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
        var cases: [(side: BlurTurnSide, dark: Bool, name: String, yaw: Double?, syncing: Bool, compact: Bool)] = []
        for side in BlurTurnSide.allCases {
            for dark in [false, true] {
                for (name, yaw, syncing) in [("illustrated", Optional<Double>.none, false),
                                              ("live-left", 25.0, true), ("live-right", -25.0, true),
                                              ("live-center", -0.0, true),
                                              ("left-limit", 75.0, true), ("right-limit", -75.0, true),
                                              ("waiting", nil, true), ("invalid", .nan, true)] {
                    cases.append((side, dark, name, yaw, syncing, false))
                }
                for (name, yaw) in [("compact-left", Optional(25.0)), ("compact-waiting", nil)] {
                    cases.append((side, dark, name, yaw, true, true))
                }
            }
        }
        var checks = 0
        func check(_ condition: Bool, _ reason: String) {
            checks += 1
            if !condition { print("FAIL: \(reason)"); exit(1) }
        }
        for fixture in cases {
                let (side, dark, name, yaw, syncing, compact) = fixture
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                app.appearance = appearance
                let content = BlurOnsetDial(left: .constant(18), right: .constant(32), initialSide: side,
                    liveYaw: yaw, syncRequested: syncing,
                    syncStatus: syncing ? (yaw?.isFinite != true ? "Face the camera and hold still." : "Following your head. Turn left and right.") : "Align with the camera, then follow your AirPods.",
                    compact: compact,
                    toggleSync: {})
                    .padding(24).frame(width: compact ? 600 : 680)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .transaction { $0.animation = nil; $0.disablesAnimations = true }
                    .preferredColorScheme(dark ? .dark : .light)
                let host = NSHostingView(rootView: content)
                host.appearance = appearance
                let size = host.fittingSize
                check(size.width == (compact ? 600 : 680) && size.height > 200 && size.height < 420,
                      "\(name) has a bounded complete native layout")
                let window = RenderWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = appearance
                window.backgroundColor = .windowBackgroundColor
                window.contentView = host
                window.setFrame(CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height), display: false)
                host.frame = CGRect(origin: .zero, size: size)
                window.orderFront(nil)
                // Allow the native control and composited layers to lay out.
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
                // Green belongs only to the actual arc/marker. Verify rendered
                // movement crosses sides independently of the disabled Picker,
                // and pending/invalid evidence paints no pretend angle marker.
                var greenXs: [Double] = []
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                    for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                        if color.greenComponent > 0.35 && color.greenComponent > color.redComponent * 1.3 && color.greenComponent > color.blueComponent * 1.2 {
                            greenXs.append(Double(x) / 2)
                        }
                    }
                }
                let feedback = BlurDialFeedback(side: side, threshold: side == .left ? 18 : 32, liveYaw: yaw, syncing: syncing)
                if !feedback.showsMarker {
                    check(greenXs.isEmpty, "\(name) paints no green marker or filled arc without valid head evidence")
                } else {
                    check(!greenXs.isEmpty, "\(name) paints a visible arc and marker")
                    let arcCenterX = 24.0 + (compact ? 126 : 150)
                    let lower = greenXs.min() ?? arcCenterX
                    let upper = greenXs.max() ?? arcCenterX
                    if feedback.arcYaw > 1 {
                        check(lower < arcCenterX - 20 && upper < arcCenterX + 10,
                              "\(name) green marker/arc follows physical left, independent of selected side")
                    } else if feedback.arcYaw < -1 {
                        check(upper > arcCenterX + 20 && lower > arcCenterX - 10,
                              "\(name) green marker/arc follows physical right, independent of selected side")
                    } else {
                        check(lower > arcCenterX - 12 && upper < arcCenterX + 12,
                              "\(name) marker sits at the shared center for measured zero")
                    }
                }
                guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Render failed") }
                try data.write(to: destination.appendingPathComponent("\(name)-\(side.rawValue.lowercased())-\(dark ? "dark" : "light").png"))
                window.orderOut(nil)
                window.close()
        }
        let note = """
        Diagnostic native renders only. The actual AppKit-backed segmented Picker and
        Aqua/Dark Aqua appearances render correctly. However, NSView.cacheDisplay does
        not composite the SwiftUI rotation3DEffect layer: the illustrative head is
        misplaced at the bitmap origin. This is a capture-path limitation; these PNGs
        are not proof of correct head placement or rotation. Inspect the live native
        window before claiming complete visual validation. No sensors or display
        capture were used. The native lifecycle was given 0.6 s to settle.
        """
        try note.write(to: destination.appendingPathComponent("NATIVE-RENDER-LIMITATION.txt"), atomically: true, encoding: .utf8)
        print("PASS: \(checks) native layout and rendered arc checks across \(cases.count) 2x fixtures: onset editing, signed live movement, center, limits, pending/invalid evidence, and compact layouts. No sensors or desktop capture; 3D head still requires live-window inspection.")
    }
}

@MainActor private final class RenderWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
