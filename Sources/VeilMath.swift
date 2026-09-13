import Foundation

struct VeilStrength: Equatable {
    var left: Double
    var right: Double
    static let zero = VeilStrength(left: 0, right: 0)
    static let full = VeilStrength(left: 1, right: 1)
}

/// Detects growing delivery lag without assuming that the headphone timestamp
/// epoch exactly matches host uptime. This cannot prove the absolute age of the
/// first sample: an already-buffered initial stream establishes its own offset.
struct VeilSampleClock {
    private(set) var minimumOffset: TimeInterval?

    mutating func addedLag(source: TimeInterval, receipt: TimeInterval) -> TimeInterval? {
        guard source.isFinite, receipt.isFinite, source >= 0, receipt >= 0 else { return nil }
        let offset = receipt - source
        guard offset.isFinite else { return nil }
        let baseline = min(minimumOffset ?? offset, offset)
        minimumOffset = baseline
        return max(0, offset - baseline)
    }

    mutating func reset() { minimumOffset = nil }
}

/// Small, framework-independent orientation value for validation and tests.
struct VeilQuaternion: Equatable {
    var x: Double
    var y: Double
    var z: Double
    var w: Double

    var normalized: VeilQuaternion? {
        guard [x, y, z, w].allSatisfy(\.isFinite) else { return nil }
        let length = sqrt(x*x + y*y + z*z + w*w)
        guard length.isFinite, length > 1e-9 else { return nil }
        return VeilQuaternion(x: x/length, y: y/length, z: z/length, w: w/length)
    }

    /// q and -q represent the same attitude; use the shortest rotation.
    func angularDistance(to other: VeilQuaternion) -> Double? {
        guard let a = normalized, let b = other.normalized else { return nil }
        let dot = abs(a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w)
        return 2 * acos(min(1, max(0, dot)))
    }
}

enum VeilMath {
    /// Monotonic receipt age, evaluated by the consumer as well as a watchdog.
    /// A future timestamp or invalid timeout is never evidence of freshness.
    static func isRecent(receipt: TimeInterval?, now: TimeInterval, timeout: TimeInterval) -> Bool {
        guard let receipt, receipt.isFinite, now.isFinite, timeout.isFinite,
              receipt >= 0, now >= receipt, timeout > 0 else { return false }
        return now - receipt < timeout
    }

    /// Invalid inputs cannot constitute evidence of privacy: caller must use its
    /// explicit tracking-loss state. This pure mapping always returns finite data.
    static func target(yawDegrees: Double, onset: Double = 8, full: Double = 32, wholeScreen: Bool = false) -> VeilStrength {
        guard yawDegrees.isFinite, onset.isFinite, full.isFinite,
              onset >= 0, full > onset else { return .zero }
        let t = min(1, max(0, (abs(yawDegrees) - onset) / (full - onset)))
        let strength = t * t * (3 - 2*t)
        // Both modes retain direction. The renderer uses the coverage choice to
        // interpret each channel as half-screen strength or full-screen sweep progress.
        return yawDegrees > 0 ? VeilStrength(left: 0, right: strength)
                              : VeilStrength(left: strength, right: 0)
    }

    /// Exact first-order response per channel; release takes twice the attack
    /// time. The coordinator handles suspension/staleness before calling this.
    static func advance(current: VeilStrength, target: VeilStrength,
                        dt: Double, response: Double = 0.07) -> VeilStrength {
        func bounded(_ value: Double) -> Double {
            value.isFinite ? min(1, max(0, value)) : 0
        }
        func channel(_ value: Double, _ goal: Double) -> Double {
            let value = bounded(value), goal = bounded(goal)
            guard dt.isFinite, dt > 0, response.isFinite, response > 0 else { return value }
            let tau = goal > value ? response : response * 2
            let alpha = -expm1(-dt / tau)
            return bounded(value + alpha * (goal - value))
        }
        return VeilStrength(left: channel(current.left, target.left),
                            right: channel(current.right, target.right))
    }

    static func wrappedRadians(_ radians: Double) -> Double? {
        guard radians.isFinite else { return nil }
        return atan2(sin(radians), cos(radians))
    }

    /// Z-axis Euler yaw from an already-relative quaternion. The Core Motion
    /// adapter obtains that quaternion using Apple's multiply(byInverseOf:).
    static func yawRadians(_ quaternion: VeilQuaternion) -> Double? {
        guard let q = quaternion.normalized else { return nil }
        return atan2(2 * (q.w*q.z + q.x*q.y), 1 - 2 * (q.y*q.y + q.z*q.z))
    }
}
