import AppKit
import SwiftUI

@MainActor private final class RenderPermissionProvider: PermissionOnboardingProviding {
    var states = Dictionary(uniqueKeysWithValues: AirVeilPermission.allCases.map { ($0, PermissionAccessSnapshot(.notDetermined)) })
    func status(for permission: AirVeilPermission) -> PermissionAccessSnapshot { states[permission]! }
    func request(_ permission: AirVeilPermission) async -> PermissionAccessSnapshot { fatalError("Native render must never request permission") }
    func openSettings(for permission: AirVeilPermission) { fatalError("Native render must never open OS Settings") }
    func cancelPendingRequest() {}
}

@main @MainActor struct PermissionOnboardingRender {
    static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
    static func main() async throws {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var renders = 0; var scrollChecks = 0
        for compact in [false, true] {
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
                    precondition(!setup.hasReviewedCurrent, "Content below viewport must not silently unlock Allow")
                    if scene.hasSuffix("-scrolled") {
                        let candidates = scrollViews(in: host)
                        precondition(candidates.count == 1, "Only active card contains an interactive scroll view")
                        let scroll = candidates[0]; let document = scroll.documentView!
                        precondition(document.bounds.height > scroll.contentView.bounds.height, "Permission content must truly scroll at supported sizes")
                        let bottom = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
                        scroll.contentView.scroll(to: CGPoint(x: 0, y: bottom)); scroll.reflectScrolledClipView(scroll.contentView)
                        try await Task.sleep(nanoseconds: 160_000_000)
                        host.layoutSubtreeIfNeeded()
                        precondition(setup.hasReviewedCurrent, "Showing the real final paragraph must unlock Allow")
                        scrollChecks += 1
                    }
                }
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(compact ? "compact" : "regular")-\(scene).png"))
                renders += 1; panel.close()
            }
        }
        print("PASS: \(renders) native permission renders, \(scrollChecks) real scroll-to-end consent gates; fake provider only, no OS prompts or sensors")
    }
}
