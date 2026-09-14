import Foundation
import CoreGraphics

@main struct PresenceTrackerTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1; if !condition() { fatalError(message) }
        }
        let reference = PresenceSeatReference(cameraID: "builtin", configurationID: "fixed-vga",
            faceBounds: CGRect(x: 0.4, y: 0.6, width: 0.2, height: 0.2), captureHostTime: 1)
        let seated = PresenceBody(bounds: CGRect(x: 0.25, y: 0.05, width: 0.5, height: 0.8), confidence: 0.95)
        let side = PresenceBody(bounds: CGRect(x: 0.72, y: 0.1, width: 0.27, height: 0.75), confidence: 0.99)
        let background = PresenceBody(bounds: CGRect(x: 0.43, y: 0.45, width: 0.14, height: 0.3), confidence: 0.99)
        func frame(_ time: Double, bodies: [PresenceBody], faces: [CGRect] = [], usable: Bool = true,
                   camera: String = "builtin", config: String = "fixed-vga") -> PresenceObservation {
            PresenceObservation(cameraID: camera, configurationID: config, captureHostTime: time,
                receiptHostTime: time + 0.02, bodies: bodies, faces: faces, analysisUsable: usable)
        }
        for posture in ["front", "profile", "back"] {
            var tracker = PresenceTracker(reference: reference)
            for index in 0..<3 {
                let t = 10 + Double(index) * 0.34
                _ = tracker.observe(frame(t, bodies: [seated], faces: posture == "front" ? [reference.faceBounds] : []), now: t + 0.02)
            }
            check(tracker.snapshot.state == .present, "Foreground upper-body evidence accepts \(posture) without a yaw or face requirement")
        }
        do {
            var tracker = PresenceTracker(reference: reference)
            for i in 0..<3 { let t = 20 + Double(i) * 0.34; _ = tracker.observe(frame(t, bodies: [], faces: [reference.faceBounds]), now: t + 0.02) }
            check(tracker.snapshot.state == .present, "A clear foreground face can confirm presence when the torso is cropped")
        }
        for gapDetection in ["refresh", "arrival"] {
            var tracker = PresenceTracker(reference: reference)
            for i in 0..<3 { let t = 23 + Double(i) * 0.34; _ = tracker.observe(frame(t, bodies: [], faces: [reference.faceBounds]), now: t + 0.02) }
            check(tracker.snapshot.state == .present, "Face-only presence is established before the \(gapDetection) gap")
            if gapDetection == "refresh" {
                check(tracker.tick(now: 25).state == .unknown, "A refresh gap invalidates face-only presence")
            }
            for i in 0..<3 {
                let t = 25.2 + Double(i) * 0.34
                _ = tracker.observe(frame(t, bodies: [], faces: [reference.faceBounds]), now: t + 0.02)
                check(tracker.snapshot.state == .unknown,
                    "Matching faces after a \(gapDetection) gap cannot inherit or reacquire the old occupant")
            }
            tracker = PresenceTracker(reference: reference)
            for i in 0..<3 { let t = 27 + Double(i) * 0.34; _ = tracker.observe(frame(t, bodies: [], faces: [reference.faceBounds]), now: t + 0.02) }
            check(tracker.snapshot.state == .present, "A new wear-session check can confirm face-only presence again")
        }
        for people in [[side], [background], [side, background]] {
            var tracker = PresenceTracker(reference: reference)
            for i in 0..<7 { let t = 30 + Double(i) * 0.34; _ = tracker.observe(frame(t, bodies: people), now: t + 0.02) }
            check(tracker.snapshot.state == .absent, "Side and background people cannot become the foreground occupant")
        }
        do {
            var tracker = PresenceTracker(reference: reference)
            for i in 0..<3 { let t = 40 + Double(i) * 0.34; _ = tracker.observe(frame(t, bodies: [seated, side, background]), now: t + 0.02) }
            check(tracker.snapshot.state == .present, "Unrelated side/background people do not invalidate one unambiguous foreground target")
            for i in 0..<7 { let t = 41.02 + Double(i) * 0.34; _ = tracker.observe(frame(t, bodies: [side, background]), now: t + 0.02) }
            check(tracker.snapshot.state == .absent, "Remaining bystanders cannot keep an absent foreground target present")
            _ = tracker.observe(frame(43.4, bodies: [seated]), now: 43.42)
            check(tracker.snapshot.state == .absent, "Confirmed departure is latched; a new occupant cannot reactivate the removed-headphones session")
        }
        do {
            var tracker = PresenceTracker(reference: reference)
            for i in 0..<3 { let t = 50 + Double(i) * 0.34; _ = tracker.observe(frame(t, bodies: [seated]), now: t + 0.02) }
            let shifted = PresenceBody(bounds: seated.bounds.offsetBy(dx: 0.1, dy: 0), confidence: 0.9)
            _ = tracker.observe(frame(51.02, bodies: [shifted]), now: 51.02 + 0.02)
            check(tracker.snapshot.state == .present, "Small continuous foreground movement retains the same anonymous track")
            _ = tracker.observe(frame(51.36, bodies: [shifted, seated]), now: 51.36 + 0.02)
            check(tracker.snapshot.state == .unknown, "Overlapping plausible people produce uncertainty instead of choosing a new wearer")
        }
        do {
            var tracker = PresenceTracker(reference: reference)
            for i in 0..<3 { let t = 60 + Double(i) * 0.34; _ = tracker.observe(frame(t, bodies: [seated]), now: t + 0.02) }
            check(tracker.tick(now: 62).state == .unknown, "A frame outage cannot keep stale presence alive")
            _ = tracker.observe(frame(62.2, bodies: [seated]), now: 62.2 + 0.02)
            check(tracker.snapshot.state == .unknown, "A continuity gap cannot silently adopt whoever appears afterward")
        }
        do {
            var tracker = PresenceTracker(reference: reference)
            for i in 0..<7 { let t = 70 + Double(i) * 0.34; _ = tracker.observe(frame(t, bodies: [], usable: false), now: t + 0.02) }
            check(tracker.snapshot.state == .unknown, "Unusable dark/failed analysis does not prove absence")
            check(tracker.tick(now: 75).state == .unknown, "Elapsed time alone cannot prove departure")
        }
        do {
            var tracker = PresenceTracker(reference: reference)
            for i in 0..<7 { let t = 76 + Double(i) * 0.34; _ = tracker.observe(frame(t, bodies: [side], usable: false), now: t + 0.02) }
            check(tracker.snapshot.state == .unknown, "A lit bystander cannot prove that the dark foreground seat is empty")
            for i in 0..<3 { let t = 78.38 + Double(i) * 0.34; _ = tracker.observe(frame(t, bodies: [seated], usable: false), now: t + 0.02) }
            check(tracker.snapshot.state == .present, "A confident foreground detection stays useful even with a dark overall frame")
        }
        do {
            var tracker = PresenceTracker(reference: reference)
            let repeated = frame(80, bodies: [])
            for _ in 0..<10 { _ = tracker.observe(repeated, now: 80.02) }
            check(tracker.snapshot.state == .unknown, "Repeated capture timestamps cannot manufacture departure evidence")
            _ = tracker.observe(frame(79.5, bodies: [seated]), now: 80.02)
            check(tracker.snapshot.state == .unknown, "Out-of-order camera evidence cannot adopt a target")
            _ = tracker.observe(frame(80.34, bodies: [seated], config: "changed"), now: 80.36)
            check(tracker.snapshot.state == .unknown && tracker.snapshot.status.contains("framing"), "Changed camera framing invalidates the reference")
        }
        check(PresenceTracker.isReferenceUsable(reference, now: 8 * 60 * 60), "An unchanged seat reference remains useful hours into the current wear session")
        print("PASS: \(checks) anonymous presence geometry checks; synthetic observations only")
    }
}
