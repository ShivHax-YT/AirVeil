import Foundation

@main struct InputGeometryTests {
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition,message); checks += 1 }
        for whole in [false,true] {
            check(VeilInputGeometry.intervals(left:0,right:0,feather:0.12,wholeScreen:whole).isEmpty, "Neutral accepts input everywhere")
            check(VeilInputGeometry.intervals(left:0,right:0,feather:0.12,wholeScreen:whole,shield:true) == [.init(lower:0,upper:1)], "Shield intercepts selected display")
            for feather in [0.02,0.12,0.3] {
                for li in 0...40 {
                    for ri in 0...40 {
                        let left = Double(li)/40, right = Double(ri)/40
                        let parts = VeilInputGeometry.intervals(left:left,right:right,feather:feather,wholeScreen:whole)
                        check(parts.count <= 2 && parts.allSatisfy { $0.lower >= 0 && $0.upper <= 1 && $0.lower < $0.upper }, "Bounded at most two blocker rectangles")
                        for i in 0..<65 {
                            let x = (Double(i)+0.5)/65
                            let alpha = VeilInputGeometry.coverage(at:x,left:left,right:right,feather:feather,wholeScreen:whole)
                            let blocked = parts.contains { x > $0.lower && x < $0.upper }
                            if abs(alpha-VeilInputGeometry.threshold) > 1e-7 {
                                check(blocked == (alpha > VeilInputGeometry.threshold), "Input region must follow actual directional alpha")
                            }
                        }
                        let mirrored = VeilInputGeometry.intervals(left:right,right:left,feather:feather,wholeScreen:whole)
                        check(parts.count == mirrored.count, "Mirrored direction has same region count")
                        for (a,b) in zip(parts,mirrored.reversed()) {
                            check(abs(a.lower-(1-b.upper)) < 1e-7 && abs(a.upper-(1-b.lower)) < 1e-7, "Mirrored blocking must match both edges")
                        }
                        let entire = VeilInputGeometry.intervals(left:left,right:right,feather:feather,wholeScreen:whole,blocksEntireDisplay:true)
                        check(entire == (parts.isEmpty ? [] : [.init(lower:0,upper:1)]), "Entire-display mode activates only with visible blur")
                    }
                }
            }
        }
        check(VeilInputGeometry.intervals(left:.nan,right:.infinity,feather:.nan,wholeScreen:true).isEmpty, "Invalid values cannot create pointer interception")
        print("PASS: \(checks) input geometry checks, including neutral, full cover, mirrored sweeps, reversals, partial/full-display modes")
    }
}
