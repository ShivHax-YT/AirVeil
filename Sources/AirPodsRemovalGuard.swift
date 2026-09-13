import Foundation

/// An explicit headphone disconnect may mean ear removal or Bluetooth loss.
/// Sample gaps and calibration changes never enter this policy as removals.
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
            reset(disconnectCount: disconnectCount)
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
