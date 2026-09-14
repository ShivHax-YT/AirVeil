import Foundation

@main struct AirPodsWearStateTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        var evidence = AirPodsWearEvidence(), time = 100.0
        func poll(_ mask: UInt8?, fresh: Bool = true, token: String = "headset") -> AirPodsWearTransition {
            time += 0.25
            return evidence.update(mask.map { .init(deviceToken: token, wornMask: $0, receipt: time) },
                freshMotion: fresh, now: time)
        }
        func confirm(_ mask: UInt8, fresh: Bool = true) -> AirPodsWearTransition {
            _ = poll(mask, fresh: fresh); return poll(mask, fresh: fresh)
        }
        check(confirm(0, fresh: false) == .unchanged && !evidence.isRemovalLatched,
              "Already out at startup is not a removal transition")
        check(confirm(3, fresh: false) == .unchanged && evidence.wornMask == nil,
              "Cached metadata cannot establish wearing without fresh headset motion")
        check(confirm(3) == .unchanged && evidence.wornMask == 3,
              "Stable dual-bud metadata plus real motion establishes wear")
        check(poll(2) == .unchanged && !evidence.isRemovalLatched,
              "A single transient left-out reading cannot trigger blackout")
        check(poll(3) == .unchanged && !evidence.isRemovalLatched,
              "A flicker back cancels the unconfirmed transition")
        check(confirm(2) == .removed && evidence.isRemovalLatched,
              "Removing the left bud is recognized even if right-bud motion continues")
        check(confirm(2) == .unchanged && evidence.isRemovalLatched,
              "Continued remaining-bud motion cannot undo removal")
        check(poll(nil) == .unchanged && evidence.isRemovalLatched && !evidence.hasCurrentMetadata,
              "Unavailable metadata never invents reinsertion")
        check(confirm(3) == .reworn && !evidence.isRemovalLatched,
              "Putting left back restores without waiting for a motion-source switch")
        check(confirm(1) == .removed && evidence.isRemovalLatched,
              "Removing the right bud follows the same path")
        check(confirm(0, fresh: false) == .unchanged && evidence.isRemovalLatched,
              "Removing the second bud keeps the same removal episode")
        check(confirm(2) == .reworn && !evidence.isRemovalLatched,
              "Reinserting one bud after both were removed ends blackout")
        check(confirm(0, fresh: false) == .removed && evidence.isRemovalLatched,
              "A one-bud wear session arms removal of its remaining bud")
        _ = poll(3, token: "another-headset"); _ = poll(3, token: "another-headset")
        check(evidence.isRemovalLatched && evidence.wornMask == 0,
              "Another connected headset cannot substitute for the removed pair")
        check(confirm(1) == .reworn && !evidence.isRemovalLatched,
              "Original device reinsertion remains recoverable after ambiguity")
        check(confirm(3) == .unchanged && evidence.wornMask == 3,
              "Adding a second bud without removal does not emit a false event")
        check(confirm(0, fresh: false) == .removed, "Both-out transition emits one removal")
        evidence.noteExplicitReconnect()
        check(evidence.isRemovalLatched && evidence.wornMask == 0,
              "Transport reconnection cannot erase a positive per-bud removal")
        check(confirm(3) == .reworn, "Stable real reinsertion still restores after transport reconnection")
        time += 1
        let stale = AirPodsWearReading(deviceToken: "headset", wornMask: 0, receipt: time - 1)
        check(evidence.update(stale, freshMotion: true, now: time) == .unchanged && !evidence.isRemovalLatched,
              "Old metadata is never a current removal")
        check(confirm(4) == .unchanged && !evidence.isRemovalLatched, "Unsupported masks fail to unknown")
        evidence.reset()
        check(!evidence.isRemovalLatched && evidence.wornMask == nil, "Manual recovery clears anonymous evidence")
        print("PASS: \(checks) per-AirPod wear-state assertions; no Bluetooth, sensor, or screen access")
    }
}
