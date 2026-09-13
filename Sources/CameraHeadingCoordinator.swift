import Foundation
import Combine
import CoreMedia

/// Owns explicit camera setup and bounded recovery. The durable screen anchor
/// is separate from the disposable alignment of each AirPods sensor epoch.
@MainActor final class CameraHeadingCoordinator: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var status = "Optional camera assistance is off."
    @Published private(set) var isBusy = false
    @Published private(set) var isAligned = false
    @Published private(set) var centerRevision = 0
    let camera: CameraAnchorService
    private let motion: MotionService
    private let defaults: UserDefaults
    private let now: () -> Double
    private var engine = HeadingFusionEngine()
    private var subscriptions = Set<AnyCancellable>()
    private var stored: StoredCenter?
    private var sessionActive = true
    private var layoutKey = ""
    private var automaticRecoveryAllowed = true
    private var lastAttemptEpoch: UInt64?
    private var burstTicket: UInt64 = 0
    private var phase: Phase?
    private var burstStarted = false
    private var pending: [HeadingCameraSample] = []
    private var setupPairs: [(camera: HeadingCameraSample, motionYaw: Double)] = []
    private var setupNeutral: (cameraYaw: Double, motionYaw: Double, cameraID: String, configurationID: String)?
    private var burstEpoch: UInt64?
    private var burstConfiguration = ""
    private var burstLayoutKey = ""

    private enum Phase { case center, direction, recovery }
    private struct StoredCenter: Codable {
        let center: HeadingCameraCenter
        let layoutKey: String
        let configurationID: String
    }
    var hasCenter: Bool { stored != nil }
    var alignmentRevision: Int { engine.alignmentRevision }
    var trackingValid: Bool { isEnabled && sessionActive && motion.isFresh && motion.fusionSample != nil && engine.heading(now: now()) != nil }
    var yawDegrees: Double { (engine.heading(now: now()) ?? 0) * 180 / .pi }

    init(motion: MotionService, camera: CameraAnchorService? = nil,
         defaults: UserDefaults = .standard,
         now: @escaping () -> Double = { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }) {
        self.motion = motion; self.camera = camera ?? CameraAnchorService(); self.defaults = defaults; self.now = now
        isEnabled = defaults.bool(forKey: "cameraAssistance")
        if let data = defaults.data(forKey: "cameraScreenCenterV1"),
           let value = try? JSONDecoder().decode(StoredCenter.self, from: data),
           value.center.neutralYawRadians.isFinite,
           abs(value.center.cameraSign) == 1, abs(value.center.sensorSign) == 1 {
            stored = value; centerRevision = value.center.revision
            engine.configure(center: value.center)
        }
        if isEnabled { status = hasCenter ? "Your screen direction is saved. Waiting for AirPods." : "Face the display and use Set center to set up camera assistance." }
        motion.$fusionSample.sink { [weak self] sample in
            guard let self, self.isEnabled else { return }
            guard let sample else { self.engine.invalidate(); self.isAligned = false; return }
            self.engine.addMotion(sample)
        }.store(in: &subscriptions)
    }

    /// The only permission request entry point; invoked by the user's button.
    func requestEnable() {
        burstTicket &+= 1
        let ticket = burstTicket
        isBusy = true
        status = "Allow the Mac camera for brief, local direction checks."
        Task { [weak self] in
            guard let self, burstTicket == ticket, sessionActive else { return }
            let allowed = await camera.requestPermission()
            guard burstTicket == ticket else { return }
            isBusy = false
            guard allowed else { status = "Camera access was not allowed. Manual Set center is still available."; return }
            isEnabled = true; defaults.set(true, forKey: "cameraAssistance")
            automaticRecoveryAllowed = true; lastAttemptEpoch = nil
            engine.configure(center: stored?.center)
            status = hasCenter ? "Camera assistance is on. Your saved screen direction will be checked when needed." : "Face the display and click Set center. Then make one short head turn to finish setup."
        }
    }
    func disable() {
        cancelBurst()
        isEnabled = false; defaults.set(false, forKey: "cameraAssistance")
        engine.invalidate(); isAligned = false
        status = "Camera assistance is off. Use Set center after reconnecting AirPods."
    }
    func cancelPendingRecovery() {
        automaticRecoveryAllowed = false
        cancelBurst()
        if isEnabled { status = "Camera is off. Refresh direction when you want to resume." }
    }
    func setSessionActive(_ active: Bool) {
        guard sessionActive != active else { return }
        sessionActive = active
        if !active {
            cancelBurst(); engine.invalidate(); isAligned = false; lastAttemptEpoch = nil
            if isEnabled { status = "Camera is off while your Mac is asleep or inactive." }
        }
    }
    func update(layoutKey: String) {
        self.layoutKey = layoutKey
        guard isEnabled, sessionActive else { return }
        if let phase {
            guard burstLayoutKey == layoutKey else {
                cancelBurst(); engine.invalidate(); isAligned = false
                status = "The display setup changed during the check. Face the display and Set center again."
                return
            }
            guard motion.fusionEpoch == burstEpoch, motion.isFresh else {
                let wasRecovery = phase == .recovery
                cancelBurst(); engine.invalidate(); isAligned = false
                if wasRecovery { lastAttemptEpoch = nil }
                status = wasRecovery ? "Waiting for AirPods before checking direction." : "AirPods changed during setup. Face the display and use Set center again."
                return
            }
            if burstStarted && !camera.isRunning {
                cancelBurst()
                status = "Camera check ended without a reliable direction. Keep your face visible and use Refresh direction, or Set center for setup."
                return
            }
            processPendingFrames()
            return
        }
        let aligned = trackingValid
        if isAligned != aligned { isAligned = aligned }
        guard let stored else { return }
        guard stored.layoutKey == layoutKey else {
            engine.invalidate()
            if isAligned { isAligned = false }
            let message = "The display setup changed. Face your reference display and Set center again."
            if status != message { status = message }
            return
        }
        guard !aligned, automaticRecoveryAllowed, motion.isFresh,
              lastAttemptEpoch != motion.fusionEpoch else { return }
        startBurst(.recovery)
    }
    func setCenter(layoutKey: String) {
        self.layoutKey = layoutKey
        guard isEnabled, sessionActive, motion.isFresh else {
            status = "Wear your AirPods and face the screen before setting its direction."
            return
        }
        automaticRecoveryAllowed = true
        engine.invalidate(); isAligned = false
        startBurst(.center)
    }
    func refreshDirection() {
        guard isEnabled, sessionActive, hasCenter else { return }
        automaticRecoveryAllowed = true; lastAttemptEpoch = nil
        engine.invalidate(); isAligned = false
        if motion.isFresh { startBurst(.recovery) }
    }
    func shutdown() { cancelBurst(); engine.invalidate() }

    private func startBurst(_ next: Phase) {
        cancelBurst()
        guard sessionActive, motion.isFresh else { return }
        phase = next; burstEpoch = motion.fusionEpoch; lastAttemptEpoch = motion.fusionEpoch
        burstLayoutKey = layoutKey
        isBusy = true
        status = next == .center ? "Face the screen and hold still while its direction is measured…" : "Hold your head briefly at its current angle while the camera restores direction…"
        let ticket = burstTicket
        Task { [weak self] in
            guard let self, burstTicket == ticket, phase != nil, sessionActive,
                  motion.isFresh, motion.fusionEpoch == burstEpoch else { return }
            do {
                burstStarted = true
                try await camera.startBurst(maxDuration: next == .center ? 20 : 12) { [weak self] frame in
                    guard let self, burstTicket == ticket, sessionActive, isEnabled, phase != nil else { return }
                    receive(frame, generation: ticket)
                }
                guard burstTicket == ticket else { return }
            } catch {
                guard burstTicket == ticket else { return }
                cancelBurst(); status = error.localizedDescription
            }
        }
    }
    private func cancelBurst() {
        burstTicket &+= 1
        camera.stop()
        phase = nil; burstStarted = false; burstEpoch = nil
        pending.removeAll(); setupPairs.removeAll(); setupNeutral = nil
        burstConfiguration = ""; isBusy = false
    }
    private func receive(_ frame: CameraAnchorFrame, generation: UInt64) {
        guard let capture = frame.captureHostTime, let yaw = frame.yawDegrees,
              let pitch = frame.pitchDegrees, let roll = frame.rollDegrees,
              let bounds = frame.faceBounds, bounds.width >= 0.12, bounds.height >= 0.12 else {
            pending.removeAll(); setupPairs.removeAll(); engine.discardCameraEvidence()
            if phase == .recovery { status = "The camera needs a clear view of one face. Your saved center has not changed." }
            return
        }
        if phase == .recovery, let stored,
           (stored.center.cameraID != frame.cameraID || stored.configurationID != frame.configurationID || stored.layoutKey != layoutKey) {
            cancelBurst(); engine.invalidate(); isAligned = false
            status = "The camera or display setup changed. Face the screen and Set center again."
            return
        }
        if !burstConfiguration.isEmpty, burstConfiguration != frame.configurationID {
            cancelBurst(); engine.invalidate(); isAligned = false
            status = "Camera framing changed during the check. Set center again with a fixed camera."
            return
        }
        burstConfiguration = frame.configurationID
        let sample = HeadingCameraSample(generation: generation, cameraID: frame.cameraID,
            captureHostTime: capture, receiptHostTime: frame.receiptHostTime,
            yawRadians: yaw * .pi / 180, pitchRadians: pitch * .pi / 180,
            rollRadians: roll * .pi / 180, confidence: Double(frame.detectionConfidence), faceCount: frame.faceCount)
        guard HeadingFusionEngine.isCameraSampleUsable(sample, now: now()) else {
            pending.removeAll(); setupPairs.removeAll(); engine.discardCameraEvidence()
            if phase == .recovery { status = "Keep one face visible with a modest head turn and tilt. The original center stays saved." }
            return
        }
        pending.append(sample)
        if pending.count > 6 { pending.removeFirst(pending.count - 6) }
    }
    private func processPendingFrames() {
        let time = now()
        var ready: [HeadingCameraSample] = []
        pending.removeAll { sample in
            if time - sample.captureHostTime > 0.8 { return true }
            if time >= sample.captureHostTime + 0.2 { ready.append(sample); return true }
            return false
        }
        for sample in ready {
            guard let phase else { return }
            guard HeadingFusionEngine.isCameraSampleUsable(sample, now: time),
                  let sensorYaw = engine.stableMotionYaw(atCameraCaptureTime: sample.captureHostTime, now: time) else { continue }
            if phase == .recovery {
                engine.addCamera(sample, now: time)
                if engine.heading(now: time) != nil {
                    cancelBurst(); isAligned = true
                    status = "Original screen direction restored. Camera is off."
                    return
                }
                continue
            }
            setupPairs.append((sample, sensorYaw))
            if setupPairs.count > 3 { setupPairs.removeFirst() }
            guard setupPairs.count == 3, let first = setupPairs.first, let last = setupPairs.last,
                  last.camera.captureHostTime - first.camera.captureHostTime >= 0.5,
                  last.camera.captureHostTime - first.camera.captureHostTime <= 1.2,
                  setupPairs.allSatisfy({ abs(Self.wrap($0.camera.yawRadians - first.camera.yawRadians)) < 3 * .pi / 180 && abs(Self.wrap($0.motionYaw - first.motionYaw)) < 3 * .pi / 180 }) else { continue }
            let cameraYaw = Self.mean(setupPairs.map { $0.camera.yawRadians })
            let motionYaw = Self.mean(setupPairs.map { $0.motionYaw })
            if phase == .center {
                if let old = stored, old.center.cameraID == sample.cameraID, old.configurationID == burstConfiguration, old.layoutKey == layoutKey {
                    finishCenter(cameraID: sample.cameraID, neutral: cameraYaw, sign: old.center.cameraSign, sample: sample, time: time)
                    return
                }
                setupNeutral = (cameraYaw, motionYaw, sample.cameraID, burstConfiguration)
                self.phase = .direction; setupPairs.removeAll()
                status = "Screen direction measured. Turn your head left or right, then hold briefly to finish setup."
            } else if let neutral = setupNeutral,
                      let sign = HeadingFusionEngine.learnedCameraSign(cameraDelta: Self.wrap(cameraYaw - neutral.cameraYaw), sensorDelta: Self.wrap(motionYaw - neutral.motionYaw)) {
                finishCenter(cameraID: neutral.cameraID, neutral: neutral.cameraYaw, sign: sign, sample: sample, time: time)
                return
            }
        }
    }
    private func finishCenter(cameraID: String, neutral: Double, sign: Double, sample: HeadingCameraSample, time: Double) {
        let center = HeadingCameraCenter(cameraID: cameraID, neutralYawRadians: Self.wrap(sign * neutral),
            cameraSign: sign, sensorSign: 1, revision: centerRevision + 1)
        let value = StoredCenter(center: center, layoutKey: layoutKey, configurationID: burstConfiguration)
        stored = value; centerRevision = center.revision
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "cameraScreenCenterV1") }
        engine.configure(center: center)
        // A new reference needs a fresh stable burst; configuring never assumes
        // the setup-ending turned pose is zero or restores a retired alignment.
        cancelBurst(); lastAttemptEpoch = nil; automaticRecoveryAllowed = true
        status = "Screen direction saved. Hold briefly to align the AirPods at your current angle."
    }
    private static func wrap(_ value: Double) -> Double { atan2(sin(value), cos(value)) }
    private static func mean(_ values: [Double]) -> Double {
        atan2(values.reduce(0) { $0 + sin($1) }, values.reduce(0) { $0 + cos($1) })
    }
}
