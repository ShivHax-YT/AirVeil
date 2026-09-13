import Foundation

@main struct NotchCoachStateTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { fatalError(message) }
        }
        func frame(faces: Int = 1, yaw: Double? = 0, pitch: Double? = 0, confidence: Float = 0.95,
                   bounds: CGRect? = CGRect(x: 0.35, y: 0.3, width: 0.3, height: 0.4),
                   luminance: Double? = nil) -> CameraAnchorFrame {
            CameraAnchorFrame(cameraID: "test", configurationID: "fixed", faceCount: faces,
                yawDegrees: yaw, pitchDegrees: pitch, rollDegrees: 0, detectionConfidence: confidence,
                faceBounds: bounds, captureHostTime: 10, receiptHostTime: 10, processedHostTime: 10, luminance: luminance)
        }
        let centered = NotchCoachGuidance.observation(frame(), requiresFrontalPose: true)
        check(centered.phase == .holding && centered.progress == 0 && centered.direction == nil,
              "A frontal face invites holding but cannot claim alignment or timed progress")
        let cropped = NotchCoachGuidance.observation(frame(bounds: CGRect(x: 0.4, y: 0.3, width: 0.3, height: 0.4)), requiresFrontalPose: true)
        check(abs(cropped.horizontalError + 0.1 * 4 / 3) < 0.0001,
              "Horizontal offset follows the square aspect-fill crop of the VGA preview")
        let outside = NotchCoachGuidance.observation(frame(bounds: CGRect(x: 0.505, y: 0.3, width: 0.3, height: 0.4)), requiresFrontalPose: true)
        let borderlineFrame = frame(bounds: CGRect(x: 0.475, y: 0.3, width: 0.3, height: 0.4))
        check(NotchCoachGuidance.observation(borderlineFrame, requiresFrontalPose: true).phase == .holding &&
              NotchCoachGuidance.observation(borderlineFrame, requiresFrontalPose: true, previous: outside).phase == .offCenter,
              "A correction has an inner release boundary to avoid guide flicker")
        for (bounds, direction, axis, sign) in [
            (CGRect(x: 0.05, y: 0.3, width: 0.2, height: 0.4), NotchCoachDirection.left, "x", 1.0),
            (CGRect(x: 0.75, y: 0.3, width: 0.2, height: 0.4), NotchCoachDirection.right, "x", -1.0),
            (CGRect(x: 0.35, y: 0.02, width: 0.3, height: 0.2), NotchCoachDirection.up, "y", 1.0),
            (CGRect(x: 0.35, y: 0.78, width: 0.3, height: 0.2), NotchCoachDirection.down, "y", -1.0)
        ] {
            let state = NotchCoachGuidance.observation(frame(bounds: bounds), requiresFrontalPose: true)
            check(state.phase == .offCenter && state.direction == direction,
                  "Preview correction points toward the middle on \(axis) axis")
            check((axis == "x" ? state.horizontalError : state.verticalError) * sign > 0,
                  "Guide errors follow the mirrored, top-origin thumbnail coordinates")
        }
        check(NotchCoachGuidance.observation(frame(yaw: 30), requiresFrontalPose: true).issue == .pose,
              "Explicit screen center cannot accept a substantial head turn")
        check(NotchCoachGuidance.observation(frame(yaw: 30), requiresFrontalPose: false).phase == .holding,
              "Recovery accepts the current modest turn without redefining screen center")
        check(NotchCoachGuidance.observation(frame(pitch: 25), requiresFrontalPose: false).phase == .offCenter,
              "Excessive pitch asks for a level head before recovery")
        check(NotchCoachGuidance.observation(frame(luminance: 0.05), requiresFrontalPose: true).issue == nil,
              "A confident usable face never gets a spurious low-light warning")
        check(NotchCoachGuidance.observation(frame(confidence: 0.2, luminance: 0.05), requiresFrontalPose: true).issue == .lowLight,
              "Measured darkness combined with poor confidence provides light guidance")
        for luminance: Double? in [nil, .nan, -1, 0.6] {
            check(NotchCoachGuidance.observation(frame(faces: 0, yaw: nil, luminance: luminance), requiresFrontalPose: true).issue == .faceMissing,
                  "Missing, invalid, or adequate brightness never becomes a low-light claim")
        }
        check(NotchCoachGuidance.observation(frame(faces: 2, luminance: 0.05), requiresFrontalPose: true).issue == .multipleFaces,
              "Multiple visible faces request one wearer even in a dim frame")
        check(NotchCoachGuidance.observation(frame(bounds: CGRect(x: 0.48, y: 0.48, width: 0.05, height: 0.05)), requiresFrontalPose: true).issue == .framing,
              "A distant tiny face cannot provide a usable hold")
        print("PASS: \(checks) notch guidance, mirrored geometry, and measured-light checks")
    }
}
