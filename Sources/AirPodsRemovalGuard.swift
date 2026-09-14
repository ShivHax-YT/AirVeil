import Foundation

/// The caller supplies validated per-bud loss. The historical disconnected
/// labels describe the removal-policy state, not the transport. Audio handoff,
/// disconnect callbacks, sample gaps, and calibration changes are not removals.
struct AirPodsRemovalGuard {
    private(set) var armed = false
    private(set) var deadline: TimeInterval?
    private var observedDisconnectCount: UInt64?
    let delay: TimeInterval

    init(delay: TimeInterval = 1.5) { self.delay = delay }

    mutating func reset(disconnectCount: UInt64) {
        armed = false
        deadline = nil
        observedDisconnectCount = disconnectCount
    }

    mutating func update(enabled: Bool, running: Bool, connected: Bool,
                         disconnected: Bool, freshMotion: Bool,
                         disconnectCount: UInt64, now: TimeInterval) -> Bool {
        guard enabled, running, now.isFinite else {
            reset(disconnectCount: disconnectCount)
            return false
        }
        let newDisconnect = observedDisconnectCount.map { $0 != disconnectCount } ?? false
        observedDisconnectCount = disconnectCount
        if connected {
            deadline = nil
            if freshMotion { armed = true }
            return false
        }
        guard disconnected else {
            // Transport may disappear before its final ear-state observation.
            // Unknown never triggers an action, but retain prior worn evidence
            // so a later confirmed removal can still receive its full delay.
            deadline = nil
            return false
        }
        if newDisconnect && (armed || deadline != nil) {
            armed = false
            deadline = now + delay
        }
        guard let deadline, now >= deadline else { return false }
        self.deadline = nil
        return true
    }
}
