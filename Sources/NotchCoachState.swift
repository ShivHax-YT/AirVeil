import Foundation

enum NotchCoachPhase: String, Equatable, Sendable {
    case idle, starting, seeking, offCenter, holding, turning, success, failure
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
        let hasPose = [frame.yawDegrees, frame.pitchDegrees, frame.rollDegrees].allSatisfy { $0?.isFinite == true }
        let confidenceIsGood = frame.detectionConfidence.isFinite && frame.detectionConfidence >= 0.7 && frame.detectionConfidence <= 1
        let visible = frame.faceCount == 1 && bounds != nil && hasPose && confidenceIsGood
        if !visible {
            if let luminance = frame.luminance, luminance.isFinite, luminance >= 0, luminance < 0.18 {
                return snapshot(.seeking, "A little more light", "Light your face so the camera can see you.", .lowLight)
            }
            return snapshot(.seeking, "Looking for your face", "Face the camera and keep your face visible.", .faceMissing)
        }
        guard let bounds, bounds.width >= 0.12, bounds.height >= 0.12 else {
            return snapshot(.offCenter, "Come a little closer", "Keep your face inside the camera view.", .framing)
        }
        // Once shown, a correction remains until the face passes the inner
        // boundary. Small fluctuations at the outer boundary do not flicker.
        let previousHorizontal = previous?.direction == .left || previous?.direction == .right
        let previousVertical = previous?.direction == .up || previous?.direction == .down
        let horizontalLimit = previousHorizontal ? 0.30 : 0.36
        let verticalLimit = previousVertical ? 0.36 : 0.42
        if abs(x) > horizontalLimit || abs(y) > verticalLimit {
            let direction: NotchCoachDirection = abs(x) / horizontalLimit >= abs(y) / verticalLimit
                ? (x > 0 ? .left : .right) : (y > 0 ? .up : .down)
            return snapshot(.offCenter, "Move slightly \(direction.rawValue)", "Bring your face toward the middle of the preview.", .framing, direction)
        }
        let yaw = abs(frame.yawDegrees!), pitch = abs(frame.pitchDegrees!), roll = abs(frame.rollDegrees!)
        let poseOK = requiresFrontalPose ? (yaw <= 12 && pitch <= 12 && roll <= 10) : (yaw <= 45 && pitch <= 20 && roll <= 15)
        if !poseOK {
            // Vision yaw's physical sign is learned later. Do not guess a
            // left/right head-turn instruction before that calibration exists.
            return snapshot(.offCenter, "Face the display", "Look straight at the screen with your head level.", .pose)
        }
        return snapshot(.holding, requiresFrontalPose ? "Hold your head still" : "Restoring direction",
            requiresFrontalPose ? "Measuring your screen direction." : "Hold briefly. Your saved center stays the same.")
    }
    private static func clamp(_ value: Double) -> Double { value.isFinite ? min(1, max(-1, value)) : 0 }
}
