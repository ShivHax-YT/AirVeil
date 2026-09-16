import AppKit
import SwiftUI
import QuartzCore

@MainActor private final class RenderPermissionProvider: PermissionOnboardingProviding {
    var states = Dictionary(uniqueKeysWithValues: AirVeilPermission.allCases.map { ($0, PermissionAccessSnapshot(.notDetermined)) })
    func status(for permission: AirVeilPermission) -> PermissionAccessSnapshot { states[permission]! }
    func request(_ permission: AirVeilPermission) async -> PermissionAccessSnapshot { fatalError("Native render must never request permission") }
    func openSettings(for permission: AirVeilPermission) { fatalError("Native render must never open OS Settings") }
    func cancelPendingRequest() {}
}

@main @MainActor struct PermissionOnboardingRender {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
    static func accessibilityElements(in element: Any) -> [any NSAccessibilityProtocol] {
        guard let accessible = element as? any NSAccessibilityProtocol else { return [] }
        return [accessible] + (accessible.accessibilityChildren() ?? []).flatMap { accessibilityElements(in: $0) }
    }
    // Measures synchronous state mutation + forced AppKit layout only. These
    // timings do not measure presentation latency, display FPS, or GPU hitches.
    static func rapidNavigation(output: URL, reduceMotion: Bool) async throws {
        let suite = "AirVeil.PermissionMotion.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let setup = PermissionOnboarding(defaults: defaults, provider: RenderPermissionProvider())
        let checkAccessibility = CommandLine.arguments.contains("--accessibility")
        if checkAccessibility {
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            require(session?["CGSSessionScreenIsLocked"] as? Bool != true,
                    "--accessibility requires an unlocked desktop")
        }
        let root = PermissionOnboardingView(onboarding: setup, reduceMotionOverride: reduceMotion)
        let host = NSHostingView(rootView: root)
        let panel = NSPanel(contentRect: CGRect(x: -20000, y: -20000, width: 740, height: 660),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        if checkAccessibility { panel.center(); NSApp.activate(ignoringOtherApps: true) }
        panel.orderFront(nil)
        defer { panel.close() }
        setup.begin()
        try await Task.sleep(for: .milliseconds(200))
        if checkAccessibility {
            let initialButtons = accessibilityElements(in: host).filter { $0.accessibilityIdentifier() == "permission-skip" }
            require(initialButtons.count == 1, "Exactly one active permission skip action must be accessible")
            let oldSkip = initialButtons[0]
            _ = oldSkip.accessibilityPerformPress()
            try await Task.sleep(for: .milliseconds(25))
            require(setup.currentPermission == .screenRecording, "Native AX press must invoke the active skip action")
            let transitioningActions = accessibilityElements(in: host).filter {
                $0.accessibilityIdentifier() == "permission-skip" && $0.isAccessibilityEnabled()
            }
            require(transitioningActions.count == 1, "Only the current permission action may remain accessible during transition")
            _ = oldSkip.accessibilityPerformPress()
            try await Task.sleep(for: .milliseconds(25))
            require(setup.currentPermission == .screenRecording, "An outgoing card action must not act on the next permission")
            setup.back()
            try await Task.sleep(for: .milliseconds(400))
            print("PASS: current AX action works; outgoing action cannot advance the next permission")
        } else {
            print("SKIP: interactive AX actions (opt in with --accessibility on an unlocked desktop)")
        }
        var samples: [Double] = []
        for iteration in 0..<30 {
            let start = CACurrentMediaTime()
            if iteration.isMultiple(of: 2) { setup.continueWithoutAccess() }
            else { setup.back() }
            host.layoutSubtreeIfNeeded()
            samples.append((CACurrentMediaTime() - start) * 1000)
            // Deliberately retarget well before the normal transition settles.
            try await Task.sleep(for: .milliseconds(25))
            if reduceMotion {
                require(scrollViews(in: host).count == 1,
                             "Reduce Motion must replace the reading surface without retaining outgoing animated readers")
            }
            if iteration == 12 { panel.setContentSize(CGSize(width: 800, height: 850)) }
            if iteration == 20 { panel.setContentSize(CGSize(width: 740, height: 660)) }
        }
        let sorted = samples.sorted()
        let report = String(format: "reduceMotion=%@ samples=%d median=%.3fms p95=%.3fms max=%.3fms\nScope: synchronous state mutation plus forced layout; offscreen, not displayed FPS or end-to-end latency.\n",
                            String(reduceMotion), sorted.count, sorted[sorted.count / 2], sorted[Int(Double(sorted.count - 1) * 0.95)], sorted.last!)
        try report.write(to: output.appendingPathComponent("motion-\(reduceMotion ? "reduced" : "normal").txt"), atomically: true, encoding: .utf8)
        print(report)
        try await Task.sleep(for: .milliseconds(1000))
        host.layoutSubtreeIfNeeded()
        require(setup.currentPermission == .camera, "Final navigation intent must win after interrupted transitions")
        require(scrollViews(in: host).count == 1, "Settled view must contain only the selected consent reader")
        require(!setup.hasReviewedCurrent, "Navigation and resize must not silently review an unread card")
        // Replay while a different card is entering must not resurrect its reader.
        setup.continueWithoutAccess()
        try await Task.sleep(for: .milliseconds(25))
        setup.replay()
        try await Task.sleep(for: .milliseconds(1000))
        host.layoutSubtreeIfNeeded()
        require(setup.phase == .welcome && setup.reviewed.isEmpty, "Replay must win over an in-flight card transition")
        require(scrollViews(in: host).isEmpty, "Welcome must not retain a hidden consent reader")
        setup.begin()
        try await Task.sleep(for: .milliseconds(1000))
        host.layoutSubtreeIfNeeded()
        let readers = scrollViews(in: host)
        require(readers.count == 1 && !setup.hasReviewedCurrent, "Reopened consent reader must begin unread")
        let scroll = readers[0]
        let document = scroll.documentView!
        let bottom = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
        scroll.contentView.scroll(to: CGPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(180))
        require(setup.hasReviewedCurrent, "Consent review must still work after interrupted navigation and replay")
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("rapid-\(reduceMotion ? "reduced" : "normal").png"))
    }
    static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
    static func main() async throws {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var renders = 0; var scrollChecks = 0
        for compact in CommandLine.arguments.contains("--motion-only") ? [] : [false, true] {
            for scene in ["welcome", "camera-unread", "camera-scrolled", "camera-denied", "camera-allowed", "screen-unverified", "screen-scrolled", "head-unavailable", "head-scrolled", "summary"] {
                let suite = "AirVeil.PermissionRender.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let provider = RenderPermissionProvider()
                let setup = PermissionOnboarding(defaults: defaults, provider: provider)
                if scene != "welcome" { setup.begin() }
                if scene == "camera-denied" { provider.states[.camera] = PermissionAccessSnapshot(.denied, message: "Camera access was not allowed. You can change it in System Settings or continue without camera assistance.") }
                if scene == "camera-allowed" { provider.states[.camera] = PermissionAccessSnapshot(.authorized) }
                if scene == "screen-scrolled" { setup.continueWithoutAccess() }
                if scene == "head-scrolled" { setup.continueWithoutAccess(); setup.continueWithoutAccess() }
                if scene == "screen-unverified" {
                    setup.continueWithoutAccess()
                    provider.states[.screenRecording] = PermissionAccessSnapshot(.notGranted, message: "macOS has not confirmed access for this session. Reopen AirVeil if System Settings asks, then check again. Your setup progress is saved.")
                }
                if scene == "head-unavailable" {
                    setup.continueWithoutAccess(); setup.continueWithoutAccess()
                    provider.states[.headTracking] = PermissionAccessSnapshot(.unavailable, message: "Connect and wear compatible AirPods, then choose Try again. AirVeil has not received a permission decision yet.")
                }
                if scene == "summary" { setup.continueWithoutAccess(); setup.continueWithoutAccess(); setup.continueWithoutAccess() }
                setup.refresh()
                if scene != "camera-unread" && !scene.hasSuffix("-scrolled"), let permission = setup.currentPermission { setup.markReviewed(permission) }
                let size = compact ? CGSize(width: 740, height: 660) : CGSize(width: 800, height: 850)
                let host = NSHostingView(rootView: PermissionOnboardingView(onboarding: setup))
                let panel = NSPanel(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false; panel.contentView = host
                host.frame = CGRect(origin: .zero, size: size); panel.orderFront(nil)
                try await Task.sleep(nanoseconds: 180_000_000)
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                if scene == "camera-unread" || scene.hasSuffix("-scrolled") {
                    require(!setup.hasReviewedCurrent, "Content below viewport must not silently unlock Allow")
                    if scene.hasSuffix("-scrolled") {
                        let candidates = scrollViews(in: host)
                        require(candidates.count == 1, "Only active card contains an interactive scroll view")
                        let scroll = candidates[0]; let document = scroll.documentView!
                        require(document.bounds.height > scroll.contentView.bounds.height, "Permission content must truly scroll at supported sizes")
                        let bottom = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
                        scroll.contentView.scroll(to: CGPoint(x: 0, y: bottom)); scroll.reflectScrolledClipView(scroll.contentView)
                        try await Task.sleep(nanoseconds: 160_000_000)
                        host.layoutSubtreeIfNeeded()
                        require(setup.hasReviewedCurrent, "Showing the real final paragraph must unlock Allow")
                        scrollChecks += 1
                    }
                }
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(compact ? "compact" : "regular")-\(scene).png"))
                renders += 1; panel.close()
            }
        }
        for reduced in [false, true] { try await rapidNavigation(output: output, reduceMotion: reduced) }
        print("PASS: \(renders) native permission renders, \(scrollChecks) real scroll-to-end consent gates, 60 rapid reversals plus resize/replay/review in normal and reduced motion; fake provider only, no OS prompts or sensors")
    }
}
