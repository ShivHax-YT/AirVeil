import AppKit
import SwiftUI

/// NSHostingView is required because the segmented Picker is an AppKit-backed
/// control. ImageRenderer intentionally substitutes an unsupported-view badge.
/// This caches only this process's offscreen view, never the user's display.
/// AppKit's bitmap path does not composite SwiftUI's rotation3DEffect layer:
/// the head is drawn at the bitmap origin. These files diagnose native Picker,
/// appearance and text layout only; inspect the real window for the head.
@main struct BlurOnsetDialRender {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let destination = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for side in BlurTurnSide.allCases {
            for dark in [false, true] {
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                app.appearance = appearance
                let content = BlurOnsetDial(left: .constant(18), right: .constant(32), initialSide: side)
                    .padding(24).frame(width: 680)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .preferredColorScheme(dark ? .dark : .light)
                let host = NSHostingView(rootView: content)
                host.appearance = appearance
                let size = host.fittingSize
                precondition(size.width == 680 && size.height > 200, "The complete control must have a resolved layout")
                let window = RenderWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = appearance
                window.backgroundColor = .windowBackgroundColor
                window.contentView = host
                window.setFrame(CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height), display: false)
                host.frame = CGRect(origin: .zero, size: size)
                window.orderFront(nil)
                // A real view lifecycle launches OnsetArc.task. Its 0.24 s
                // illustrative head turn must settle before caching the bitmap.
                try await Task.sleep(nanoseconds: 600_000_000)
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                    pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("Bitmap allocation failed") }
                bitmap.size = size
                appearance.performAsCurrentDrawingAppearance {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                }
                guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Render failed") }
                try data.write(to: destination.appendingPathComponent("\(side.rawValue.lowercased())-\(dark ? "dark" : "light").png"))
                window.orderOut(nil)
                window.close()
            }
        }
        let note = """
        Diagnostic native renders only. The actual AppKit-backed segmented Picker and
        Aqua/Dark Aqua appearances render correctly. However, NSView.cacheDisplay does
        not composite the SwiftUI rotation3DEffect layer: the illustrative head is
        misplaced at the bitmap origin. This is a capture-path limitation; these PNGs
        are not proof of correct head placement or rotation. Inspect the live native
        window before claiming complete visual validation. No sensors or display
        capture were used. The .task lifecycle was given 0.6 s to settle.
        """
        try note.write(to: destination.appendingPathComponent("NATIVE-RENDER-LIMITATION.txt"), atomically: true, encoding: .utf8)
        print("Wrote four native dial diagnostics at 2x. Picker/theme verified; 3D head requires live-window inspection.")
    }
}

@MainActor private final class RenderWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
