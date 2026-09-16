import Foundation

enum NotchCoachPhase: String, Equatable, Sendable {
    case idle, starting, seeking, offCenter, holding, turning, lighting, success, failure
}
enum NotchCoachDirection: String, Equatable, Sendable { case left, right, up, down }
enum NotchCoachRetryAction: String, Equatable, Sendable { case enableCamera, setCenter, refreshDirection }
enum NotchCoachIssue: String, Equatable, Sendable {
    case faceMissing, multipleFaces, lowLight, framing, pose, motion, configuration, camera
}

struct NotchCoachSnapshot: Equatable, Sendable {
    var phase: NotchCoachPhase = .idle
    var title = ""
    var detail = ""
    var progress = 0.0
    /// Coordinates of the face in the mirrored thumbnail, relative to center.
    /// Negative x is left; negative y is up. Directions point toward center.
    var horizontalError = 0.0
    var verticalError = 0.0
    var direction: NotchCoachDirection?
    var issue: NotchCoachIssue?
    var retryAction: NotchCoachRetryAction?
    var needsLightHelp = false
    var isAssistLightOn = false
}

/// Presentation guidance never grants an alignment. Only the coordinator's
/// paired camera/motion evidence can move the presentation to success.
enum NotchCoachGuidance {
    static func observation(_ frame: CameraAnchorFrame, requiresFrontalPose: Bool,
                            previous: NotchCoachSnapshot? = nil) -> NotchCoachSnapshot {
        let bounds = frame.faceBounds
        // VGA is aspect-filled into a square circular thumbnail. Its central
        // 480px are visible, so map x to the crop rather than the 640px source.
        let x = bounds.map { clamp((1 - 2 * $0.midX) * 4 / 3) } ?? 0
        let y = bounds.map { clamp(1 - 2 * $0.midY) } ?? 0
        func snapshot(_ phase: NotchCoachPhase, _ title: String, _ detail: String,
                      _ issue: NotchCoachIssue? = nil, _ direction: NotchCoachDirection? = nil) -> NotchCoachSnapshot {
            NotchCoachSnapshot(phase: phase, title: title, detail: detail,
                horizontalError: x, verticalError: y, direction: direction, issue: issue)
        }
        if frame.faceCount > 1 {
            return snapshot(.seeking, "One face at a time", "Keep only your face in the camera view.", .multipleFaces)
        }
        // Darkness cannot establish presence. This only offers a manual light
        // during an already-active check; the coordinator debounces the offer.
        if frame.faceCount == 0, let brightness = frame.centerLuminance,
           brightness.isFinite, brightness >= 0, brightness < 0.16 {
            var result = snapshot(.lighting, "Too dark to find your face",
                "Try Face light, then keep facing the camera.", .lowLight)
            result.needsLightHelp = true
            return result
        }
        // Face-local automatic lighting still requires a plausible face.
        guard frame.faceCount == 1, let bounds,
              [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy({ $0.isFinite }),
              bounds.width > 0, bounds.height > 0,
              frame.detectionConfidence.isFinite, frame.detectionConfidence >= 0.3,
              frame.detectionConfidence <= 1 else {
            return snapshot(.seeking, "Looking for your face", "Face the camera and keep your face visible.", .faceMissing)
        }
        guard bounds.width >= 0.12, bounds.height >= 0.12 else {
            return snapshot(.offCenter, "Come a little closer", "Keep your face inside the camera view.", .framing)
        }
        // A measured turn asks for a turn back, even in darkness. Lighting
        // assistance is reserved for a face whose direction cannot be read.
        if let measuredYaw = frame.yawDegrees, measuredYaw.isFinite,
           abs(measuredYaw) > HeadingFusionEngine.centerYawToleranceDegrees {
            return snapshot(.offCenter, "Look straight ahead",
                "\(Int(abs(measuredYaw).rounded()))° from center. Aim within 5°.", .pose)
        }
        if let pitch = frame.pitchDegrees, pitch.isFinite, abs(pitch) > 20 {
            return snapshot(.offCenter, "Keep your head level", "Face straight ahead, then hold briefly.", .pose)
        }
        if let roll = frame.rollDegrees, roll.isFinite, abs(roll) > 15 {
            return snapshot(.offCenter, "Keep your head level", "Face straight ahead, then hold briefly.", .pose)
        }
        let hasPose = [frame.yawDegrees, frame.pitchDegrees, frame.rollDegrees].allSatisfy { $0?.isFinite == true }
        let confidenceIsGood = frame.detectionConfidence >= 0.7
        if !hasPose || !confidenceIsGood {
            if let luminance = frame.luminance, luminance.isFinite, luminance >= 0, luminance < 0.18 {
                var result = snapshot(.lighting, "Light too low", "Your face is visible. Add light to read its direction.", .lowLight)
                result.needsLightHelp = true
                return result
            }
            return snapshot(.seeking, "Reading your direction", "Face the camera and keep your head level.", .pose)
        }
        return snapshot(.holding, "Hold at center", "One quick camera and AirPods check.")
    }
    private static func clamp(_ value: Double) -> Double { value.isFinite ? min(1, max(-1, value)) : 0 }
}
