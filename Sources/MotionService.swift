import Foundation
import Combine
import CoreMotion

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
    @Published private(set) var sourceName = "No headphone sensor"
    /// Added delay relative to this source session's best observed offset;
    /// deliberately not called absolute source age before epoch verification.
    @Published private(set) var addedDeliveryLag = 0.0

    private var manager: CMHeadphoneMotionManager?
    private var connectionDelegate: MotionConnectionDelegate?
    private var generation: UInt64 = 0
    private var streamGeneration: UInt64 = 0
    private var watchdog: Timer?
    private var reference: CMAttitude?
    private var latest: CMAttitude?
    private var previousQuaternion: VeilQuaternion?
    private var source: CMDeviceMotion.SensorLocation?
    private var previousTimestamp: TimeInterval?
    private var lastReceipt: TimeInterval?
    private var stableSince: TimeInterval?
    private var stableAnchor: VeilQuaternion?
    private var rateStart: TimeInterval?
    private var rateSamples = 0
    private var streamRequested = false
    private var nextRetryTime: TimeInterval = 0
    private var errorRetryCount = 0
    private var sourceClock = VeilSampleClock()
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
            // A connect callback may follow the first valid sample at startup.
            // Only restart when no stream is already requested.
            beginStreamIfAvailable()
        } else {
            streamGeneration &+= 1
            manager?.stopDeviceMotionUpdates()
            streamRequested = false
            resetSamples()
            status = "AirPods disconnected — reconnect and Set center"
        }
    }

    private func beginStreamIfAvailable() {
        guard isRunning, let manager, !streamRequested, errorRetryCount <= 3,
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
        streamGeneration &+= 1
        let run = generation, stream = streamGeneration
        status = "Waiting for AirPods motion and permission"
        // Main operation queue keeps the small latest-pose update bounded and
        // ordered with UI state. No image work or history processing occurs here.
        manager.startDeviceMotionUpdates(to: .main) { [weak self] sample, error in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, self.generation == run,
                      self.streamGeneration == stream else { return }
                if let error {
                    self.handleStreamError(error)
                    return
                }
                if let sample { self.receive(sample) }
            }
        }
    }

    private func handleStreamError(_ error: Error) {
        // A terminal Core Motion error may not be followed by a disconnect.
        // Retire this callback generation before stopping, then allow a bounded
        // retry. Denied/restricted authorization is checked before every start.
        streamGeneration &+= 1
        manager?.stopDeviceMotionUpdates()
        streamRequested = false
        errorRetryCount += 1
        nextRetryTime = ProcessInfo.processInfo.systemUptime + 2
        resetSamples()
        let recovery = errorRetryCount <= 3 ? "Retrying in 2 seconds; Set center after recovery" : "Choose Reconnect to retry"
        status = "Motion error: \(error.localizedDescription). \(recovery)"
    }

    private func receive(_ sample: CMDeviceMotion) {
        let now = ProcessInfo.processInfo.systemUptime
        let q = Self.quaternion(sample.attitude)
        let rotation = sample.rotationRate
        let speed = sqrt(rotation.x*rotation.x + rotation.y*rotation.y + rotation.z*rotation.z)
        guard sample.timestamp.isFinite, sample.timestamp >= 0, q.normalized != nil,
              speed.isFinite, let attitude = sample.attitude.copy() as? CMAttitude else {
            invalidateCalibration("Invalid motion sample — Set center after recovery")
            isFresh = false
            return
        }
        if let previousTimestamp, sample.timestamp <= previousTimestamp {
            invalidateCalibration("Motion clock changed — Reconnect if it persists, then Set center")
            isFresh = false
            // Drop this sample and reset ordering so a restarted source clock can
            // recover, while refusing to use the out-of-order pose as direction.
            self.previousTimestamp = nil
            previousQuaternion = nil
            return
        }
        if let lastReceipt, now - lastReceipt > staleAfter {
            invalidateCalibration("Motion resumed after a gap — Set center")
        }
        if let source, source != sample.sensorLocation {
            invalidateCalibration("Active AirPod changed — Set center")
            previousQuaternion = nil
            sourceClock.reset()
        }
        guard let lag = sourceClock.addedLag(source: sample.timestamp, receipt: now) else {
            invalidateCalibration("Invalid motion delivery timing — Reconnect")
            isFresh = false
            return
        }
        addedDeliveryLag = lag
        if lag >= staleAfter {
            invalidateCalibration("Delayed motion samples — wait for live motion and Set center")
            isFresh = false
            // Keep the best offset rather than adopting this late stream as the
            // new normal. Increasing buffered timestamps do not imply live pose.
            previousTimestamp = sample.timestamp
            previousQuaternion = nil
            return
        }
        if let previousTimestamp, let previousQuaternion {
            let dt = sample.timestamp - previousTimestamp
            if dt > staleAfter {
                invalidateCalibration("Motion sample gap — Set center")
            } else if let distance = q.angularDistance(to: previousQuaternion),
                      distance > max(0.35, speed * dt * 3 + 0.15) {
                // Conservative discontinuity heuristic, not a drift guarantee.
                invalidateCalibration("Head reference jumped — hold still and Set center")
            }
        }
        previousTimestamp = sample.timestamp
        previousQuaternion = q
        lastReceipt = now
        latest = attitude
        source = sample.sensorLocation
        switch sample.sensorLocation {
        case .headphoneLeft: sourceName = "Left AirPod"
        case .headphoneRight: sourceName = "Right AirPod"
        case .default: sourceName = "Headphone motion sensor"
        @unknown default: sourceName = "Unknown headphone sensor"
        }
        updateStability(q, speed: speed, now: now)
        updateRate(now)
        isFresh = true
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

    private func updateStability(_ q: VeilQuaternion, speed: Double, now: TimeInterval) {
        guard speed < 0.15 else { stableSince = nil; stableAnchor = nil; return }
        if let anchor = stableAnchor, let distance = q.angularDistance(to: anchor), distance < 0.035 {
            return
        }
        stableAnchor = q
        stableSince = now
    }

    private func updateRate(_ now: TimeInterval) {
        guard let rateStart else { self.rateStart = now; rateSamples = 0; return }
        rateSamples += 1
        let elapsed = now - rateStart
        if elapsed >= 1 {
            sampleRate = Double(rateSamples) / elapsed
            self.rateStart = now
            rateSamples = 0
        }
    }

    private func checkFreshness() {
        if !streamRequested { beginStreamIfAvailable() }
        guard let lastReceipt else { return }
        if ProcessInfo.processInfo.systemUptime - lastReceipt > staleAfter {
            if isFresh { invalidateCalibration("Motion stalled — reconnect or Set center after recovery") }
            isFresh = false
            sampleRate = 0
            rateStart = nil
        }
    }

    private func invalidateCalibration(_ message: String) {
        reference = nil
        isCalibrated = false
        yawDegrees = 0
        stableSince = nil
        stableAnchor = nil
        status = message
    }

    private func resetSamples() {
        invalidateCalibration("Waiting for motion")
        latest = nil
        previousQuaternion = nil
        previousTimestamp = nil
        sourceClock.reset()
        addedDeliveryLag = 0
        lastReceipt = nil
        source = nil
        sourceName = "No headphone sensor"
        sampleRate = 0
        rateStart = nil
        rateSamples = 0
        isFresh = false
    }

    private static func quaternion(_ attitude: CMAttitude) -> VeilQuaternion {
        let q = attitude.quaternion
        return VeilQuaternion(x: q.x, y: q.y, z: q.z, w: q.w)
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
