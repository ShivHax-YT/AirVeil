import SwiftUI

@main struct BlurOnsetDialTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { print("FAIL: \(label)"); exit(1) } }
        let center = CGPoint(x: 150, y: 10)
        for side in BlurTurnSide.allCases {
            for degree in 0...60 {
                let point = BlurDialGeometry.point(value: Double(degree), side: side, center: center, radius: 135)
                check((point.x - center.x) * side.screenSign >= 0, "Head control never enters opposite half")
                check(abs(BlurDialGeometry.value(at: point, side: side, center: center) - Double(degree)) < 0.0001, "Every tick roundtrips")
                let reflected = CGPoint(x: 2 * center.x - point.x, y: point.y)
                check(BlurDialGeometry.value(at: reflected, side: side, center: center) == 0, "Opposite-side drag clamps to zero")
            }
            check(BlurDialGeometry.value(at: CGPoint(x: center.x + side.screenSign * 1000, y: -200), side: side, center: center) == 60, "Beyond arc caps at maximum")
        }
        check(VeilMath.target(yawDegrees: 12, leftOnset: 15, rightOnset: 5) == .zero, "Left has independent onset")
        check(VeilMath.target(yawDegrees: -12, leftOnset: 15, rightOnset: 5).left > 0, "Right uses its own threshold")
        check(VeilMath.target(yawDegrees: 12, leftOnset: 5, rightOnset: 15).right > 0, "Left uses its own threshold")
        check(VeilMath.target(yawDegrees: -12, leftOnset: 5, rightOnset: 15) == .zero, "Right has independent onset")
        for fullScreen in [false, true] {
            check(VeilMath.target(yawDegrees: 10, leftOnset: 10, rightOnset: 20, wholeScreen: fullScreen) == .zero, "Exact left onset remains clear")
            check(VeilMath.target(yawDegrees: -20, leftOnset: 10, rightOnset: 20, wholeScreen: fullScreen) == .zero, "Exact right onset remains clear")
            check(VeilMath.target(yawDegrees: 32, leftOnset: 10, rightOnset: 20, wholeScreen: fullScreen).right == 1, "Full point remains full coverage")
        }
        for selectedSide in BlurTurnSide.allCases {
            var savedLeft = 18.0
            var savedRight = 32.0
            for yaw in -75...75 {
                let live = BlurDialFeedback(side: selectedSide, threshold: selectedSide == .left ? savedLeft : savedRight,
                                           liveYaw: Double(yaw), syncing: true)
                let markerSide: BlurTurnSide = live.arcYaw >= 0 ? .left : .right
                let point = BlurDialGeometry.point(value: abs(live.arcYaw), side: markerSide, center: center, radius: 135)
                check(live.showsMarker && !live.allowsEditing, "Every finite live angle has a read-only marker")
                check(abs(hypot(point.x - center.x, point.y - center.y) - 135) < 0.0001,
                      "Live marker stays on the curved track through both sides and center")
                check(yaw == 0 ? abs(point.x - center.x) < 0.0001 : (point.x - center.x) * Double(yaw) < 0,
                      "Positive physical left yaw moves left regardless of the selected onset side")
                check(abs(live.arcYaw) == min(60, abs(Double(yaw))), "Only the marker clamps at the arc endpoint")
                check(live.angleText == (yaw == 0 ? "0°" : String(format: "%+d°", yaw)),
                      "The large readout keeps the actual signed angle, including beyond the arc")
                check(live.isAtArcLimit == (abs(yaw) > 60), "Out-of-range telemetry explicitly explains the arc limit")
                if let changed = live.acceptedEdit(45) {
                    if selectedSide == .left { savedLeft = changed } else { savedRight = changed }
                }
                check(savedLeft == 18 && savedRight == 32, "Live packets and attempted edits leave both saved onsets unchanged")
            }
            let stopped = BlurDialFeedback(side: selectedSide, threshold: selectedSide == .left ? savedLeft : savedRight,
                                           liveYaw: -45, syncing: false)
            check(stopped.allowsEditing && stopped.showsMarker, "Stop sync returns the same control to editable onset mode")
            check(stopped.arcYaw == selectedSide.headingSign * (selectedSide == .left ? 18 : 32),
                  "Stopped sync restores the chosen saved threshold rather than the last live angle")
            check(stopped.angleText == (selectedSide == .left ? "18°" : "32°"), "Stopped readout describes the saved onset")
            check(stopped.acceptedEdit(61) == 60 && stopped.acceptedEdit(-1) == 0,
                  "Onset editing still enforces its zero-to-sixty range")
            for invalid in [Optional<Double>.none, .some(.nan), .some(.infinity), .some(-.infinity)] {
                let waiting = BlurDialFeedback(side: selectedSide, threshold: 18, liveYaw: invalid, syncing: true)
                check(waiting == .waiting && !waiting.showsMarker && !waiting.allowsEditing,
                      "Missing or nonfinite live evidence has no marker and no adjustable onset")
                check(waiting.angleText == "—" && waiting.caption == "Waiting for head tracking",
                      "Waiting never represents missing evidence as a measured zero")
                check(waiting.acceptedEdit(25) == nil, "Pending sync cannot alter an onset through drag or accessibility")
            }
        }
        for yaw in [-0.49, -0.0, 0.0, 0.49] {
            let centered = BlurDialFeedback(side: .left, threshold: 18, liveYaw: yaw, syncing: true)
            check(centered.angleText == "0°" && centered.caption == "Facing forward", "Rounded signed zero has neutral text")
            check(centered.accessibilityValue == "0 degrees, straight ahead", "VoiceOver never announces negative zero")
        }
        let leftLimit = BlurDialFeedback(side: .right, threshold: 32, liveYaw: 75, syncing: true)
        let rightLimit = BlurDialFeedback(side: .left, threshold: 18, liveYaw: -75, syncing: true)
        check(leftLimit.accessibilityValue == "75 degrees, left. Marker at the 60-degree arc limit", "Accessible live left reading reports actual angle and endpoint")
        check(rightLimit.accessibilityValue == "75 degrees, right. Marker at the 60-degree arc limit", "Accessible live right reading reports actual angle and endpoint")
        print("PASS: \(checks) independent onset, signed live arc/readout, waiting, and protected-edit checks; no sensors")
    }
}
