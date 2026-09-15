import SwiftUI

@main struct BlurOnsetDialTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { fatalError(label) } }
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
        for side in BlurTurnSide.allCases {
            check(BlurDialGeometry.headRotation(side: side, threshold: 18, liveYaw: 25, syncing: true) == -25,
                  "Live left yaw turns the illustration left regardless of edited threshold side")
            check(BlurDialGeometry.headRotation(side: side, threshold: 32, liveYaw: -20, syncing: true) == 20,
                  "Live right yaw turns the illustration right regardless of edited threshold side")
            check(BlurDialGeometry.headRotation(side: side, threshold: 32, liveYaw: nil, syncing: true) == 0,
                  "Pending camera alignment does not invent a live head pose")
            check(BlurDialGeometry.headRotation(side: side, threshold: 32, liveYaw: .nan, syncing: true) == 0,
                  "Invalid live yaw cannot reach a rendering transform")
            check(BlurDialGeometry.headRotation(side: side, threshold: 18, liveYaw: 25, syncing: false) == side.screenSign * 18,
                  "Stopping sync restores the selected threshold illustration even if a stale yaw remains")
        }
        check(BlurDialGeometry.headRotation(side: .left, threshold: 18, liveYaw: 120, syncing: true) == -60,
              "Extreme positive yaw remains bounded")
        check(BlurDialGeometry.headRotation(side: .right, threshold: 32, liveYaw: -120, syncing: true) == 60,
              "Extreme negative yaw remains bounded")
        print("PASS: \(checks) independent onset, one-sided dial, and live head preview checks")
    }
}
