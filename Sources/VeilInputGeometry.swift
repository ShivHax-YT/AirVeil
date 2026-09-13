import Foundation

struct VeilInputInterval: Equatable {
    let lower: Double
    let upper: Double
}

/// Pointer interception follows the same directional coverage as Veil.metal.
/// Results are normalized horizontal intervals; the controller reserves menu UI.
enum VeilInputGeometry {
    static let threshold = 0.05
    private static func bounded(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
    private static func smooth(_ value: Double) -> Double { let t = bounded(value); return t*t*(3-2*t) }
    private static func inverseSmooth(_ value: Double) -> Double {
        var low = 0.0, high = 1.0
        for _ in 0..<40 { let mid = (low+high)/2; if smooth(mid) < value { low = mid } else { high = mid } }
        return (low+high)/2
    }
    static func coverage(at x: Double, left: Double, right: Double, feather: Double, wholeScreen: Bool) -> Double {
        let l = bounded(left), r = bounded(right)
        let w = feather.isFinite ? min(0.5, max(0.001, feather)) : 0.12
        if !wholeScreen { return l + (r-l)*smooth((x-0.5+w/2)/w) }
        let a = smooth((x-1+(1+w)*r)/w)
        let b = smooth((-x+(1+w)*l)/w)
        return 1-(1-a)*(1-b)
    }
    static func intervals(left: Double, right: Double, feather: Double, wholeScreen: Bool,
                          blocksEntireDisplay: Bool = false, shield: Bool = false) -> [VeilInputInterval] {
        if shield { return [.init(lower: 0, upper: 1)] }
        let l = bounded(left), r = bounded(right)
        let w = feather.isFinite ? min(0.5, max(0.001, feather)) : 0.12
        func result(_ parts: [VeilInputInterval]) -> [VeilInputInterval] {
            let parts = parts.filter { $0.upper - $0.lower > 1e-9 }
            return blocksEntireDisplay && !parts.isEmpty ? [.init(lower: 0, upper: 1)] : parts
        }
        if !wholeScreen {
            if min(l,r) > threshold { return result([.init(lower:0,upper:1)]) }
            if max(l,r) <= threshold { return [] }
            let edge = bounded(0.5-w/2+w*inverseSmooth((threshold-l)/(r-l)))
            return result(l > r ? [.init(lower:0,upper:edge)] : [.init(lower:edge,upper:1)])
        }
        // Each directional mask contributes an edge interval. If those already
        // touch, their union covers the display. Otherwise examine the small
        // valley where both contributions are below the threshold: alpha union
        // can close that valley during reversal, and must not leave a click gap.
        let rightStart = bounded(1-(1+w)*r+w*inverseSmooth(threshold))
        let leftEnd = bounded((1+w)*l-w*inverseSmooth(threshold))
        if leftEnd >= rightStart { return result([.init(lower:0,upper:1)]) }
        func alpha(_ x: Double) -> Double { coverage(at:x,left:l,right:r,feather:w,wholeScreen:true) }
        var low = leftEnd, high = rightStart
        for _ in 0..<60 {
            let a = low+(high-low)/3, b = high-(high-low)/3
            if alpha(a) < alpha(b) { high = b } else { low = a }
        }
        let valley = (low+high)/2
        if alpha(valley) > threshold { return result([.init(lower:0,upper:1)]) }
        var parts: [VeilInputInterval] = []
        if alpha(0) > threshold {
            low = 0; high = valley
            for _ in 0..<40 { let mid = (low+high)/2; if alpha(mid) > threshold { low = mid } else { high = mid } }
            parts.append(.init(lower:0,upper:(low+high)/2))
        }
        if alpha(1) > threshold {
            low = valley; high = 1
            for _ in 0..<40 { let mid = (low+high)/2; if alpha(mid) > threshold { high = mid } else { low = mid } }
            parts.append(.init(lower:(low+high)/2,upper:1))
        }
        return result(parts)
    }
}
