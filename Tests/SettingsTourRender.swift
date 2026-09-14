import AppKit
import SwiftUI

/// Renders only an offscreen window owned by this process. No screen capture,
/// headphone streaming, camera setup, or desktop effect is started.
@main struct SettingsTourRender {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let destination = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let name = "AirVeil.TourRender.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppModel()
        for compact in [false, true] {
            for dark in [false, true] {
                let size = CGSize(width: compact ? 740 : 800, height: compact ? 660 : 850)
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                app.appearance = appearance
                let tour = SettingsTour(defaults: defaults)
                tour.replay()
                let host = NSHostingView(rootView: SettingsView(model: model, tour: tour)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .transaction { $0.disablesAnimations = true })
                host.appearance = appearance
                let window = NSPanel(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                host.frame = CGRect(origin: .zero, size: size)
                window.orderFront(nil)
                for step in SettingsTourStep.allCases {
                    precondition(tour.step == step)
                    try await Task.sleep(nanoseconds: 600_000_000)
                    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
                    appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
                    let data = bitmap.representation(using: .png, properties: [:])!
                    try data.write(to: destination.appendingPathComponent("\(compact ? "compact" : "regular")-\(dark ? "dark" : "light")-\(step.rawValue).png"))
                    tour.next()
                }
                window.orderOut(nil); window.close()
            }
        }
        precondition(!model.motion.isRunning && !model.cameraHeading.camera.isRunning && !model.enabled)
        print("PASS: 56 native tour renders, two sizes and both appearances; no sensors or desktop capture started")
    }
}
