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
                   camera: String = "builtin", config: String = "fixed-vga", dark: Bool = false,
                   quality: PresenceFrameQuality? = PresenceFrameQuality(globalMean: 0.4, seatMean: 0.35,
                    seatDarkFraction: 0.05, seatContrast: 0.2, seatClippedFraction: 0, sampleCount: 192)) -> PresenceObservation {
            PresenceObservation(cameraID: camera, configurationID: config, captureHostTime: time,
                receiptHostTime: time + 0.02, bodies: bodies, faces: faces, analysisUsable: usable,
                needsLightAssistance: dark, frameQuality: quality)
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
            _ = tracker.observe(frame(90, bodies: [], usable: false, dark: true), now: 90.02)
            check(tracker.snapshot.isLowLight && tracker.snapshot.state == .unknown,
                  "Fresh measured darkness exposes a typed low-light condition without declaring absence")
            check(!tracker.tick(now: 92).isLowLight, "A stale dark frame cannot request brightness recovery")
            _ = tracker.observe(frame(92.2, bodies: [], usable: false), now: 92.22)
            check(!tracker.snapshot.isLowLight, "Unusable analysis without measured darkness is not low light")
            _ = tracker.observe(frame(92.54, bodies: [], usable: false, config: "changed", dark: true), now: 92.56)
            check(!tracker.snapshot.isLowLight, "A mismatched camera configuration cannot report actionable low light")
        }
        do {
            var tracker = PresenceTracker(reference: reference)
            for i in 0..<3 { let t = 100 + Double(i) * 0.34; _ = tracker.observe(frame(t, bodies: [seated]), now: t + 0.02) }
            for i in 0..<35 {
                let t = 101.02 + Double(i) * 0.34
                _ = tracker.observe(frame(t, bodies: [], usable: false, dark: true), now: t + 0.02)
                check(tracker.snapshot.isLowLight && tracker.snapshot.state == .unknown,
                      "Continuous fresh darkness never becomes absent even beyond the old eight-second cleanup")
            }
            _ = tracker.observe(frame(112.92, bodies: [seated]), now: 112.94)
            check(tracker.snapshot.state == .present && !tracker.snapshot.isLowLight,
                  "Restored illumination can resume the same foreground track without restarting capture")
            for i in 0..<4 { let t = 113.26 + Double(i) * 0.34; _ = tracker.observe(frame(t, bodies: []), now: t + 0.02) }
            check(tracker.snapshot.state == .unknown, "New usable empty frames must still satisfy the ordinary absence hold")
            for i in 4..<6 { let t = 113.26 + Double(i) * 0.34; _ = tracker.observe(frame(t, bodies: []), now: t + 0.02) }
            check(tracker.snapshot.state == .absent, "Only sufficient fresh usable empty-seat evidence confirms departure")
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
        for ambiguous in [
            PresenceBody(bounds: seated.bounds, confidence: 0.45),
            PresenceBody(bounds: CGRect(x: 0.4, y: 0.52, width: 0.2, height: 0.25), confidence: 0.95)
        ] {
            var tracker = PresenceTracker(reference: reference)
            for i in 0..<10 { let t = 130 + Double(i) * 0.34; _ = tracker.observe(frame(t, bodies: [ambiguous]), now: t + 0.02) }
            check(tracker.snapshot.state == .unknown,
                  "A visible nearby human rejected for confidence or foreground size cannot become an empty seat")
        }
        do {
            var tracker = PresenceTracker(reference: reference)
            let smallerFace = CGRect(x: 0.43, y: 0.63, width: 0.14, height: 0.14)
            for i in 0..<10 { let t = 140 + Double(i) * 0.34; _ = tracker.observe(frame(t, bodies: [], faces: [smallerFace]), now: t + 0.02) }
            check(tracker.snapshot.state == .unknown, "A nearby face smaller than the reference remains uncertain rather than absent")
        }
        for quality in [
            PresenceFrameQuality(globalMean: 0.8, seatMean: 0.02, seatDarkFraction: 1, seatContrast: 0.01, seatClippedFraction: 0, sampleCount: 192),
            PresenceFrameQuality(globalMean: 0.8, seatMean: 0.4, seatDarkFraction: 0, seatContrast: 0, seatClippedFraction: 0, sampleCount: 192)
        ] {
            var tracker = PresenceTracker(reference: reference)
            for i in 0..<10 { let t = 150 + Double(i) * 0.34; _ = tracker.observe(frame(t, bodies: [], quality: quality), now: t + 0.02) }
            check(tracker.snapshot.state == .unknown && tracker.snapshot.isLowLight == quality.needsLight,
                  "Bright global exposure cannot prove absence when calibrated seat quality is dark or ambiguous")
        }
        do {
            var tracker = PresenceTracker(reference: reference)
            for i in 0..<7 { let t = 160 + Double(i) * 0.34; _ = tracker.observe(frame(t, bodies: []), now: t + 0.02) }
            check(tracker.snapshot.state == .absent, "A genuinely analyzable initial empty seat remains detectable without a prior present frame")
            tracker.recheckAfterBrightnessRestore(after: 163)
            for t in [161.0, 162.8, 163] { _ = tracker.observe(frame(t, bodies: []), now: 163.02) }
            check(tracker.snapshot.state == .unknown, "Pre-restore and cutoff-equal frames cannot reuse a latched absence")
            for t in [163.1, 163.5, 163.9, 164.3] { _ = tracker.observe(frame(t, bodies: []), now: t + 0.02) }
            check(tracker.snapshot.state == .unknown, "Post-restore absence must complete a new hold interval")
            _ = tracker.observe(frame(164.7, bodies: []), now: 164.72)
            check(tracker.snapshot.state == .absent, "Fresh reliable post-restore empty-seat frames can confirm departure")
        }
        do {
            var tracker = PresenceTracker(reference: reference)
            _ = tracker.observe(frame(170, bodies: [], config: "changed"), now: 170.02)
            tracker.recheckAfterBrightnessRestore(after: 171)
            for i in 0..<7 { let t = 171.1 + Double(i) * 0.34; _ = tracker.observe(frame(t, bodies: []), now: t + 0.02) }
            check(tracker.snapshot.state == .unknown, "Brightness restoration cannot repair a changed camera configuration")
        }
        print("PASS: \(checks) anonymous presence geometry checks; synthetic observations only")
    }
}
