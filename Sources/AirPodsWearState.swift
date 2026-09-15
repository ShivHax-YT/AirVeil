import Foundation

/// Public headphone-motion availability, not individual ear identification.
/// Removing both AirPods normally stops the stream with Automatic Ear Detection.
/// A sustained connection loss or device handoff can look identical, so a camera
/// seat check decides the display action. Continuous one-bud motion never counts.
enum AirPodsWearSessionState: String { case unknown, worn, removed }
enum AirPodsWearTransition { case unchanged, removed, reworn }

struct AirPodsMotionWearEvidence {
    private(set) var state = AirPodsWearSessionState.unknown
    private(set) var armed = false
    private(set) var lossStarted: TimeInterval?
    private var firstFreshReceipt: TimeInterval?
    private var latestFreshReceipt: TimeInterval?
    private var lastNow: TimeInterval?
    let wearStability: TimeInterval
    let lossGrace: TimeInterval

    init(wearStability: TimeInterval = 0.75, lossGrace: TimeInterval = 0.35) {
        self.wearStability = wearStability
        self.lossGrace = lossGrace
    }

    var isRemovalLatched: Bool { state == .removed }

    mutating func reset() {
        state = .unknown; armed = false; lossStarted = nil
        firstFreshReceipt = nil; latestFreshReceipt = nil; lastNow = nil
    }

    mutating func update(monitoringAvailable: Bool, freshMotionReceipt: TimeInterval?,
                         now: TimeInterval) -> AirPodsWearTransition {
        guard monitoringAvailable, now.isFinite, now >= 0,
              lastNow.map({ now >= $0 }) ?? true else {
            reset()
            return .unchanged
        }
        lastNow = now
        if let receipt = freshMotionReceipt, receipt.isFinite, receipt >= 0,
           receipt <= now, now - receipt <= 0.65 {
            let returning = isRemovalLatched
            if lossStarted != nil || firstFreshReceipt == nil { firstFreshReceipt = receipt }
            lossStarted = nil
            state = .worn
            if latestFreshReceipt.map({ receipt > $0 }) ?? true {
                latestFreshReceipt = receipt
                if let firstFreshReceipt, receipt - firstFreshReceipt >= wearStability { armed = true }
            }
            // Restoring owned brightness is safe as soon as genuine fresh
            // motion returns. A full new stable session rearms the next loss.
            return returning ? .reworn : .unchanged
        }
        firstFreshReceipt = nil
        guard armed || isRemovalLatched else { state = .unknown; return .unchanged }
        guard !isRemovalLatched else { return .unchanged }
        if lossStarted == nil { lossStarted = now }
        guard let lossStarted, now - lossStarted >= lossGrace else { return .unchanged }
        state = .removed; armed = false
        return .removed
    }
}
