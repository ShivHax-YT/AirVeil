import Foundation
import Combine
import CoreMotion
import CoreMedia

enum MotionReferenceState: String {
    case unset, established, awaitingReturn, retainedAfterGap, invalid
}

enum MotionConnectionState: String {
    case unknown
    case connected
    case disconnected
}

/// Local, in-memory headphone pose. Positive relative yaw is provisionally
/// physical LEFT; that adapter convention must be checked with the wearer's
/// actual AirPods, and the UI exposes inversion. It is not an eye-gaze sensor.
@MainActor
final class MotionService: NSObject, ObservableObject {
    @Published private(set) var status = "Motion paused"
    @Published private(set) var yawDegrees = 0.0
    @Published private(set) var sampleRate = 0.0
    @Published private(set) var isCalibrated = false
    @Published private(set) var referenceState = MotionReferenceState.unset
    @Published private(set) var centerRevision = 0
    /// Raw local sensor coordinates for optional camera fusion. Availability
    /// does not imply the legacy manual center survived a removal/reset.
    @Published private(set) var fusionSample: HeadingMotionSample?
    @Published private(set) var fusionEpoch: UInt64 = 0
    /// Last public Core Motion diagnostics only. A reported heading is not
    /// assumed to be absolute or display-relative for headphone motion.
    @Published private(set) var reportedHeadingDegrees = -1.0
    @Published private(set) var reportedMagneticAccuracy = -1
    var hasSavedCenter: Bool { reference != nil }
    var referenceUsable: Bool { hasSavedCenter && referenceState != .invalid && referenceState != .unset }
    @Published private(set) var isFresh = false
    @Published private(set) var isRunning = false
    @Published private(set) var connectionState: MotionConnectionState = .unknown
    /// Removal policy only. Unlike motion connectionState, a still-streaming
    /// remaining bud cannot cancel an independently observed per-bud removal.
    @Published private(set) var removalConnectionState: MotionConnectionState = .unknown
    @Published private(set) var removalEventCount: UInt64 = 0
    @Published private(set) var wearStatus = "Using AirPods connection events."
    var monitorsIndividualAirPods = false {
        didSet {
            guard oldValue != monitorsIndividualAirPods else { return }
            clearRemovalEvidence()
        }
    }
    /// Lifetime-monotonic count of actual delegate disconnect callbacks. With
    /// Automatic Ear Detection this can indicate removal; it does not prove
    /// both buds were removed. Stream errors and stale data are not removal.
    @Published private(set) var disconnectEventCount: UInt64 = 0
    @Published private(set) var sourceName = "No headphone sensor"
    /// Added delay relative to this source session's best observed offset;
    /// deliberately not called absolute source age before epoch verification.
    @Published private(set) var addedDeliveryLag = 0.0
    /// Session count and one aggregate event description, never a pose history.
    /// A latched status may be read many times; that does not mean many jumps.
    @Published private(set) var referenceJumpCount = 0
    @Published private(set) var lastReferenceJump = "No reference jump observed"

    private var manager: (any HeadphoneMotionTransport)?
    private let transportFactory: () -> any HeadphoneMotionTransport
    private let now: () -> TimeInterval
    private let usesAutomaticWatchdog: Bool
    private var generation: UInt64 = 0
    private var streamGeneration: UInt64 = 0
    private var watchdog: Timer?
    private var reference: (any MotionAttitude)?
    private var latest: (any MotionAttitude)?
    private var lastReceipt: TimeInterval?
    private var stableSince: TimeInterval?
    private var streamRequested = false
    private var streamStartedAt: TimeInterval?
    private var nextRetryTime: TimeInterval = 0
    private var errorRetryCount = 0
    private var mailbox: MotionDeliveryBuffer?
    private var wearEvidence = AirPodsWearEvidence()
    private var nextWearPoll = -Double.infinity
    private var observedPublicDisconnect = false
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "AirVeil.HeadphoneAcquisition"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        return queue
    }()
    private let staleAfter = 0.65
    private let calibrationWindow = 0.45

    override convenience init() {
        self.init(transportFactory: { CoreMotionTransport() },
                  now: { ProcessInfo.processInfo.systemUptime })
    }

    /// Injectable acquisition/clock boundary tests the real coordinator without
    /// constructing Core Motion managers or requesting device permissions.
    init(transportFactory: @escaping () -> any HeadphoneMotionTransport,
         now: @escaping () -> TimeInterval, usesAutomaticWatchdog: Bool = true) {
        self.transportFactory = transportFactory
        self.now = now
        self.usesAutomaticWatchdog = usesAutomaticWatchdog
        super.init()
    }

    /// Read at render consumption, so a delayed watchdog cannot make an old
    /// pose appear valid during menu tracking or main-thread scheduling delays.
    var trackingValid: Bool {
        isRunning && isFresh && referenceUsable && yawDegrees.isFinite &&
            VeilMath.isRecent(receipt: lastReceipt, now: now(),
                              timeout: staleAfter)
    }

    var canCalibrate: Bool {
        guard isRunning, isFresh, latest != nil, let stableSince, let lastReceipt else { return false }
        let now = now()
        return VeilMath.isRecent(receipt: lastReceipt, now: now, timeout: staleAfter) &&
            lastReceipt - stableSince >= calibrationWindow
    }

    func start() {
        guard !isRunning else { return }
        connectionState = .unknown
        wearEvidence.reset(); nextWearPoll = -Double.infinity; observedPublicDisconnect = false
        synchronizeRemovalEvidence()
        generation &+= 1
        let run = generation
        resetDelivery()
        if hasSavedCenter { invalidateCalibration("Motion manager restarted — original center retained but unverified; use Set center") }
        errorRetryCount = 0
        nextRetryTime = 0
        let motion = transportFactory()
        manager = motion
        isRunning = true
        status = "Waiting for connected, worn AirPods"
        motion.startConnectionUpdates { [weak self] connected in
            self?.connectionChanged(connected: connected, generation: run)
        }
        beginStreamIfAvailable()
        guard usesAutomaticWatchdog else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == run, self.isRunning else { return }
                self.checkFreshness()
            }
        }
        watchdog = timer
        // Status menus enter event-tracking mode. Freshness must still expire
        // while a common-mode display link is drawing the desktop effect.
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        generation &+= 1
        streamGeneration &+= 1
        watchdog?.invalidate()
        watchdog = nil
        manager?.stopMotionUpdates()
        manager?.stopConnectionUpdates()
        manager = nil
        streamRequested = false
        errorRetryCount = 0
        nextRetryTime = 0
        isRunning = false
        connectionState = .unknown
        wearEvidence.reset(); observedPublicDisconnect = false
        synchronizeRemovalEvidence()
        resetDelivery()
        invalidateCalibration("Motion stopped — original center must be checked before reuse")
        if !hasSavedCenter { status = "Motion paused" }
    }

    func calibrate() {
        guard canCalibrate, let latest else {
            status = isFresh ? "Hold your head still facing the screen, then Set center" : "Wait for fresh AirPods motion before setting center"
            return
        }
        reference = latest.copyForReference()
        centerRevision += 1
        yawDegrees = 0
        isCalibrated = true
        referenceState = .established
        status = "Tracking head motion"
    }

    fileprivate func connectionChanged(connected: Bool, generation run: UInt64) {
        guard isRunning, generation == run else { return }
        if connected {
            if observedPublicDisconnect { wearEvidence.noteExplicitReconnect() }
            observedPublicDisconnect = false
            mailbox?.setConnected(true)
            connectionState = .connected
            // A connect callback may follow the first valid sample at startup.
            // Only restart when no stream is already requested.
            errorRetryCount = 0
            nextRetryTime = 0
            beginStreamIfAvailable()
        } else {
            observedPublicDisconnect = true
            // Keep the stream for transport recovery, but the wearer test
            // disproved trusting its original zero through a removal.
            mailbox?.setConnected(false)
            markFreshnessLost("AirPods disconnected — check your center after reconnecting", awaitingReturn: true)
            connectionState = .disconnected
            // Publish the event after the disconnected state and stream cleanup
            // so a debounced coordinator observes a consistent service state.
            if disconnectEventCount < UInt64.max { disconnectEventCount += 1 }
        }
        synchronizeRemovalEvidence()
    }

    private func beginStreamIfAvailable() {
        guard isRunning, let manager, !streamRequested, connectionState != .disconnected,
              now() >= nextRetryTime else { return }
        switch manager.authorizationStatus {
        case .denied:
            status = "Motion access denied — allow AirVeil in System Settings"
            return
        case .restricted:
            status = "Motion access is restricted on this Mac"
            return
        case .authorized, .notDetermined: break
        @unknown default:
            status = "Unknown motion authorization state"
            return
        }
        guard manager.isMotionAvailable else { return }
        streamRequested = true
        streamStartedAt = now()
        streamGeneration &+= 1
        let run = generation, stream = streamGeneration
        status = "Waiting for AirPods motion and permission"
        let buffer = MotionDeliveryBuffer(staleAfter: staleAfter)
        mailbox = buffer
        // Timestamp delivery independently of UI scheduling. This serial queue
        // validates every sample; a one-slot mailbox forwards only the newest
        // pose and preserves any intervening continuity failure.
        manager.startMotionUpdates(on: motionQueue) { [weak self] sample, error in
            let shouldNotify: Bool
            if let error { shouldNotify = buffer.offerError(error) }
            else if let sample { shouldNotify = buffer.offer(sample) }
            else { return }
            guard shouldNotify else { return }
            DispatchQueue.main.async { [weak self, buffer] in
                guard let self, self.isRunning, self.generation == run,
                      self.streamGeneration == stream, self.mailbox === buffer else { return }
                self.drainMotionMailbox(fromScheduledCallback: true)
            }
        }
    }

    private func handleStreamError(_ error: Error) {
        // A terminal Core Motion error may not be followed by a disconnect.
        // Retire this callback generation before stopping, then retry with a
        // bounded delay. Denied/restricted access is checked before each start.
        streamGeneration &+= 1
        manager?.stopMotionUpdates()
        streamRequested = false
        errorRetryCount = min(errorRetryCount + 1, 5)
        let retryDelay = min(30.0, pow(2.0, Double(errorRetryCount)))
        nextRetryTime = now() + retryDelay
        resetDelivery()
        invalidateCalibration("Motion stream restarted — original center retained but unusable until Set center")
        let recovery = "Retrying automatically in \(Int(retryDelay)) seconds"
        status = "Motion error: \(error.localizedDescription). \(recovery). Set center after recovery."
    }

    private func drainMotionMailbox(fromScheduledCallback: Bool = false) {
        guard let delivery = mailbox?.take(releaseNotification: fromScheduledCallback) else { return }
        referenceJumpCount = delivery.referenceJumpCount
        if let jump = delivery.lastReferenceJump { lastReferenceJump = jump.summary }
        if let error = delivery.error {
            handleStreamError(NSError(domain: "AirVeil.Motion", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: error]))
            return
        }
        if let issue = delivery.continuityIssue {
            if delivery.continuityImpact == .invalid { invalidateCalibration(issue) }
            else if delivery.continuityImpact == .gap { markFreshnessLost(issue) }
        }
        addedDeliveryLag = delivery.addedLag
        guard let reading = delivery.reading, let attitude = reading.attitude else {
            isFresh = false
            return
        }
        // Fresh acquisition can wait behind UI work. A still-old newest sample
        // remains unsafe; never renew its receipt time at UI consumption.
        guard VeilMath.isRecent(receipt: reading.receipt,
                                now: now(), timeout: staleAfter) else {
            markFreshnessLost("Motion stalled — original center retained while waiting for samples")
            isFresh = false
            return
        }
        lastReceipt = reading.receipt
        if let rawYaw = VeilMath.yawRadians(reading.quaternion) {
            let hostReceipt = reading.hostReceipt ?? reading.receipt
            if hostReceipt.isFinite, hostReceipt >= 0 {
                fusionSample = HeadingMotionSample(epoch: fusionEpoch,
                    sourceTimestamp: reading.timestamp, receiptHostTime: hostReceipt,
                    yawRadians: rawYaw, angularSpeed: reading.speed,
                    acquisitionContinuityVerified: true)
            }
        }
        reportedHeadingDegrees = reading.headingDegrees.isFinite ? reading.headingDegrees : -1
        reportedMagneticAccuracy = reading.magneticAccuracy
        latest = attitude
        stableSince = delivery.stableSince
        sampleRate = delivery.sampleRate
        switch reading.source {
        case .headphoneLeft: sourceName = "Left AirPod"
        case .headphoneRight: sourceName = "Right AirPod"
        case .default: sourceName = "Headphone motion sensor"
        @unknown default: sourceName = "Unknown headphone sensor"
        }
        errorRetryCount = 0
        isFresh = true
        // Some systems deliver usable motion before the startup connect event.
        connectionState = .connected
        synchronizeRemovalEvidence()
        if referenceState == .awaitingReturn { referenceState = .retainedAfterGap }
        if let reference {
            guard let yaw = attitude.relativeYaw(to: reference), yaw.isFinite else {
                invalidateCalibration("Invalid relative attitude — original center retained; use Set center")
                return
            }
            yawDegrees = yaw * 180 / .pi
            if referenceUsable {
                isCalibrated = true
                status = referenceState == .retainedAfterGap
                    ? "Using your saved center after motion returned"
                    : "Tracking head motion"
            } else if !status.contains("Set center") {
                status = "Original center retained, but the sensor reference changed. Use Set center."
            }
        } else if !status.contains("Set center") {
            status = "Motion available — face the screen and Set center once"
        }
    }

    func checkFreshness() {
        // Consume acquisition that may already be waiting before judging the
        // previous UI snapshot. This also operates during menu tracking.
        drainMotionMailbox()
        pollWearEvidence()
        if !streamRequested { beginStreamIfAvailable() }
        let now = now()
        // Silence is not evidence of a broken reference. Restarting a known
        // calibrated stream solely because the buds are out can destroy zero.
        if streamRequested, !hasSavedCenter, connectionState != .disconnected,
           let receipt = lastReceipt ?? streamStartedAt, now - receipt > 5 {
            handleStreamError(NSError(domain: "AirVeil.Motion", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "No motion received"]))
            return
        }
        guard let lastReceipt else { return }
        if now - lastReceipt > staleAfter {
            if isFresh { markFreshnessLost("Motion stalled — original center retained while waiting for samples") }
            isFresh = false
            sampleRate = 0
            if hasSavedCenter, connectionState != .disconnected, now - lastReceipt > 5 {
                status = "No motion updates. Reconnect AirPods or restart AirVeil; restarting the motion stream requires Set center."
            }
        }
    }

    /// Explicit user recovery, used only by a visible manual action. A new
    /// genuine metadata transition may arm removal again after fresh motion.
    func clearRemovalEvidence() {
        wearEvidence.reset(); nextWearPoll = -Double.infinity
        synchronizeRemovalEvidence()
    }

    private func pollWearEvidence() {
        guard isRunning, monitorsIndividualAirPods else { return }
        let receipt = now()
        guard receipt >= nextWearPoll else { return }
        nextWearPoll = receipt + 0.25
        _ = wearEvidence.update(manager?.readWearState(now: receipt),
            freshMotion: isFresh && connectionState == .connected, now: receipt)
        synchronizeRemovalEvidence()
    }

    private func synchronizeRemovalEvidence() {
        let next: MotionConnectionState = wearEvidence.isRemovalLatched ? .disconnected : connectionState
        if next != removalConnectionState {
            let newlyRemoved = next == .disconnected && removalConnectionState != .disconnected
            removalConnectionState = next
            if newlyRemoved, removalEventCount < UInt64.max { removalEventCount += 1 }
        }
        let message: String
        if wearEvidence.hasCurrentMetadata, let mask = wearEvidence.wornMask {
            switch mask {
            case 3: message = "Both AirPods are in ear."
            case 1: message = "Right AirPod is out of ear."
            case 2: message = "Left AirPod is out of ear."
            default: message = "Both AirPods are out of ear."
            }
        } else if wearEvidence.isRemovalLatched {
            message = "AirPod removal was observed. Waiting for reinsertion or manual brightness recovery."
        } else { message = "Per-AirPod state unavailable. Using AirPods connection events." }
        if wearStatus != message { wearStatus = message }
    }

    private func invalidateCalibration(_ message: String) {
        advanceFusionEpoch()
        referenceState = hasSavedCenter ? .invalid : .unset
        isCalibrated = false
        stableSince = nil
        status = message
    }

    private func markFreshnessLost(_ message: String, awaitingReturn: Bool = false) {
        if isFresh || fusionSample != nil { advanceFusionEpoch() }
        isFresh = false
        stableSince = nil
        // An unobserved gap can hide an origin reset. Keep the copied object
        // for diagnostics, never drive legacy blur from its unverified zero.
        if hasSavedCenter { referenceState = .invalid }
        isCalibrated = false
        status = hasSavedCenter ? message + ". Use Set center or camera assistance." : message
    }

    private func advanceFusionEpoch() {
        fusionEpoch &+= 1
        fusionSample = nil
    }

    private func resetDelivery() {
        advanceFusionEpoch()
        latest = nil
        mailbox = nil
        addedDeliveryLag = 0
        referenceJumpCount = 0
        lastReferenceJump = "No reference jump observed"
        lastReceipt = nil
        reportedHeadingDegrees = -1
        reportedMagneticAccuracy = -1
        sourceName = "No headphone sensor"
        sampleRate = 0
        isFresh = false
    }

}

/// The copied attitude is immutable on the acquisition side and transferred
/// through the lock; only the main actor makes a second, mutable relative copy.
struct MotionReading: @unchecked Sendable {
    let attitude: (any MotionAttitude)?
    let timestamp: TimeInterval
    let receipt: TimeInterval
    let quaternion: VeilQuaternion
    let speed: Double
    let source: CMDeviceMotion.SensorLocation
    var headingDegrees: Double = -1
    var magneticAccuracy: Int = -1
    /// Core Media host clock sampled at acquisition, before any main-queue wait.
    /// Synthetic boundaries may omit it and use their injected receipt clock.
    var hostReceipt: TimeInterval? = nil
}

struct MotionDelivery {
    let reading: MotionReading?
    let continuityIssue: String?
    let continuityImpact: MotionContinuityImpact
    let error: String?
    let stableSince: TimeInterval?
    let sampleRate: Double
    let addedLag: Double
    let referenceJumpCount: Int
    let lastReferenceJump: MotionJumpDiagnostic?
}

enum MotionContinuityImpact: Int {
    case none, gap, invalid
}

/// Evidence of an unexplained orientation step, not proof of an Apple reset.
/// We cannot reconstruct the lost screen reference from this event alone.
struct MotionJumpDiagnostic {
    let stepRadians: Double
    let thresholdRadians: Double
    let sourceInterval: TimeInterval
    let receiptInterval: TimeInterval
    let previousSpeed: Double
    let currentSpeed: Double

    var summary: String {
        String(format: "Attitude step %.1f°; limit %.1f°; sensor %.0f ms; receipt %.0f ms; rotation %.1f→%.1f°/s",
               stepRadians * 180 / .pi, thresholdRadians * 180 / .pi,
               sourceInterval * 1000, receiptInterval * 1000,
               previousSpeed * 180 / .pi, currentSpeed * 180 / .pi)
    }
}

/// Bounded acquisition/UI handoff. Every sensor sample is validated before
/// replacement. Errors and lost continuity are sticky until UI consumption, so
/// dropping obsolete visual poses cannot conceal an intervening sensor failure.
final class MotionDeliveryBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let staleAfter: TimeInterval
    private var notificationPending = false
    private var updatePending = false
    private var latest: MotionReading?
    private var issue: String?
    private var impact = MotionContinuityImpact.none
    private var acceptsSamples = true
    private var returningAfterAbsence = false
    private var clockRecovery: MotionClockRecoveryCandidate?
    private var error: String?
    private var previous: MotionReading?
    private var clock = VeilSampleClock()
    private var stableSince: TimeInterval?
    private var stableAnchor: VeilQuaternion?
    private var rateStart: TimeInterval?
    private var rateSamples = 0
    private var sampleRate = 0.0
    private var addedLag = 0.0
    private var referenceJumpCount = 0
    private var lastReferenceJump: MotionJumpDiagnostic?

    init(staleAfter: TimeInterval = 0.65) { self.staleAfter = staleAfter }

    /// True means schedule one main-queue drain; further samples replace the
    /// slot without adding tasks to the UI queue.
    @discardableResult
    func offer(_ reading: MotionReading) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard error == nil, acceptsSamples else { return false }
        let notify = !notificationPending
        notificationPending = true
        updatePending = true
        guard reading.timestamp.isFinite, reading.timestamp >= 0,
              reading.receipt.isFinite, reading.receipt >= 0,
              reading.quaternion.normalized != nil, reading.speed.isFinite else {
            fail("Invalid motion sample — Set center after recovery")
            return notify
        }
        if let previous, previous.source != reading.source {
            fail("Active AirPod changed — Set center")
            clock.reset()
            self.previous = nil
            clockRecovery = nil
        }
        if let previous {
            let sourceGap = reading.timestamp - previous.timestamp
            let receiptGap = reading.receipt - previous.receipt
            if receiptGap < 0 {
                clockRecovery = nil
                fail("Motion receipt clock changed — waiting for recovery; then Set center")
                return notify
            }
            if sourceGap <= 0 {
                fail("Motion clock changed — checking fresh samples; then Set center")
                guard observeClockRecovery(reading, reason: .reversedTimestamp) else { return notify }
                resetTimingForRecovery(reading)
            } else {
                if clockRecovery?.reason == .reversedTimestamp { clockRecovery = nil }
                if returningAfterAbsence || receiptGap >= 0.3 || sourceGap >= 0.3 {
                    fail("Motion resumed after a sensor gap — original center retained", impact: .gap)
                } else if let distance = reading.quaternion.angularDistance(to: previous.quaternion) {
                    // Using only the newest rotation speed misclassifies a real
                    // turn that stops between samples. Both bounding samples matter.
                    // This remains a conservative heuristic, not a reference-reset
                    // API or a drift guarantee. Never correct the reference here.
                    let threshold = max(0.35, max(previous.speed, reading.speed) * sourceGap * 3 + 0.15)
                    if distance > threshold {
                        referenceJumpCount += 1
                        lastReferenceJump = MotionJumpDiagnostic(stepRadians: distance,
                            thresholdRadians: threshold, sourceInterval: sourceGap,
                            receiptInterval: receiptGap, previousSpeed: previous.speed,
                            currentSpeed: reading.speed)
                        fail("Head reference jumped — face the screen and Set center")
                    }
                }
            }
        }
        guard let lag = clock.addedLag(source: reading.timestamp, receipt: reading.receipt) else {
            fail("Invalid motion delivery timing — waiting for recovery")
            return notify
        }
        addedLag = lag
        previous = reading
        if lag >= staleAfter {
            fail("Delayed sensor samples — waiting for live motion with original center retained", impact: .gap)
            // Only an explicit out-of-ear interval authorizes recovery of a
            // changed offset. Ordinary delivery lag must never rebase itself.
            guard returningAfterAbsence,
                  observeClockRecovery(reading, reason: .offsetAfterAbsence) else { return notify }
            resetTimingForRecovery(reading)
            _ = clock.addedLag(source: reading.timestamp, receipt: reading.receipt)
            addedLag = 0
        } else {
            clockRecovery = nil
        }
        returningAfterAbsence = false
        if reading.speed >= 0.15 {
            stableSince = nil
            stableAnchor = nil
        } else if stableAnchor == nil ||
                    (reading.quaternion.angularDistance(to: stableAnchor!) ?? .infinity) >= 0.035 {
            stableSince = reading.receipt
            stableAnchor = reading.quaternion
        }
        if let rateStart {
            rateSamples += 1
            let elapsed = reading.receipt - rateStart
            if elapsed >= 1 {
                sampleRate = Double(rateSamples) / elapsed
                self.rateStart = reading.receipt
                rateSamples = 0
            }
        } else { rateStart = reading.receipt }
        latest = reading
        return notify
    }

    private func observeClockRecovery(_ reading: MotionReading,
                                      reason: MotionClockRecoveryCandidate.Reason) -> Bool {
        if clockRecovery?.reason != reason {
            clockRecovery = MotionClockRecoveryCandidate(reading: reading, reason: reason)
            return false
        }
        return clockRecovery!.observe(reading)
    }

    private func resetTimingForRecovery(_ reading: MotionReading) {
        clock.reset()
        clockRecovery = nil
        previous = reading
        rateStart = nil
        rateSamples = 0
        sampleRate = 0
        // Recovery makes the new timestamps usable, NOT the old orientation
        // reference. Only a subsequent explicit Set center can replace zero.
        fail("Motion timing restarted. Face the display and use Set center")
    }

    @discardableResult
    func offerError(_ message: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let notify = !notificationPending
        notificationPending = true
        updatePending = true
        error = message
        latest = nil
        return notify
    }

    func take(releaseNotification: Bool = true) -> MotionDelivery? {
        lock.lock()
        defer { lock.unlock() }
        // The common-mode watchdog may consume data before the scheduled main
        // task runs. Keep its scheduling token until that task actually drains,
        // so menu tracking cannot accumulate a task on every watchdog tick.
        if releaseNotification { notificationPending = false }
        guard updatePending else { return nil }
        let delivery = MotionDelivery(reading: latest, continuityIssue: issue,
            continuityImpact: impact,
            error: error, stableSince: stableSince, sampleRate: sampleRate, addedLag: addedLag,
            referenceJumpCount: referenceJumpCount, lastReferenceJump: lastReferenceJump)
        updatePending = false
        issue = nil
        impact = .none
        latest = nil
        // A terminal error remains latched until the owner retires this buffer.
        return delivery
    }

    func setConnected(_ connected: Bool) {
        lock.lock()
        defer { lock.unlock() }
        acceptsSamples = connected
        if !connected {
            // The disconnect event itself reaches the owner synchronously.
            // Keep only source/frame history, not an undelivered visual pose.
            latest = nil
            updatePending = error != nil || impact == .invalid
            stableSince = nil
            stableAnchor = nil
            returningAfterAbsence = true
            clockRecovery = nil
        }
    }

    private func fail(_ message: String, impact newImpact: MotionContinuityImpact = .invalid) {
        if newImpact.rawValue >= impact.rawValue { issue = message; impact = newImpact }
        latest = nil
        stableSince = nil
        stableAnchor = nil
    }
}

/// Conservative timing-only recovery. Never estimates screen direction and
/// never treats a single old packet, duplicate, or burst as a new live epoch.
private struct MotionClockRecoveryCandidate {
    enum Reason { case reversedTimestamp, offsetAfterAbsence }
    let reason: Reason
    private var first: MotionReading
    private var latest: MotionReading
    private var count = 1

    init(reading: MotionReading, reason: Reason) {
        first = reading; latest = reading; self.reason = reason
    }

    mutating func observe(_ reading: MotionReading) -> Bool {
        let sourceStep = reading.timestamp - latest.timestamp
        let receiptStep = reading.receipt - latest.receipt
        guard sourceStep > 0, receiptStep > 0, receiptStep < 0.3,
              abs(sourceStep-receiptStep) <= max(0.02, receiptStep*0.25) else {
            first = reading; latest = reading; count = 1
            return false
        }
        latest = reading
        count += 1
        let receiptSpan = reading.receipt-first.receipt
        let sourceSpan = reading.timestamp-first.timestamp
        return count >= 3 && receiptSpan >= 0.2 &&
            abs(sourceSpan-receiptSpan) <= max(0.025, receiptSpan*0.25)
    }
}

/// Immutable attitude boundary: production uses Apple's copied CMAttitude and
/// multiply(byInverseOf:); deterministic tests inject sensor attitudes without
/// constructing Core Motion objects or replacing the lifecycle coordinator.
protocol MotionAttitude: AnyObject, Sendable {
    func copyForReference() -> any MotionAttitude
    func relativeYaw(to reference: any MotionAttitude) -> Double?
}

private final class CoreMotionAttitude: MotionAttitude, @unchecked Sendable {
    private let value: CMAttitude
    init?(_ value: CMAttitude) {
        guard let copy = value.copy() as? CMAttitude else { return nil }
        self.value = copy
    }
    private init(copied: CMAttitude) { value = copied }
    func copyForReference() -> any MotionAttitude {
        // Core Motion attitudes implement NSCopying. A fallback still retains
        // this immutable wrapper and is never multiplied in place.
        guard let copy = value.copy() as? CMAttitude else { return self }
        return CoreMotionAttitude(copied: copy)
    }
    func relativeYaw(to reference: any MotionAttitude) -> Double? {
        guard let reference = reference as? CoreMotionAttitude,
              let relative = value.copy() as? CMAttitude else { return nil }
        relative.multiply(byInverseOf: reference.value)
        let q = relative.quaternion
        return VeilMath.yawRadians(VeilQuaternion(x: q.x, y: q.y, z: q.z, w: q.w))
    }
}

@MainActor protocol HeadphoneMotionTransport: AnyObject {
    var authorizationStatus: CMAuthorizationStatus { get }
    var isMotionAvailable: Bool { get }
    func startConnectionUpdates(_ handler: @escaping @MainActor (Bool) -> Void)
    func stopConnectionUpdates()
    func startMotionUpdates(on queue: OperationQueue,
        handler: @escaping @Sendable (MotionReading?, String?) -> Void)
    func stopMotionUpdates()
    func readWearState(now: TimeInterval) -> AirPodsWearReading?
}

extension HeadphoneMotionTransport {
    func readWearState(now: TimeInterval) -> AirPodsWearReading? { nil }
}

@MainActor private final class CoreMotionTransport: NSObject, HeadphoneMotionTransport,
    CMHeadphoneMotionManagerDelegate {
    private let manager = CMHeadphoneMotionManager()
    private let wearReader = SystemAirPodsWearReader()
    private var connectionHandler: (@MainActor (Bool) -> Void)?
    var authorizationStatus: CMAuthorizationStatus { CMHeadphoneMotionManager.authorizationStatus() }
    var isMotionAvailable: Bool { manager.isDeviceMotionAvailable }
    func startConnectionUpdates(_ handler: @escaping @MainActor (Bool) -> Void) {
        connectionHandler = handler
        manager.delegate = self
        manager.startConnectionStatusUpdates()
    }
    func stopConnectionUpdates() {
        manager.stopConnectionStatusUpdates()
        manager.delegate = nil
        connectionHandler = nil
    }
    func startMotionUpdates(on queue: OperationQueue,
        handler: @escaping @Sendable (MotionReading?, String?) -> Void) {
        manager.startDeviceMotionUpdates(to: queue) { sample, error in
            let receipt = ProcessInfo.processInfo.systemUptime
            let hostReceipt = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            if let error { handler(nil, error.localizedDescription); return }
            guard let sample else { return }
            let q = sample.attitude.quaternion, r = sample.rotationRate
            handler(MotionReading(attitude: CoreMotionAttitude(sample.attitude),
                timestamp: sample.timestamp, receipt: receipt,
                quaternion: VeilQuaternion(x: q.x, y: q.y, z: q.z, w: q.w),
                speed: sqrt(r.x*r.x + r.y*r.y + r.z*r.z), source: sample.sensorLocation,
                headingDegrees: sample.heading, magneticAccuracy: Int(sample.magneticField.accuracy.rawValue),
                hostReceipt: hostReceipt), nil)
        }
    }
    func stopMotionUpdates() { manager.stopDeviceMotionUpdates() }
    func readWearState(now: TimeInterval) -> AirPodsWearReading? { wearReader.read(now: now) }
    nonisolated func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor [weak self] in self?.connectionHandler?(true) }
    }
    nonisolated func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor [weak self] in self?.connectionHandler?(false) }
    }
}
