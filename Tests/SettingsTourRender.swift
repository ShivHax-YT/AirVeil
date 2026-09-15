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
        // Render the first-launch tracking action without starting sensors.
        model.startupTourActive = true
        for compact in [true, false] {
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
        let energy = EnergyController(defaults: defaults, monitorSystem: false)
        defer { energy.shutdown(); model.shutdown() }
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            app.appearance = appearance
            for (name, mode, lowPower) in [("automatic", EnergyMode.automatic, false),
                                            ("low-power", .automatic, true),
                                            ("smoothest", .smoothest, true),
                                            ("reduced", .reducedEnergy, false)] {
                energy.updateSystemState(lowPowerMode: lowPower, thermalState: .nominal)
                energy.mode = mode
                let size = CGSize(width: 684, height: 230)
                let host = NSHostingView(rootView: EnergySettingsView(energy: energy, overlay: model.overlay)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .frame(width: size.width, height: size.height)
                    .transaction { $0.disablesAnimations = true })
                host.appearance = appearance
                let window = NSPanel(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                host.frame = CGRect(origin: .zero, size: size); window.orderFront(nil)
                try await Task.sleep(nanoseconds: 100_000_000)
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No energy bitmap") }
                appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
                try bitmap.representation(using: .png, properties: [:])!.write(to:
                    destination.appendingPathComponent("energy-\(dark ? "dark" : "light")-\(name).png"))
                window.orderOut(nil); window.close()
            }
        }
        precondition(!model.motion.isRunning && !model.cameraHeading.camera.isRunning && !model.enabled)
        print("PASS: \(SettingsTourStep.allCases.count * 4) native tour renders and 8 energy-control renders; no sensors or desktop capture started")
    }
}
