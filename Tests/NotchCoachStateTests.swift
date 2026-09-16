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
                   luminance: Double? = nil, centerLuminance: Double? = nil) -> CameraAnchorFrame {
            CameraAnchorFrame(cameraID: "test", configurationID: "fixed", faceCount: faces,
                yawDegrees: yaw, pitchDegrees: pitch, rollDegrees: 0, detectionConfidence: confidence,
                faceBounds: bounds, captureHostTime: 10, receiptHostTime: 10, processedHostTime: 10, luminance: luminance, centerLuminance: centerLuminance)
        }
        let centered = NotchCoachGuidance.observation(frame(), requiresFrontalPose: true)
        check(centered.phase == .holding && centered.progress == 0 && centered.direction == nil,
              "A frontal face invites holding but cannot claim alignment or timed progress")
        let cropped = NotchCoachGuidance.observation(frame(bounds: CGRect(x: 0.4, y: 0.3, width: 0.3, height: 0.4)), requiresFrontalPose: true)
        check(abs(cropped.horizontalError + 0.1 * 4 / 3) < 0.0001,
              "Horizontal offset follows the square aspect-fill crop of the VGA preview")
        for requiresSetup in [true, false] {
            for yaw in [-15.0, -13.0, -5.01, 5.01, 13.0, 15.0] {
                let state = NotchCoachGuidance.observation(frame(yaw: yaw), requiresFrontalPose: requiresSetup)
                check(state.phase == .offCenter && state.issue == .pose && state.progress == 0,
                      "Both setup and recovery reject yaw beyond the absolute five-degree center gate")
                check(state.detail.contains("5°"), "The correction states the actual center buffer")
            }
            for yaw in [-5.0, 0, 5] {
                let state = NotchCoachGuidance.observation(frame(yaw: yaw), requiresFrontalPose: requiresSetup)
                check(state.phase == .holding && state.progress == 0,
                      "Within-buffer pose requests one hold but cannot grant calibration")
            }
        }
        let side = NotchCoachGuidance.observation(frame(bounds: CGRect(x: 0.7, y: 0.3, width: 0.2, height: 0.4)), requiresFrontalPose: true)
        check(side.phase == .holding && side.horizontalError < 0 && side.direction == nil,
              "Thumbnail position retains mirrored coordinates without becoming a head-angle gate")
        check(NotchCoachGuidance.observation(frame(pitch: 25), requiresFrontalPose: false).phase == .offCenter,
              "Excessive pitch asks for a level head before recovery")
        check(NotchCoachGuidance.observation(frame(luminance: 0.05), requiresFrontalPose: true).issue == nil,
              "A confident usable face never gets a spurious low-light warning")
        check(NotchCoachGuidance.observation(frame(confidence: 0.45, luminance: 0.05), requiresFrontalPose: true).issue == .lowLight,
              "Measured darkness combined with poor confidence provides light guidance")
        for luminance: Double? in [nil, .nan, -1, 0.01, 0.6] {
            check(NotchCoachGuidance.observation(frame(faces: 0, yaw: nil, luminance: luminance), requiresFrontalPose: true).issue == .faceMissing,
                  "Missing, invalid, or adequate brightness never becomes a low-light claim")
        }
        check(NotchCoachGuidance.observation(frame(faces: 2, luminance: 0.05), requiresFrontalPose: true).issue == .multipleFaces,
              "Multiple visible faces request one wearer even in a dim frame")
        check(NotchCoachGuidance.observation(frame(bounds: CGRect(x: 0.48, y: 0.48, width: 0.05, height: 0.05)), requiresFrontalPose: true).issue == .framing,
              "A distant tiny face cannot provide a usable hold")
        let darkSearch = NotchCoachGuidance.observation(frame(faces: 0, yaw: nil, bounds: nil, centerLuminance: 0.05), requiresFrontalPose: true)
        check(darkSearch.phase == .lighting && darkSearch.needsLightHelp && darkSearch.progress == 0,
              "Central darkness can offer light without claiming a detected face")
        for brightness: Double? in [nil, .nan, .infinity, -1, 0.16, 0.5, 1.2] {
            check(NotchCoachGuidance.observation(frame(faces: 0, centerLuminance: brightness), requiresFrontalPose: true).issue == .faceMissing,
                  "Invalid or bright central measurements cannot offer light")
        }
        check(NotchCoachGuidance.observation(frame(faces: 2, centerLuminance: 0.01), requiresFrontalPose: true).issue == .multipleFaces,
              "Dark central readings never override multiple-face guidance")
        check(NotchCoachGuidance.observation(frame(centerLuminance: 0.01), requiresFrontalPose: true).phase == .holding,
              "A usable face takes priority over central darkness")
        let dimPose = NotchCoachGuidance.observation(frame(yaw: nil, luminance: 0.08), requiresFrontalPose: true)
        check(dimPose.phase == .lighting && dimPose.needsLightHelp && !dimPose.isAssistLightOn,
              "A visible close face with unreadable pose in measured darkness offers a default-off light card")
        check(NotchCoachGuidance.observation(frame(yaw: nil, confidence: 0.2, luminance: 0.02), requiresFrontalPose: true).issue == .faceMissing,
              "Very weak face evidence cannot claim a wearer needs illumination")
        check(NotchCoachGuidance.observation(frame(yaw: 22, confidence: 0.45, luminance: 0.02), requiresFrontalPose: true).issue == .pose,
              "An observable off-axis turn asks for center rather than blaming the light")
        check(NotchCoachGuidance.observation(frame(yaw: nil, bounds: CGRect(x: 0.48, y: 0.48, width: 0.05, height: 0.05), luminance: 0.02), requiresFrontalPose: true).issue == .framing,
              "A far-away dim face asks for proximity and cannot offer illumination")
        check(NotchCoachGuidance.observation(frame(yaw: nil, luminance: 0.5), requiresFrontalPose: true).issue == .pose,
              "Unreadable direction with adequate illumination never becomes a lighting failure")
        print("PASS: \(checks) notch guidance, mirrored geometry, and measured-light checks")
    }
}
