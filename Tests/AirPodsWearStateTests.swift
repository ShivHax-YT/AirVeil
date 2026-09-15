import Foundation

@main struct AirPodsWearStateTests {
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        var evidence = AirPodsMotionWearEvidence()
        func sample(_ now: Double, receipt: Double?, available: Bool = true) -> AirPodsWearTransition {
            evidence.update(monitoringAvailable: available, freshMotionReceipt: receipt, now: now)
        }
        check(sample(0, receipt: nil) == .unchanged && evidence.state == .unknown,
              "An empty startup cannot fabricate both-AirPods removal")
        _ = sample(1, receipt: 1); _ = sample(1.6, receipt: 1)
        check(!evidence.armed, "Reading the same cached motion sample cannot establish a stable session")
        _ = sample(2, receipt: nil); _ = sample(3, receipt: nil)
        check(!evidence.isRemovalLatched, "A single transient sample followed by silence does not arm")
        _ = sample(4, receipt: 4); _ = sample(4.4, receipt: 4.4); _ = sample(4.8, receipt: 4.8)
        check(evidence.armed && evidence.state == .worn, "Sustained fresh advancing motion arms a wear session")
        _ = sample(5.5, receipt: nil)
        check(sample(5.7, receipt: nil) == .unchanged && !evidence.isRemovalLatched,
              "A brief full-stream interruption waits through the loss grace")
        check(sample(5.75, receipt: 5.75) == .unchanged && evidence.state == .worn,
              "Fresh return before the grace expires cancels the pending loss")
        _ = sample(6, receipt: nil)
        check(sample(6.4, receipt: nil) == .removed && evidence.isRemovalLatched,
              "Only sustained total motion loss emits the removal proxy")
        check(sample(60, receipt: nil) == .unchanged && evidence.isRemovalLatched,
              "One uninterrupted absence emits one episode")
        check(sample(60.1, receipt: 60.1) == .reworn && evidence.state == .worn && !evidence.armed,
              "Genuine fresh return permits brightness restoration before rearming")
        _ = sample(60.8, receipt: nil); _ = sample(61.5, receipt: nil)
        check(!evidence.isRemovalLatched, "One return packet cannot arm another blackout")
        _ = sample(62, receipt: 62); _ = sample(62.8, receipt: 62.8)
        _ = sample(63.5, receipt: nil)
        check(sample(64, receipt: nil, available: false) == .unchanged && evidence.state == .unknown,
              "Stopped, denied, or failed monitoring cancels pending removal evidence")
        check(sample(80, receipt: nil) == .unchanged && !evidence.armed,
              "A resumed monitor without new wearing evidence cannot replay removal")
        _ = sample(81, receipt: 81); _ = sample(81.8, receipt: 81.8)
        check(evidence.armed, "A new real session can rearm after recovery")
        _ = sample(70, receipt: 70)
        check(!evidence.armed && evidence.state == .unknown, "A backwards clock resets the policy")
        _ = sample(.nan, receipt: nil)
        check(evidence.state == .unknown, "Invalid timing never arms a display action")
        print("PASS: \(checks) public-motion wear-session assertions; no Bluetooth, sensor, or screen access")
    }
}
