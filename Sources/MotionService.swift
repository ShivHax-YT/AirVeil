import Foundation
import Combine
import CoreMotion

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
    @Published private(set) var isFresh = false
    @Published private(set) var isRunning = false
    @Published private(set) var connectionState: MotionConnectionState = .unknown
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

    private var manager: CMHeadphoneMotionManager?
    private var connectionDelegate: MotionConnectionDelegate?
    private var generation: UInt64 = 0
    private var streamGeneration: UInt64 = 0
    private var watchdog: Timer?
    private var reference: CMAttitude?
    private var latest: CMAttitude?
    private var lastReceipt: TimeInterval?
    private var stableSince: TimeInterval?
    private var streamRequested = false
    private var streamStartedAt: TimeInterval?
    private var nextRetryTime: TimeInterval = 0
    private var errorRetryCount = 0
    private var mailbox: MotionDeliveryBuffer?
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "AirVeil.HeadphoneAcquisition"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        return queue
    }()
    private let staleAfter = 0.65
    private let calibrationWindow = 0.45

    /// Read at render consumption, so a delayed watchdog cannot make an old
    /// pose appear valid during menu tracking or main-thread scheduling delays.
    var trackingValid: Bool {
        isRunning && isFresh && isCalibrated && yawDegrees.isFinite &&
            VeilMath.isRecent(receipt: lastReceipt, now: ProcessInfo.processInfo.systemUptime,
                              timeout: staleAfter)
    }

    var canCalibrate: Bool {
        guard isRunning, isFresh, latest != nil, let stableSince, let lastReceipt else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        return VeilMath.isRecent(receipt: lastReceipt, now: now, timeout: staleAfter) &&
            lastReceipt - stableSince >= calibrationWindow
    }

    func start() {
        guard !isRunning else { return }
        connectionState = .unknown
        generation &+= 1
        let run = generation
        resetSamples()
        errorRetryCount = 0
        nextRetryTime = 0
        let motion = CMHeadphoneMotionManager()
        manager = motion
        let delegate = MotionConnectionDelegate(owner: self, generation: run)
        connectionDelegate = delegate
        motion.delegate = delegate
        isRunning = true
        status = "Waiting for connected, worn AirPods"
        motion.startConnectionStatusUpdates()
        beginStreamIfAvailable()
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
        manager?.stopDeviceMotionUpdates()
        manager?.stopConnectionStatusUpdates()
        manager?.delegate = nil
        manager = nil
        connectionDelegate = nil
        streamRequested = false
        errorRetryCount = 0
        nextRetryTime = 0
        isRunning = false
        connectionState = .unknown
        resetSamples()
        status = "Motion paused"
    }

    func calibrate() {
        guard canCalibrate, let latest,
              let copied = latest.copy() as? CMAttitude else {
            status = isFresh ? "Hold your head still facing the screen, then Set center" : "Wait for fresh AirPods motion before setting center"
            return
        }
        reference = copied
        yawDegrees = 0
        isCalibrated = true
        status = "Tracking head motion"
    }

    fileprivate func connectionChanged(connected: Bool, generation run: UInt64) {
        guard isRunning, generation == run else { return }
        if connected {
            connectionState = .connected
            // A connect callback may follow the first valid sample at startup.
            // Only restart when no stream is already requested.
            errorRetryCount = 0
            nextRetryTime = 0
            beginStreamIfAvailable()
        } else {
            streamGeneration &+= 1
            manager?.stopDeviceMotionUpdates()
            streamRequested = false
            resetSamples()
            status = "AirPods disconnected — waiting to reconnect automatically"
            connectionState = .disconnected
            // Publish the event after the disconnected state and stream cleanup
            // so a debounced coordinator observes a consistent service state.
            if disconnectEventCount < UInt64.max { disconnectEventCount += 1 }
        }
    }

    private func beginStreamIfAvailable() {
        guard isRunning, let manager, !streamRequested,
              ProcessInfo.processInfo.systemUptime >= nextRetryTime else { return }
        switch CMHeadphoneMotionManager.authorizationStatus() {
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
        guard manager.isDeviceMotionAvailable else { return }
        streamRequested = true
        streamStartedAt = ProcessInfo.processInfo.systemUptime
        streamGeneration &+= 1
        let run = generation, stream = streamGeneration
        status = "Waiting for AirPods motion and permission"
        let buffer = MotionDeliveryBuffer(staleAfter: staleAfter)
        mailbox = buffer
        // Timestamp delivery independently of UI scheduling. This serial queue
        // validates every sample; a one-slot mailbox forwards only the newest
        // pose and preserves any intervening continuity failure.
        manager.startDeviceMotionUpdates(to: motionQueue) { [weak self] sample, error in
            let receipt = ProcessInfo.processInfo.systemUptime
            let shouldNotify: Bool
            if let error {
                shouldNotify = buffer.offerError(error.localizedDescription)
            } else if let sample {
                let q = sample.attitude.quaternion
                let r = sample.rotationRate
                let reading = MotionReading(attitude: sample.attitude.copy() as? CMAttitude,
                    timestamp: sample.timestamp, receipt: receipt,
                    quaternion: VeilQuaternion(x: q.x, y: q.y, z: q.z, w: q.w),
                    speed: sqrt(r.x*r.x + r.y*r.y + r.z*r.z), source: sample.sensorLocation)
                shouldNotify = buffer.offer(reading)
            } else { return }
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
        manager?.stopDeviceMotionUpdates()
        streamRequested = false
        errorRetryCount = min(errorRetryCount + 1, 5)
        let retryDelay = min(30.0, pow(2.0, Double(errorRetryCount)))
        nextRetryTime = ProcessInfo.processInfo.systemUptime + retryDelay
        resetSamples()
        let recovery = "Retrying automatically in \(Int(retryDelay)) seconds"
        status = "Motion error: \(error.localizedDescription). \(recovery)"
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
        if let issue = delivery.continuityIssue { invalidateCalibration(issue) }
        addedDeliveryLag = delivery.addedLag
        guard let reading = delivery.reading, let attitude = reading.attitude else {
            isFresh = false
            return
        }
        // Fresh acquisition can wait behind UI work. A still-old newest sample
        // remains unsafe; never renew its receipt time at UI consumption.
        guard VeilMath.isRecent(receipt: reading.receipt,
                                now: ProcessInfo.processInfo.systemUptime, timeout: staleAfter) else {
            invalidateCalibration("Motion stalled — waiting for recovery; then Set center")
            isFresh = false
            return
        }
        lastReceipt = reading.receipt
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
        if let reference, let relative = attitude.copy() as? CMAttitude {
            relative.multiply(byInverseOf: reference)
            guard let yaw = VeilMath.yawRadians(Self.quaternion(relative)) else {
                invalidateCalibration("Invalid relative attitude — Set center")
                return
            }
            yawDegrees = yaw * 180 / .pi
            status = "Tracking head motion"
        } else if !status.contains("Set center") {
            status = "Motion available — face the screen and Set center"
        }
    }

    private func checkFreshness() {
        // Consume acquisition that may already be waiting before judging the
        // previous UI snapshot. This also operates during menu tracking.
        drainMotionMailbox()
        if !streamRequested { beginStreamIfAvailable() }
        let now = ProcessInfo.processInfo.systemUptime
        if streamRequested, let receipt = lastReceipt ?? streamStartedAt, now - receipt > 5 {
            handleStreamError(NSError(domain: "AirVeil.Motion", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "No motion received"]))
            return
        }
        guard let lastReceipt else { return }
        if ProcessInfo.processInfo.systemUptime - lastReceipt > staleAfter {
            if isFresh { invalidateCalibration("Motion stalled — waiting for recovery; then Set center") }
            isFresh = false
            sampleRate = 0
        }
    }

    private func invalidateCalibration(_ message: String) {
        reference = nil
        isCalibrated = false
        yawDegrees = 0
        stableSince = nil
        status = message
    }

    private func resetSamples() {
        invalidateCalibration("Waiting for motion")
        latest = nil
        mailbox = nil
        addedDeliveryLag = 0
        referenceJumpCount = 0
        lastReferenceJump = "No reference jump observed"
        lastReceipt = nil
        sourceName = "No headphone sensor"
        sampleRate = 0
        isFresh = false
    }

    private static func quaternion(_ attitude: CMAttitude) -> VeilQuaternion {
        let q = attitude.quaternion
        return VeilQuaternion(x: q.x, y: q.y, z: q.z, w: q.w)
    }
}

/// The copied attitude is immutable on the acquisition side and transferred
/// through the lock; only the main actor makes a second, mutable relative copy.
struct MotionReading: @unchecked Sendable {
    let attitude: CMAttitude?
    let timestamp: TimeInterval
    let receipt: TimeInterval
    let quaternion: VeilQuaternion
    let speed: Double
    let source: CMDeviceMotion.SensorLocation
}

struct MotionDelivery {
    let reading: MotionReading?
    let continuityIssue: String?
    let error: String?
    let stableSince: TimeInterval?
    let sampleRate: Double
    let addedLag: Double
    let referenceJumpCount: Int
    let lastReferenceJump: MotionJumpDiagnostic?
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
        guard error == nil else { return false }
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
        }
        if let previous {
            let sourceGap = reading.timestamp - previous.timestamp
            let receiptGap = reading.receipt - previous.receipt
            if sourceGap <= 0 || receiptGap < 0 {
                fail("Motion clock changed — waiting for recovery; then Set center")
                // Keep the lag baseline: out-of-order delivery must not make
                // stale data fresh. An actual reset recovers via normal retry.
                return notify
            }
            if receiptGap >= staleAfter || sourceGap >= staleAfter {
                fail("Motion resumed after a sensor gap — Set center")
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
        guard let lag = clock.addedLag(source: reading.timestamp, receipt: reading.receipt) else {
            fail("Invalid motion delivery timing — waiting for recovery")
            return notify
        }
        addedLag = lag
        previous = reading
        guard lag < staleAfter else {
            fail("Delayed sensor samples — wait for live motion and Set center")
            return notify
        }
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
            error: error, stableSince: stableSince, sampleRate: sampleRate, addedLag: addedLag,
            referenceJumpCount: referenceJumpCount, lastReferenceJump: lastReferenceJump)
        updatePending = false
        issue = nil
        latest = nil
        // A terminal error remains latched until the owner retires this buffer.
        return delivery
    }

    private func fail(_ message: String) {
        issue = message
        latest = nil
        stableSince = nil
        stableAnchor = nil
    }
}

/// The immutable run token makes queued delegate callbacks from previous
/// starts harmless, including a late disconnect after reconnecting.
private final class MotionConnectionDelegate: NSObject, CMHeadphoneMotionManagerDelegate {
    weak var owner: MotionService?
    let generation: UInt64
    init(owner: MotionService, generation: UInt64) {
        self.owner = owner
        self.generation = generation
    }
    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        let run = generation
        Task { @MainActor [weak owner] in owner?.connectionChanged(connected: true, generation: run) }
    }
    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        let run = generation
        Task { @MainActor [weak owner] in owner?.connectionChanged(connected: false, generation: run) }
    }
}
