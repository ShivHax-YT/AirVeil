import Foundation

@main
struct MotionMathTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ description: String) {
            checks += 1
            guard condition() else { fatalError("FAIL: \(description)") }
        }
        func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-10) -> Bool {
            a.isFinite && b.isFinite && abs(a-b) <= tolerance
        }
        func pose(_ yaw: Double) -> VeilQuaternion {
            VeilQuaternion(x: 0, y: 0, z: sin(yaw/2), w: cos(yaw/2))
        }
        check(VeilMath.isRecent(receipt: 10, now: 10.1, timeout: 0.65), "Fresh receipt accepted")
        check(!VeilMath.isRecent(receipt: 10, now: 10.7, timeout: 0.65), "Age expires without a watchdog callback")
        check(!VeilMath.isRecent(receipt: 10, now: 11, timeout: 1), "Freshness threshold is exclusive")
        check(!VeilMath.isRecent(receipt: nil, now: 10, timeout: 1), "Missing receipt rejected")
        check(!VeilMath.isRecent(receipt: 11, now: 10, timeout: 1), "Future receipt rejected")
        check(!VeilMath.isRecent(receipt: -1, now: 0, timeout: 1), "Negative receipt rejected")
        for invalid in [Double.nan, .infinity, -.infinity] {
            check(!VeilMath.isRecent(receipt: invalid, now: 10, timeout: 1), "Invalid receipt rejected")
            check(!VeilMath.isRecent(receipt: 10, now: invalid, timeout: 1), "Invalid clock rejected")
            check(!VeilMath.isRecent(receipt: 10, now: 10, timeout: invalid), "Invalid timeout rejected")
        }
        check(!VeilMath.isRecent(receipt: 10, now: 10, timeout: 0), "Zero timeout rejected")
        var sourceClock = VeilSampleClock()
        check(sourceClock.addedLag(source: 100, receipt: 1000) == 0, "Different timestamp epochs establish offset")
        check(near(sourceClock.addedLag(source: 100.1, receipt: 1000.12)!, 0.02), "Small transport variation measured")
        check(sourceClock.addedLag(source: 100.2, receipt: 1001.2)! > 0.65, "Increasing but buffered source timestamps detected")
        check(sourceClock.addedLag(source: 100.3, receipt: 1001.3)! > 0.65, "Late stream does not replace healthy baseline")
        check(near(sourceClock.addedLag(source: 101.4, receipt: 1001.42)!, 0.02), "Caught-up stream recovers against original offset")
        check(sourceClock.addedLag(source: 102, receipt: 1001.99) == 0, "Lower transport delay improves baseline")
        check(sourceClock.addedLag(source: .nan, receipt: 1002) == nil, "Invalid source clock rejected")
        sourceClock.reset()
        check(sourceClock.minimumOffset == nil, "Source change resets clock baseline")
        check(sourceClock.addedLag(source: 1, receipt: 2000) == 0, "New source epoch accepted after explicit reset")
        check(VeilMath.target(yawDegrees: 0) == .zero, "Neutral is clear")
        for angle in [-8.0, -5, 5, 8] {
            check(VeilMath.target(yawDegrees: angle) == .zero, "Dead zone includes onset \(angle)")
        }
        check(VeilMath.target(yawDegrees: 20) == VeilStrength(left: 0, right: 0.5), "Left turn reaches right midpoint")
        check(VeilMath.target(yawDegrees: -20) == VeilStrength(left: 0.5, right: 0), "Right turn reaches left midpoint")
        for angle in [32.0, 45, 180, Double.greatestFiniteMagnitude] {
            check(VeilMath.target(yawDegrees: angle) == VeilStrength(left: 0, right: 1), "Left saturates right \(angle)")
            check(VeilMath.target(yawDegrees: -angle) == VeilStrength(left: 1, right: 0), "Right saturates left \(angle)")
        }
        check(VeilMath.target(yawDegrees: 0, wholeScreen: true) == .zero, "Whole screen is clear at center")
        check(VeilMath.target(yawDegrees: 20, wholeScreen: true) == VeilStrength(left: 0, right: 0.5), "Whole screen left turn drives right-to-left sweep")
        check(VeilMath.target(yawDegrees: -20, wholeScreen: true) == VeilStrength(left: 0.5, right: 0), "Whole screen right turn drives left-to-right sweep")
        check(VeilMath.target(yawDegrees: 32, wholeScreen: true) == VeilStrength(left: 0, right: 1), "Whole screen left turn completes directional sweep")
        check(VeilMath.target(yawDegrees: -50, wholeScreen: true) == VeilStrength(left: 1, right: 0), "Whole screen right turn completes directional sweep")
        check(VeilMath.target(yawDegrees: .nan, wholeScreen: true) == .zero, "Whole screen rejects invalid input")
        var previous = 0.0
        for step in 0...1000 {
            let angle = Double(step) / 20
            let positive = VeilMath.target(yawDegrees: angle)
            let negative = VeilMath.target(yawDegrees: -angle)
            check(positive.right >= previous && positive.right <= 1, "Monotonic bounded coverage")
            check(positive.left == 0 && negative.right == 0 && positive.right == negative.left, "Symmetric opposite-side mapping")
            previous = positive.right
        }
        for invalid in [Double.nan, .infinity, -.infinity] {
            check(VeilMath.target(yawDegrees: invalid) == .zero, "Invalid yaw sanitized")
            check(VeilMath.target(yawDegrees: 20, onset: invalid) == .zero, "Invalid onset rejected")
            check(VeilMath.target(yawDegrees: 20, full: invalid) == .zero, "Invalid full angle rejected")
        }
        check(VeilMath.target(yawDegrees: 20, onset: -1, full: 30) == .zero, "Negative onset rejected")
        check(VeilMath.target(yawDegrees: 20, onset: 30, full: 30) == .zero, "Equal thresholds rejected")
        check(VeilMath.target(yawDegrees: 20, onset: 30, full: 8) == .zero, "Reversed thresholds rejected")
        let right = VeilStrength(left: 0, right: 1)
        let left = VeilStrength(left: 1, right: 0)
        let attack = VeilMath.advance(current: .zero, target: right, dt: 0.07)
        check(near(attack.right, 1-exp(-1)), "Attack time constant")
        let release = VeilMath.advance(current: right, target: .zero, dt: 0.14)
        check(near(release.right, exp(-1)), "Release twice attack time constant")
        let reversal = VeilMath.advance(current: right, target: left, dt: 1/60)
        check(reversal.left > 0 && reversal.left < 1 && reversal.right > 0 && reversal.right < 1, "Reversal crossfades both channels without teleportation")

        func timeline(fps: Int) -> VeilStrength {
            var current = VeilStrength.zero
            // Aligned target changes exercise both activation and reversal.
            for goal in [right, left, VeilStrength.zero] {
                for _ in 0..<fps { current = VeilMath.advance(current: current, target: goal, dt: 1/Double(fps)) }
            }
            return current
        }
        let baseline = timeline(fps: 30)
        for fps in [60, 120, 240] {
            let result = timeline(fps: fps)
            check(near(result.left, baseline.left) && near(result.right, baseline.right), "Timing invariant at \(fps) Hz")
        }
        for invalid in [0.0, -1, .nan, .infinity, -.infinity] {
            check(VeilMath.advance(current: right, target: left, dt: invalid) == right, "Invalid dt holds current")
            check(VeilMath.advance(current: right, target: left, dt: 0.1, response: invalid) == right, "Invalid response holds current")
        }
        let sanitized = VeilMath.advance(current: VeilStrength(left: .nan, right: 5),
                                         target: VeilStrength(left: -.infinity, right: -3), dt: 0.1)
        check(sanitized.left == 0 && sanitized.right >= 0 && sanitized.right <= 1, "Nonfinite and out-of-range channels stay bounded")
        check(VeilMath.advance(current: .zero, target: right, dt: 1000) == right, "Large valid time settles without overshoot")
        check(near(VeilMath.wrappedRadians(358 * .pi/180)!, -2 * .pi/180), "Positive wrap crosses branch cut")
        check(near(VeilMath.wrappedRadians(-358 * .pi/180)!, 2 * .pi/180), "Negative wrap crosses branch cut")
        check(VeilMath.wrappedRadians(.nan) == nil, "Invalid wrap rejected")
        for angle in [-179.0, -90, -30, 0, 30, 90, 179] {
            check(near(VeilMath.yawRadians(pose(angle * .pi/180))!, angle * .pi/180), "Relative quaternion yaw \(angle)")
        }
        let original = pose(0.75)
        let negated = VeilQuaternion(x: -original.x, y: -original.y, z: -original.z, w: -original.w)
        check(near(original.angularDistance(to: negated)!, 0), "Quaternion double cover is same attitude")
        check(near(pose(179 * .pi/180).angularDistance(to: pose(-179 * .pi/180))!, 2 * .pi/180), "Quaternion distance crosses wrap by shortest arc")
        let scaled = VeilQuaternion(x: 0, y: 0, z: original.z*2, w: original.w*2)
        check(near(VeilMath.yawRadians(scaled)!, 0.75), "Normalize valid quaternion scale")
        check(VeilMath.yawRadians(VeilQuaternion(x: 0, y: 0, z: 0, w: 0)) == nil, "Zero quaternion rejected")
        check(VeilMath.yawRadians(VeilQuaternion(x: .nan, y: 0, z: 0, w: 1)) == nil, "Nonfinite quaternion rejected")
        // Rotation about X alone must not masquerade as a horizontal turn.
        check(near(VeilMath.yawRadians(VeilQuaternion(x: sin(0.2), y: 0, z: 0, w: cos(0.2)))!, 0), "Pure roll has zero yaw")
        print("PASS: \(checks) motion/math assertions (synthetic; hardware direction remains unverified)")
    }
}
