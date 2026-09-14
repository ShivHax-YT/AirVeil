import Foundation

@main struct AirPodsRemovalGuardTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { fatalError(label) }
        }
        var guardState = AirPodsRemovalGuard()
        func update(_ time: Double, _ connected: Bool, _ disconnected: Bool,
                    _ fresh: Bool, _ count: UInt64, enabled: Bool = true, running: Bool = true) -> Bool {
            guardState.update(enabled: enabled, running: running, connected: connected,
                disconnected: disconnected, freshMotion: fresh, disconnectCount: count, now: time)
        }
        check(!update(0, false, true, false, 1), "Already absent at launch must not trigger")
        check(!update(10, true, false, false, 1) && !guardState.armed, "Connect alone is not worn motion proof")
        check(!update(11, true, false, true, 1) && guardState.armed, "Real motion arms")
        check(!update(30, true, false, false, 1) && guardState.deadline == nil, "Sample gap does not imply removal")
        check(!update(31, false, true, false, 2) && guardState.deadline == 32.5, "Explicit disconnect starts delay")
        check(!update(32, true, false, false, 2) && guardState.deadline == nil, "Fast handoff cancels removal")
        check(!update(40, false, true, false, 3), "A handoff without any new motion cannot rearm")
        check(!update(41, true, false, true, 3), "Fresh reconnect rearms")
        check(!update(42, false, true, false, 4), "Next actual removal delays")
        check(!update(43.49, false, true, false, 4), "Not before delay")
        check(update(43.5, false, true, false, 4), "Fires at delay")
        check(!update(100, false, true, false, 4), "One shot while absent")
        check(!update(101, false, true, false, 5), "Duplicate disconnect cannot rearm")
        _ = update(110, true, false, true, 5)
        _ = update(111, false, true, false, 6)
        check(!update(112, false, true, false, 6, enabled: false), "Toggle off cancels")
        check(!update(120, false, true, false, 6), "Toggle on while absent does not trigger")
        _ = update(121, true, false, true, 6)
        _ = update(122, false, true, false, 7)
        check(!update(123, false, false, false, 7, running: false), "Sleep or explicit stop cancels")
        check(!update(130, false, true, false, 7), "Wake while absent does not trigger")
        _ = update(131, true, false, true, 7)
        _ = update(132, false, true, false, 8)
        guardState.reset(disconnectCount: 8)
        check(!update(140, false, true, false, 8), "Manual reset cancels")
        check(!update(.nan, true, false, true, 8) && !guardState.armed, "Invalid time disarms")
        _ = update(150, true, false, true, 8)
        _ = update(151, false, true, false, 9)
        check(!update(152, false, true, false, 10) && guardState.deadline == 153.5,
              "An unobserved rapid reconnect and newer disconnect restarts delay")
        check(!update(152.6, false, true, false, 10), "Old disconnect deadline cannot fire newer event")
        check(update(153.5, false, true, false, 10), "Latest event fires only after its own full delay")
        _ = update(160, true, false, true, 10)
        check(!update(161, false, false, false, 10) && guardState.armed && guardState.deadline == nil,
              "Unknown transport never acts and preserves the observed worn baseline")
        check(!update(200, false, false, false, 10), "Long idle audio never starts removal")
        check(!update(201, false, true, false, 11) && guardState.deadline == 202.5,
              "Confirmed ear loss arriving after disconnect still receives its delay")
        check(update(202.5, false, true, false, 11), "Only confirmed ear loss can complete removal after a transport gap")
        print("PASS: \(checks) AirPods removal policy assertions; no device or display actions")
    }
}
