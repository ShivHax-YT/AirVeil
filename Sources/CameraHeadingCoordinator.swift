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
    /// Anonymous geometry from a successfully accepted wearer check; no image
    /// or facial template is retained. Consumers may define the foreground seat.
    var onAcceptedFace: ((String, String, CGRect, Double) -> Void)?
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
    private var observedRemovalEvent: UInt64 = 0
    private(set) var automaticReturnCheckCount = 0
    private var burstTicket: UInt64 = 0
    private var phase: Phase?
    private var burstStarted = false
    private var pending: [HeadingCameraSample] = []
    private var pendingFaceBounds: [Double: CGRect] = [:]
    private var burstEpoch: UInt64?
    private var burstConfiguration = ""
    private var burstLayoutKey = ""
    private var holdEvidence: [HeadingCameraSample] = []
    private var successDismissal: Task<Void, Never>?
    private var lastFrameReceipt: Double?
    private var lowLightFrames = 0
    private var automaticLightAttempted = false
    private var lastLowLightCapture: Double?
    private var hadLiveAlignment = false
    private var lightMissingFaceFrames = 0

    private enum Phase { case center, recovery }
    private struct StoredCenter: Codable {
        let center: HeadingCameraCenter
        let layoutKey: String
        let configurationID: String
        var visualCameraSign: Double? = nil
    }
    var hasCenter: Bool { stored?.center.mode == .facingCamera }
    func visualCameraSign(cameraID: String, configurationID: String) -> Double? {
        guard let stored, stored.center.cameraID == cameraID, stored.configurationID == configurationID else { return nil }
        let sign = stored.center.mode == nil ? stored.center.cameraSign : stored.visualCameraSign
        guard let sign, abs(sign) == 1 else { return nil }
        return sign
    }
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
           abs(value.center.sensorSign) == 1,
           ((value.center.mode == nil && abs(value.center.cameraSign) == 1) ||
            (value.center.mode == .facingCamera && value.center.neutralYawRadians == 0 && value.center.cameraSign == 0)) {
            stored = value; centerRevision = value.center.revision
            engine.configure(center: value.center.mode == .facingCamera ? value.center : nil)
        }
        if isEnabled { status = hasCenter ? "Your screen direction is saved. Waiting for AirPods." : "Face the display and use Set center to set up camera assistance." }
        motion.$fusionSample.sink { [weak self] sample in
            guard let self else { return }
            self.notchMotion.updateMotion(sample)
            guard self.isEnabled else { return }
            guard let sample else {
                self.engine.invalidate(); self.isAligned = false
                if self.hadLiveAlignment {
                    self.hadLiveAlignment = false
                    self.status = "Tracking interrupted. Use Refresh direction when you are ready."
                }
                if self.coach.phase == .success { self.present(NotchCoachSnapshot()) }
                return
            }
            self.engine.addMotion(sample)
        }.store(in: &subscriptions)
    }

    /// The only permission request entry point; invoked by the user's button.
    func requestEnable() {
        guard sessionActive else {
            status = "Wake and unlock your Mac, then turn on Camera assistance again."
            return
        }
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
            engine.configure(center: hasCenter ? stored?.center : nil)
            status = hasCenter ? "Camera assistance is on. Your saved screen direction will be checked when needed." : "Face the camera straight on and click Set center. Hold still briefly to finish setup."
            present(NotchCoachSnapshot())
        }
    }
    func disable() {
        clearReturnRecoveryIntent()
        cancelBurst()
        isEnabled = false; defaults.set(false, forKey: "cameraAssistance")
        engine.invalidate(); isAligned = false
        status = "Camera assistance is off. Use Set center after reconnecting AirPods."
    }
    func cancelPendingRecovery() {
        automaticRecoveryAllowed = false
        clearReturnRecoveryIntent()
        cancelBurst()
        if isEnabled { status = "Camera is off. Refresh direction when you want to resume." }
    }
    private func clearReturnRecoveryIntent() {
        observedRemovalEvent = motion.removalEventCount
    }
    func setSessionActive(_ active: Bool) {
        guard sessionActive != active else { return }
        sessionActive = active
        if !active {
            cancelBurst(); engine.invalidate(); isAligned = false; lastAttemptEpoch = nil; hadLiveAlignment = false
            if isEnabled { status = "Camera is off while your Mac is asleep or inactive." }
        }
    }
    func update(layoutKey: String) {
        self.layoutKey = layoutKey
        guard isEnabled, sessionActive else { return }
        if motion.removalConnectionState == .disconnected {
            if phase != nil { cancelBurst() }
            engine.invalidate(); isAligned = false; hadLiveAlignment = false
            status = "AirPods motion stopped. Waiting for them to return before checking direction."
            return
        }
        // A sensor epoch is not a wear event: idle audio and Continuity can
        // change it repeatedly. Rearm only after a confirmed removal returns.
        let confirmedReturn = motion.removalEventCount != observedRemovalEvent &&
            motion.removalConnectionState == .connected && motion.isFresh
        if confirmedReturn {
            observedRemovalEvent = motion.removalEventCount
            cancelBurst(); engine.invalidate(); isAligned = false; hadLiveAlignment = false
            automaticRecoveryAllowed = true
            lastAttemptEpoch = nil
            automaticReturnCheckCount += 1
        }
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
                if wasRecovery { automaticRecoveryAllowed = false }
                status = wasRecovery ? "Tracking interrupted. Use Refresh direction when you are ready." : "AirPods changed during setup. Face the display and use Set center again."
                if !wasRecovery { fail("AirPods changed", detail: "Wear your AirPods and set center again.", issue: .motion, retryAction: .setCenter) }
                return
            }
            if burstStarted && !camera.isRunning {
                let lastGuidance = coach
                let needsLight = lastGuidance.issue == .lowLight
                let issue = lastGuidance.issue ?? .camera
                let title = needsLight ? "A little more light" : "Try the direction check again"
                let detail = needsLight ? "Light your face, then retry the direction check." :
                    (lastGuidance.issue != nil ? lastGuidance.title + ". " + lastGuidance.detail : "Keep your face visible and hold still briefly.")
                let action = retryAction(for: phase)
                cancelBurst()
                status = title + ". " + detail
                fail(title, detail: detail, issue: issue, retryAction: action)
                return
            }
            if let lastFrameReceipt, now() - lastFrameReceipt > 0.8 {
                camera.setAssistLightEnabled(false)
                clearEvidence()
                present(NotchCoachSnapshot(phase: .seeking, title: "Waiting for a clear frame", detail: "Keep your face visible to the camera.", issue: .faceMissing))
                syncMeasurementStatus()
            }
            processPendingFrames()
            return
        }
        let aligned = trackingValid
        // Losing alignment pauses blur without spending another camera check.
        if hadLiveAlignment && !aligned {
            hadLiveAlignment = false
            status = "Tracking interrupted. Use Refresh direction when you are ready."
        }
        if aligned { hadLiveAlignment = true }
        if isAligned != aligned { isAligned = aligned }
        if !aligned, coach.phase == .success { present(NotchCoachSnapshot()) }
        guard let stored else { return }
        guard stored.center.mode == .facingCamera else {
            let message = "Face the camera straight on and use Set center to replace the previous direction setup."
            if status != message { status = message }
            return
        }
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
    /// The card is offered only from repeated face-local low-light evidence.
    /// Turning on the light continues this same check; it cannot set center.
    func toggleAssistLight() {
        if camera.isAssistLightOn {
            automaticLightAttempted = true
            camera.setAssistLightEnabled(false)
            present(NotchCoachSnapshot(phase: phase == nil ? .idle : .seeking,
                title: "Reading your direction", detail: "Face light is off."))
            return
        }
        guard sessionActive, phase != nil, camera.isRunning,
              coach.phase == .lighting, coach.needsLightHelp else { return }
        guard camera.setAssistLightEnabled(true) else {
            present(NotchCoachSnapshot(phase: .lighting, title: "Face light unavailable",
                detail: "Use a light in front of you and keep facing the camera.", issue: .lowLight,
                needsLightHelp: true))
            return
        }
        clearEvidence(); lowLightFrames = 0; lightMissingFaceFrames = 0
        present(NotchCoachSnapshot(phase: .seeking, title: "Reading your direction",
            detail: "Face light is on. Keep looking at the camera."))
        syncMeasurementStatus()
    }

    /// Explicit Enable intent resumes a saved reference without replacing it
    /// and never restarts a valid alignment or an already-running check.
    func resumeTracking() {
        guard isEnabled, sessionActive, hasCenter else { return }
        guard !trackingValid, phase == nil else { return }
        automaticRecoveryAllowed = true
        lastAttemptEpoch = nil
        guard stored?.layoutKey == layoutKey else {
            status = "The display setup changed. Face your reference display and Set center again."
            return
        }
        if motion.isFresh { startBurst(.recovery) }
        else { status = "Waiting for AirPods before checking the saved screen direction." }
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
        automaticRecoveryAllowed = false
        automaticLightAttempted = false; lastLowLightCapture = nil
        let feedbackReference = next == .recovery && stored?.layoutKey == layoutKey ? stored?.center : nil
        notchMotion.begin(reference: feedbackReference, sample: motion.fusionSample)
        burstLayoutKey = layoutKey
        isBusy = true
        status = next == .center ? "Face the screen and hold still while its direction is measured…" : "Face the camera straight on and hold still while direction is checked…"
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
        pending.removeAll()
        pendingFaceBounds.removeAll()
        burstConfiguration = ""; isBusy = false
        holdEvidence.removeAll(); lastFrameReceipt = nil; lowLightFrames = 0; lightMissingFaceFrames = 0
        if clearCoach { present(NotchCoachSnapshot()) }
    }
    private func receive(_ frame: CameraAnchorFrame, generation: UInt64) {
        notchMotion.updateCamera(frame, visualCameraSign: visualCameraSign(cameraID: frame.cameraID, configurationID: frame.configurationID))
        lastFrameReceipt = frame.receiptHostTime
        var guidance = NotchCoachGuidance.observation(frame, requiresFrontalPose: phase == .center, previous: coach)
        // Old or untimed camera evidence cannot offer or activate a light.
        let time = now()
        let fresh = frame.captureHostTime.map { $0.isFinite && $0 >= 0 && $0 <= frame.receiptHostTime + 0.05 && time - $0 <= 0.8 } == true
            && frame.receiptHostTime.isFinite && frame.receiptHostTime <= time + 0.05 && time - frame.receiptHostTime <= 0.8
        if guidance.issue == .lowLight && !fresh {
            guidance.phase = .seeking; guidance.issue = .camera; guidance.needsLightHelp = false
            guidance.title = "Waiting for a clear frame"; guidance.detail = "Keep facing the camera."
        }
        if guidance.issue == .lowLight, fresh, let capture = frame.captureHostTime {
            if lastLowLightCapture.map({ capture > $0 }) ?? true {
                lowLightFrames = min(2, lowLightFrames + 1)
                lastLowLightCapture = capture
            }
        } else { lowLightFrames = 0; lastLowLightCapture = nil }
        // One automatic light attempt per camera burst. A repeated dark frame,
        // missing face, or manual Off cannot produce an illumination loop.
        if lowLightFrames >= 2, !automaticLightAttempted, !camera.isAssistLightOn,
           phase != nil, sessionActive, camera.isRunning {
            automaticLightAttempted = true
            if camera.setAssistLightEnabled(true) {
                clearEvidence(); lightMissingFaceFrames = 0
            }
        }
        if guidance.issue == .lowLight && (lowLightFrames < 2 || camera.isAssistLightOn) {
            guidance.phase = .seeking
            guidance.title = "Reading your direction"
            guidance.detail = camera.isAssistLightOn ? "Face light is on. Keep facing the camera." : "Keep facing the camera."
            guidance.issue = .pose
            guidance.needsLightHelp = false
        }
        let faceStillVisible = fresh && frame.faceCount == 1 && frame.faceBounds != nil && frame.detectionConfidence >= 0.3
        lightMissingFaceFrames = faceStillVisible ? 0 : min(2, lightMissingFaceFrames + 1)
        if camera.isAssistLightOn && lightMissingFaceFrames >= 2 { camera.setAssistLightEnabled(false) }
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
        guard HeadingFusionEngine.isCenteredCameraSampleUsable(sample, now: now()) else {
            clearEvidence()
            presentRejectedFrame(guidance)
            return
        }
        if !holdEvidence.isEmpty {
            var updated = coach
            updated.horizontalError = guidance.horizontalError
            updated.verticalError = guidance.verticalError
            present(updated)
        } else {
            present(NotchCoachSnapshot(phase: .holding, title: "Hold at center",
                detail: "Keep facing the camera straight on.",
                horizontalError: guidance.horizontalError, verticalError: guidance.verticalError))
        }
        syncMeasurementStatus()
        pending.append(sample)
        pendingFaceBounds[capture] = bounds
        if pending.count > 6 { pending.removeFirst(pending.count - 6) }
        pendingFaceBounds = pendingFaceBounds.filter { now() - $0.key <= 1.2 }
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
            guard HeadingFusionEngine.isCenteredCameraSampleUsable(sample, now: time),
                  engine.stableMotionYaw(atCameraCaptureTime: sample.captureHostTime, now: time) != nil else {
                holdEvidence.removeAll(); engine.discardCameraEvidence()
                present(NotchCoachSnapshot(phase: .holding, title: "Hold at center",
                    detail: "Waiting for steady AirPods motion.", issue: .motion))
                syncMeasurementStatus()
                continue
            }
            addHoldEvidence(sample)
            let reference: HeadingCameraCenter
            if phase == .recovery {
                guard let saved = stored?.center, saved.mode == .facingCamera else { return }
                reference = saved
            } else {
                reference = HeadingCameraCenter(cameraID: sample.cameraID, neutralYawRadians: 0,
                    cameraSign: 0, sensorSign: 1, revision: centerRevision + 1, mode: .facingCamera)
            }
            if engine.addCenteredCamera(sample, reference: reference, now: time) {
                if let bounds = pendingFaceBounds[sample.captureHostTime] {
                    onAcceptedFace?(sample.cameraID, burstConfiguration, bounds, sample.captureHostTime)
                }
                if phase == .center {
                    let sign = visualCameraSign(cameraID: sample.cameraID, configurationID: burstConfiguration)
                    let value = StoredCenter(center: reference, layoutKey: layoutKey,
                        configurationID: burstConfiguration, visualCameraSign: sign)
                    stored = value; centerRevision = reference.revision
                    if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "cameraScreenCenterV1") }
                }
                // The same verified batch installs the center and sensor offset.
                // Keep its motion history and alignment; never configure again
                // or start a second capture after completing this check.
                cancelBurst(clearCoach: false); isAligned = true; hadLiveAlignment = true
                status = "Facing-center check complete. Camera is off."
                showSuccess()
                return
            }
        }
    }
    private func clearEvidence() {
        pending.removeAll(); pendingFaceBounds.removeAll(); holdEvidence.removeAll(); engine.discardCameraEvidence()
    }
    private func presentRejectedFrame(_ guidance: NotchCoachSnapshot) {
        let snapshot = guidance.issue != nil ? guidance : NotchCoachSnapshot(phase: .seeking,
            title: "Waiting for a usable frame", detail: "Keep your face visible and hold briefly.", issue: .camera)
        present(snapshot)
        syncMeasurementStatus()
    }
    private func addHoldEvidence(_ sample: HeadingCameraSample) {
        if let first = holdEvidence.first, let last = holdEvidence.last,
           sample.captureHostTime - last.captureHostTime > 0.5 ||
           sample.captureHostTime <= last.captureHostTime ||
           abs(Self.wrap(sample.yawRadians - first.yawRadians)) > 2 * .pi / 180 {
            holdEvidence.removeAll()
        }
        holdEvidence.append(sample)
        holdEvidence.removeAll { sample.captureHostTime - $0.captureHostTime > 1.1 }
        let span = sample.captureHostTime - (holdEvidence.first?.captureHostTime ?? sample.captureHostTime)
        var snapshot = coach
        snapshot.phase = .holding
        snapshot.title = "Hold at center"
        snapshot.detail = "Measuring camera and AirPods together."
        snapshot.progress = min(0.9, span / HeadingFusionEngine.holdDurationSeconds)
        snapshot.issue = nil; snapshot.direction = nil
        present(snapshot)
        syncMeasurementStatus()
    }
    private func syncMeasurementStatus() {
        let message = coach.title + ". " + coach.detail
        if status != message { status = message }
    }
    private func present(_ newSnapshot: NotchCoachSnapshot) {
        var snapshot = newSnapshot
        snapshot.isAssistLightOn = camera.isAssistLightOn
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
        present(NotchCoachSnapshot(phase: .success, title: "Center confirmed", detail: "You're ready. Camera is off.", progress: 1))
        let ticket = burstTicket
        successDismissal = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_450_000_000) } catch { return }
            guard let self, self.burstTicket == ticket, self.coach.phase == .success else { return }
            self.present(NotchCoachSnapshot())
        }
    }
    private static func wrap(_ value: Double) -> Double { atan2(sin(value), cos(value)) }
    private static func mean(_ values: [Double]) -> Double {
        atan2(values.reduce(0) { $0 + sin($1) }, values.reduce(0) { $0 + cos($1) })
    }
}
