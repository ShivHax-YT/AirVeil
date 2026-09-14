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
        // Image position is not head direction. A centered check uses the
        // same absolute yaw limit in setup and recovery, independent of crop.
        let yaw = abs(frame.yawDegrees!), pitch = abs(frame.pitchDegrees!), roll = abs(frame.rollDegrees!)
        if yaw > HeadingFusionEngine.centerYawToleranceDegrees {
            return snapshot(.offCenter, "Look straight ahead",
                "\(Int(yaw.rounded()))° from center. Aim within 5°.", .pose)
        }
        if pitch > 20 || roll > 15 {
            return snapshot(.offCenter, "Keep your head level", "Face straight ahead, then hold briefly.", .pose)
        }
        return snapshot(.holding, "Hold at center", "One quick camera and AirPods check.")
    }
    private static func clamp(_ value: Double) -> Double { value.isFinite ? min(1, max(-1, value)) : 0 }
}
