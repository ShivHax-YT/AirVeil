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
    @Published private(set) var coach = NotchCoachSnapshot()
    let notchMotion: NotchMotionFeedback
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
    private var holdEvidence: [HeadingCameraSample] = []
    private var successDismissal: Task<Void, Never>?
    private var lastFrameReceipt: Double?
    private var lowLightFrames = 0

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
        notchMotion = NotchMotionFeedback(now: now)
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
            guard let self else { return }
            self.notchMotion.updateMotion(sample)
            guard self.isEnabled else { return }
            guard let sample else {
                self.engine.invalidate(); self.isAligned = false
                if self.coach.phase == .success { self.present(NotchCoachSnapshot()) }
                return
            }
            self.engine.addMotion(sample)
        }.store(in: &subscriptions)
    }

    /// The only permission request entry point; invoked by the user's button.
    func requestEnable() {
        burstTicket &+= 1
        let ticket = burstTicket
        isBusy = true
        status = "Allow the Mac camera for brief, local direction checks."
        present(NotchCoachSnapshot(phase: .starting, title: "Allow the camera", detail: "Brief direction checks stay on your Mac."))
        Task { [weak self] in
            guard let self, burstTicket == ticket, sessionActive else { return }
            let allowed = await camera.requestPermission()
            guard burstTicket == ticket else { return }
            isBusy = false
            guard allowed else {
                status = "Camera access was not allowed. Manual Set center is still available."
                fail("Camera access is off", detail: "Allow camera access in System Settings to use camera guidance.", issue: .camera, retryAction: .enableCamera)
                return
            }
            isEnabled = true; defaults.set(true, forKey: "cameraAssistance")
            automaticRecoveryAllowed = true; lastAttemptEpoch = nil
            engine.configure(center: stored?.center)
            status = hasCenter ? "Camera assistance is on. Your saved screen direction will be checked when needed." : "Face the display and click Set center. Then make one short head turn to finish setup."
            present(NotchCoachSnapshot())
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
                fail("Display setup changed", detail: "Face this display and set your center again.", issue: .configuration, retryAction: .setCenter)
                return
            }
            guard motion.fusionEpoch == burstEpoch, motion.isFresh else {
                let wasRecovery = phase == .recovery
                cancelBurst(); engine.invalidate(); isAligned = false
                if wasRecovery { lastAttemptEpoch = nil }
                status = wasRecovery ? "Waiting for AirPods before checking direction." : "AirPods changed during setup. Face the display and use Set center again."
                if !wasRecovery { fail("AirPods changed", detail: "Wear your AirPods and set center again.", issue: .motion, retryAction: .setCenter) }
                return
            }
            if burstStarted && !camera.isRunning {
                let needsLight = coach.issue == .lowLight
                let action = retryAction(for: phase)
                cancelBurst()
                status = "Camera check ended without a reliable direction. Keep your face visible and use Refresh direction, or Set center for setup."
                fail(needsLight ? "A little more light" : "Try the direction check again",
                    detail: needsLight ? "Light your face, then retry the direction check." : "Keep your face visible and hold still briefly.",
                    issue: needsLight ? .lowLight : .camera, retryAction: action)
                return
            }
            if let lastFrameReceipt, now() - lastFrameReceipt > 0.8 {
                clearEvidence()
                present(NotchCoachSnapshot(phase: .seeking, title: "Waiting for a clear frame", detail: "Keep your face visible to the camera.", issue: .faceMissing))
            }
            processPendingFrames()
            return
        }
        let aligned = trackingValid
        if isAligned != aligned { isAligned = aligned }
        if !aligned, coach.phase == .success { present(NotchCoachSnapshot()) }
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
            fail("Waiting for AirPods", detail: "Wear your AirPods, then set center.", issue: .motion, retryAction: .setCenter)
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
        cancelBurst(clearCoach: false)
        guard sessionActive, motion.isFresh else { return }
        phase = next; burstEpoch = motion.fusionEpoch; lastAttemptEpoch = motion.fusionEpoch
        let feedbackReference = next == .recovery && stored?.layoutKey == layoutKey ? stored?.center : nil
        notchMotion.begin(reference: feedbackReference, sample: motion.fusionSample)
        burstLayoutKey = layoutKey
        isBusy = true
        status = next == .center ? "Face the screen and hold still while its direction is measured…" : "Hold your head briefly at its current angle while the camera restores direction…"
        present(NotchCoachSnapshot(phase: .starting, title: next == .center ? "Finding your center" : "Restoring direction",
            detail: "Starting a brief camera check."))
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
                let action = retryAction(for: phase ?? next)
                cancelBurst(); status = error.localizedDescription
                fail("Camera unavailable", detail: error.localizedDescription, issue: .camera, retryAction: action)
            }
        }
    }
    private func cancelBurst(clearCoach: Bool = true) {
        burstTicket &+= 1
        successDismissal?.cancel(); successDismissal = nil
        camera.stop()
        notchMotion.stop()
        phase = nil; burstStarted = false; burstEpoch = nil
        pending.removeAll(); setupPairs.removeAll(); setupNeutral = nil
        burstConfiguration = ""; isBusy = false
        holdEvidence.removeAll(); lastFrameReceipt = nil; lowLightFrames = 0
        if clearCoach { present(NotchCoachSnapshot()) }
    }
    private func receive(_ frame: CameraAnchorFrame, generation: UInt64) {
        notchMotion.updateCamera(frame)
        lastFrameReceipt = frame.receiptHostTime
        var guidance = NotchCoachGuidance.observation(frame, requiresFrontalPose: phase == .center, previous: coach)
        lowLightFrames = guidance.issue == .lowLight ? min(2, lowLightFrames + 1) : 0
        if guidance.issue == .lowLight && lowLightFrames < 2 {
            guidance.title = "Looking for your face"
            guidance.detail = "Face the camera and keep your face visible."
            guidance.issue = .faceMissing
        }
        if phase == .direction, guidance.issue == .pose {
            guidance.title = "Turn a little less"
            guidance.detail = "Keep your face visible, then hold at the turned angle."
        }
        // The notch's framing and pose hints are presentation, not additional
        // calibration gates. Explicit Set center measures the wearer's chosen
        // screen-facing pose; it does not require zero Vision yaw or a face at
        // the center of a cropped thumbnail. Keep the proven camera/motion
        // acceptance rules below as the only source of alignment evidence.
        guard let capture = frame.captureHostTime, let yaw = frame.yawDegrees,
              let pitch = frame.pitchDegrees, let roll = frame.rollDegrees,
              let bounds = frame.faceBounds, bounds.width >= 0.12, bounds.height >= 0.12 else {
            clearEvidence()
            presentRejectedFrame(guidance)
            return
        }
        if phase == .recovery, let stored,
           (stored.center.cameraID != frame.cameraID || stored.configurationID != frame.configurationID || stored.layoutKey != layoutKey) {
            cancelBurst(); engine.invalidate(); isAligned = false
            status = "The camera or display setup changed. Face the screen and Set center again."
            fail("Camera setup changed", detail: "Face this display and set your center again.", issue: .configuration, retryAction: .setCenter)
            return
        }
        if !burstConfiguration.isEmpty, burstConfiguration != frame.configurationID {
            cancelBurst(); engine.invalidate(); isAligned = false
            status = "Camera framing changed during the check. Set center again with a fixed camera."
            fail("Camera framing changed", detail: "Set center again with a fixed camera.", issue: .configuration, retryAction: .setCenter)
            return
        }
        burstConfiguration = frame.configurationID
        let sample = HeadingCameraSample(generation: generation, cameraID: frame.cameraID,
            captureHostTime: capture, receiptHostTime: frame.receiptHostTime,
            yawRadians: yaw * .pi / 180, pitchRadians: pitch * .pi / 180,
            rollRadians: roll * .pi / 180, confidence: Double(frame.detectionConfidence), faceCount: frame.faceCount)
        guard HeadingFusionEngine.isCameraSampleUsable(sample, now: now()) else {
            clearEvidence()
            presentRejectedFrame(guidance)
            return
        }
        // An accepted frame must not flash a red correction for a thumbnail
        // crop or a nonzero explicit neutral pose, then turn green when the
        // same frame is paired with motion. Publish the actual operation.
        if !holdEvidence.isEmpty {
            var updated = coach
            updated.horizontalError = guidance.horizontalError
            updated.verticalError = guidance.verticalError
            present(updated)
        } else if phase == .direction {
            var updated = coach.phase == .turning ? coach : NotchCoachSnapshot(phase: .turning,
                title: "Make one gentle head turn", detail: "Turn left or right, then hold briefly.")
            updated.horizontalError = guidance.horizontalError
            updated.verticalError = guidance.verticalError
            present(updated)
        } else {
            present(NotchCoachSnapshot(phase: .holding,
                title: phase == .center ? "Hold your head still" : "Restoring direction",
                detail: phase == .center ? "Measuring your screen direction." : "Hold briefly. Your saved center stays the same.",
                horizontalError: guidance.horizontalError, verticalError: guidance.verticalError))
        }
        pending.append(sample)
        if pending.count > 6 { pending.removeFirst(pending.count - 6) }
    }
    private func processPendingFrames() {
        let time = now()
        var ready: [HeadingCameraSample] = []
        pending.removeAll { sample in
            if time - sample.captureHostTime > 0.8 { return true }
            // A display tick can pass the time guard before the next AirPods
            // callback arrives. Keep the camera frame pending until an actual
            // motion receipt spans the far side of that guard; elapsed wall
            // time alone cannot satisfy the paired stationary window.
            if time >= sample.captureHostTime + 0.2,
               let motionSample = motion.fusionSample,
               motionSample.epoch == burstEpoch,
               motionSample.receiptHostTime >= sample.captureHostTime + 0.2 {
                ready.append(sample)
                return true
            }
            return false
        }
        for sample in ready {
            guard let phase else { return }
            guard HeadingFusionEngine.isCameraSampleUsable(sample, now: time),
                  let sensorYaw = engine.stableMotionYaw(atCameraCaptureTime: sample.captureHostTime, now: time) else {
                // Skip this unpaired frame, as acquisition did before the
                // notch coach. The fusion engine still checks the complete
                // stationary window; setup still bounds its own paired span.
                // A presentation reset must not retire earlier valid pairs.
                holdEvidence.removeAll()
                present(NotchCoachSnapshot(phase: phase == .direction ? .turning : .holding,
                    title: phase == .direction ? "Turn, then hold briefly" : "Hold your head still",
                    detail: "Waiting for steady AirPods motion.", issue: .motion))
                continue
            }
            addHoldEvidence(sample, sensorYaw: sensorYaw, phase: phase)
            if phase == .recovery {
                engine.addCamera(sample, now: time)
                if engine.heading(now: time) != nil {
                    cancelBurst(clearCoach: false); isAligned = true
                    status = "Original screen direction restored. Camera is off."
                    showSuccess()
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
                // Camera/sensor handedness belongs to the camera pipeline,
                // not the set of connected displays. Explicit Set center has
                // just measured a new neutral for this layout, so reuse a
                // previously learned sign when that pipeline is unchanged.
                if let old = stored, old.center.cameraID == sample.cameraID, old.configurationID == burstConfiguration {
                    finishCenter(cameraID: sample.cameraID, neutral: cameraYaw, sign: old.center.cameraSign, sample: sample, time: time)
                    return
                }
                setupNeutral = (cameraYaw, motionYaw, sample.cameraID, burstConfiguration)
                self.phase = .direction; setupPairs.removeAll()
                holdEvidence.removeAll()
                status = "Screen direction measured. Turn your head left or right, then hold briefly to finish setup."
                present(NotchCoachSnapshot(phase: .turning, title: "Make one gentle head turn", detail: "Turn left or right, then hold briefly."))
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
        cancelBurst(clearCoach: false); lastAttemptEpoch = nil; automaticRecoveryAllowed = true
        status = "Screen direction saved. Hold briefly to align the AirPods at your current angle."
        present(NotchCoachSnapshot(phase: .starting, title: "Restoring direction", detail: "Screen center saved. Hold briefly to align your AirPods."))
    }
    private func clearEvidence() {
        pending.removeAll(); setupPairs.removeAll(); holdEvidence.removeAll(); engine.discardCameraEvidence()
    }
    private func presentRejectedFrame(_ guidance: NotchCoachSnapshot) {
        let snapshot = guidance.issue != nil ? guidance : NotchCoachSnapshot(phase: .seeking,
            title: "Waiting for a usable frame", detail: "Keep your face visible and hold briefly.", issue: .camera)
        present(snapshot)
        status = snapshot.title + ". " + snapshot.detail
    }
    private func addHoldEvidence(_ sample: HeadingCameraSample, sensorYaw: Double, phase: Phase) {
        if phase == .direction, let neutral = setupNeutral,
           HeadingFusionEngine.learnedCameraSign(cameraDelta: Self.wrap(sample.yawRadians - neutral.cameraYaw),
               sensorDelta: Self.wrap(sensorYaw - neutral.motionYaw)) == nil {
            // Three steady frames at the original pose are not progress on
            // learning a turn. Let the wearer see motion on the independent
            // pose rail while explaining what evidence is still missing.
            holdEvidence.removeAll()
            var snapshot = coach
            snapshot.phase = .turning
            snapshot.title = "Turn a little farther"
            snapshot.detail = "Turn about 20° left or right, then hold briefly."
            snapshot.progress = 0
            snapshot.issue = nil; snapshot.direction = nil
            present(snapshot)
            status = snapshot.title + ". " + snapshot.detail
            return
        }
        if let first = holdEvidence.first, let last = holdEvidence.last,
           sample.captureHostTime - last.captureHostTime > 0.5 ||
           sample.captureHostTime <= last.captureHostTime ||
           abs(Self.wrap(sample.yawRadians - first.yawRadians)) > 2 * .pi / 180 {
            holdEvidence.removeAll()
        }
        holdEvidence.append(sample)
        if holdEvidence.count > 3 { holdEvidence.removeFirst() }
        var snapshot = coach
        snapshot.phase = phase == .direction ? .turning : .holding
        snapshot.title = phase == .center ? "Hold your head still" : (phase == .direction ? "Hold at this angle" : "Restoring direction")
        snapshot.detail = phase == .recovery ? "Your saved screen center stays the same." : "Measuring camera and AirPods together."
        snapshot.progress = min(0.9, Double(holdEvidence.count) / 3)
        snapshot.issue = nil; snapshot.direction = nil
        present(snapshot)
    }
    private func present(_ snapshot: NotchCoachSnapshot) {
        if coach != snapshot { coach = snapshot }
    }
    private func retryAction(for phase: Phase) -> NotchCoachRetryAction {
        camera.refreshAuthorization()
        if camera.authorization != .authorized { return .enableCamera }
        return phase == .recovery ? .refreshDirection : .setCenter
    }
    private func fail(_ title: String, detail: String, issue: NotchCoachIssue, retryAction: NotchCoachRetryAction) {
        present(NotchCoachSnapshot(phase: .failure, title: title, detail: detail, issue: issue, retryAction: retryAction))
    }
    private func showSuccess() {
        present(NotchCoachSnapshot(phase: .success, title: "Direction restored", detail: "You're ready. Camera is off.", progress: 1))
        let ticket = burstTicket
        successDismissal = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_100_000_000) } catch { return }
            guard let self, self.burstTicket == ticket, self.coach.phase == .success else { return }
            self.present(NotchCoachSnapshot())
        }
    }
    private static func wrap(_ value: Double) -> Double { atan2(sin(value), cos(value)) }
    private static func mean(_ values: [Double]) -> Double {
        atan2(values.reduce(0) { $0 + sin($1) }, values.reduce(0) { $0 + cos($1) })
    }
}
