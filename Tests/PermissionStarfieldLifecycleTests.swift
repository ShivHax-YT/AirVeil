import AppKit
import SwiftUI

@MainActor private final class StarfieldHarnessState: ObservableObject {
    @Published var reduceMotion = false
}

@MainActor private final class StarfieldTickRecorder {
    private(set) var count = 0
    private(set) var elapsed: TimeInterval = 0
    func record(_ time: TimeInterval) { count += 1; elapsed = time }
}

@MainActor private final class StarfieldPermissionProvider: PermissionOnboardingProviding {
    func status(for permission: AirVeilPermission) -> PermissionAccessSnapshot {
        PermissionAccessSnapshot(.notDetermined)
    }
    func request(_ permission: AirVeilPermission) async -> PermissionAccessSnapshot {
        fatalError("Generated-art harness must never request OS access")
    }
    func openSettings(for permission: AirVeilPermission) {
        fatalError("Generated-art harness must never open OS Settings")
    }
    func cancelPendingRequest() {}
}

private struct StarfieldHarnessView: View {
    @ObservedObject var state: StarfieldHarnessState
    let ticks: StarfieldTickRecorder
    var body: some View {
        PermissionStarfieldBackground(reduceMotionOverride: state.reduceMotion,
                                      onAnimationTick: { ticks.record($0) })
    }
}

private final class StarfieldHarnessPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct StarfieldHarnessFailure: Error, CustomStringConvertible {
    let description: String
}

private struct StarfieldPixels {
    let bytes: [UInt8]
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytesPerPixel: Int

    /// The center of the first 60 points is outside the logo/counter and all
    /// permission cards, so changes here cannot be hidden behind their glass.
    func changedHeaderBytes(comparedTo other: Self, viewHeight: CGFloat) -> Int {
        guard width == other.width, height == other.height,
              bytesPerRow == other.bytesPerRow, bytesPerPixel == other.bytesPerPixel else { return 0 }
        let minX = Int(Double(width) * 0.23), maxX = Int(Double(width) * 0.65)
        let minY = max(0, Int(Double(height) * 8 / viewHeight))
        let maxY = min(height, Int(Double(height) * 60 / viewHeight))
        var changed = 0
        for y in minY..<maxY {
            for index in (y * bytesPerRow + minX * bytesPerPixel)..<(y * bytesPerRow + maxX * bytesPerPixel) {
                if bytes[index] != other.bytes[index] { changed += 1 }
            }
        }
        return changed
    }

}

@main @MainActor struct PermissionStarfieldLifecycleTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        Task { @MainActor in
            do {
                try await run(app)
                exit(0)
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        }
        app.run()
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw StarfieldHarnessFailure(description: message) }
    }

    private static func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    private static func awaitState(_ message: String, condition: () -> Bool) async throws {
        for _ in 0..<30 {
            if condition() { return }
            try await pause(0.1)
        }
        throw StarfieldHarnessFailure(description: message)
    }

    private static func awaitTicks(_ ticks: StarfieldTickRecorder, after count: Int) async throws {
        for _ in 0..<25 {
            if ticks.count >= count + 3 { return }
            try await pause(0.1)
        }
        throw StarfieldHarnessFailure(description: "A visible, unfocused native window did not receive animation ticks")
    }

    private static func starfield(in view: NSView) -> StarfieldLayerView? {
        if let field = view as? StarfieldLayerView { return field }
        return view.subviews.lazy.compactMap { starfield(in: $0) }.first
    }

    private static func capture(_ host: NSView, to url: URL) throws -> StarfieldPixels {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw StarfieldHarnessFailure(description: "Could not allocate generated-art bitmap")
        }
        guard let graphics = NSGraphicsContext(bitmapImageRep: bitmap), let presentation = host.layer?.presentation() else {
            throw StarfieldHarnessFailure(description: "Could not read actual presentation layers")
        }
        // CALayer uses the host's flipped geometry. Bitmap contexts start at
        // the lower-left; flip once so exported rows and header checks agree.
        graphics.cgContext.translateBy(x: 0, y: host.bounds.height)
        graphics.cgContext.scaleBy(x: 1, y: -1)
        presentation.render(in: graphics.cgContext)
        guard let data = bitmap.bitmapData,
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw StarfieldHarnessFailure(description: "Could not read generated-art pixels")
        }
        try png.write(to: url)
        return StarfieldPixels(bytes: Array(UnsafeBufferPointer(start: data, count: bitmap.bytesPerRow * bitmap.pixelsHigh)),
            width: bitmap.pixelsWide, height: bitmap.pixelsHigh, bytesPerRow: bitmap.bytesPerRow,
            bytesPerPixel: bitmap.bitsPerPixel / 8)
    }

    private static func run(_ app: NSApplication) async throws {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        try require((session?["CGSSessionScreenIsLocked"] as? Bool) != true,
                    "Visible starfield verification requires an unlocked desktop; the session is locked. No visible-render gates were run or skipped as passing.")
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let state = StarfieldHarnessState(), ticks = StarfieldTickRecorder()
        let host = NSHostingView(rootView: StarfieldHarnessView(state: state, ticks: ticks))
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let size = CGSize(width: 360, height: 240)
        let frame = CGRect(x: screen.maxX - size.width - 24, y: screen.minY + 24,
                           width: size.width, height: size.height)
        let panel = StarfieldHarnessPanel(contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        defer { panel.close() }

        // Exercise a real visible AppKit window while another app owns focus.
        // Captures contain generated presentation layers only, never the desktop.
        // Keep accessory policy: prohibited applications cannot create windows.
        // Deactivation is asynchronous, so await the actual fixture state.
        app.deactivate()
        panel.orderFrontRegardless()
        try await pause(0.25)
        app.deactivate()
        try await awaitState("Fixture could not become inactive after deactivation; unfocused animation was not tested") {
            !app.isActive
        }
        try await awaitState("Harness window never became visibly unoccluded (visible=\(panel.isVisible), occlusion=\(panel.occlusionState.rawValue), activeSpace=\(panel.isOnActiveSpace), hidden=\(app.isHidden))") {
            panel.isVisible && panel.occlusionState.contains(.visible)
        }
        try require(panel.isVisible && panel.occlusionState.contains(.visible),
                    "Harness must be truly visible and unoccluded")
        try await awaitTicks(ticks, after: ticks.count)
        try require(starfield(in: host)?.activeAnimationCount ?? 0 > 0,
                    "Visible artwork must have real compositor animations")
        let first = try capture(host, to: output.appendingPathComponent("visible-a.png"))
        let movingCount = ticks.count
        try await pause(1.2)
        let second = try capture(host, to: output.appendingPathComponent("visible-b.png"))
        let changedBytes = zip(first.bytes, second.bytes).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
        try require(!app.isActive && ticks.count > movingCount,
                    "Visible animation must continue while the app lacks focus (active=\(app.isActive), ticks=\(ticks.count), prior=\(movingCount), visible=\(panel.occlusionState.contains(.visible)))")
        try require(first.bytes.count == second.bytes.count && changedBytes >= 48,
                    "Actual generated star pixels must change over time")
        print("PASS: visible inactive window animates; \(ticks.count - movingCount) ticks, \(changedBytes) changed pixel bytes")

        // An ordered-in window can be entirely covered. Unlike orderOut, this
        // specifically exercises the occlusion gate while isVisible stays true.
        // Use only an opaque generated fixture; never move another app's window.
        let cover = StarfieldHarnessPanel(contentRect: panel.frame.insetBy(dx: -12, dy: -12),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.hidesOnDeactivate = false
        cover.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        cover.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        cover.isOpaque = true
        cover.backgroundColor = .black
        cover.hasShadow = false
        cover.ignoresMouseEvents = true
        defer { cover.close() }
        cover.orderFrontRegardless()
        try await awaitState("Opaque fixture did not fully occlude the still-ordered-in starfield window") {
            panel.isVisible && !panel.occlusionState.contains(.visible)
        }
        try await pause(0.35)
        let coveredCount = ticks.count
        try await pause(0.8)
        try require(panel.isVisible && !panel.occlusionState.contains(.visible) && ticks.count == coveredCount,
                    "Fully occluded window must stop animation ticks even though isVisible remains true")
        try require(starfield(in: host)?.activeAnimationCount == 0,
                    "Full occlusion must remove compositor animations, not just stop the observer")
        print("PASS: fully covered ordered-in window removes compositor animations and stops observations")
        cover.orderOut(nil)
        try await awaitState("Uncovering did not restore native visibility") {
            panel.occlusionState.contains(.visible)
        }
        try await awaitTicks(ticks, after: ticks.count)
        try require(!app.isActive, "Cover/uncover fixtures must not activate the harness")
        print("PASS: uncovering resumes animation without focus")

        state.reduceMotion = true
        try await pause(0.35)
        let reducedA = try capture(host, to: output.appendingPathComponent("reduced-motion.png"))
        let reducedCount = ticks.count
        try await pause(0.8)
        let reducedB = try capture(host, to: output.appendingPathComponent("reduced-motion-repeat.png"))
        try require(ticks.count == reducedCount && reducedA.bytes == reducedB.bytes,
                    "Reduce Motion must stop diagnostic observations and keep identical artwork")
        try require(starfield(in: host)?.activeAnimationCount == 0,
                    "Reduce Motion must remove all compositor animations")
        print("PASS: Reduce Motion removes animations and preserves static pixels")

        state.reduceMotion = false
        try await pause(0.2)
        try await awaitTicks(ticks, after: ticks.count)
        panel.orderOut(nil)
        try await pause(0.35)
        let hiddenCount = ticks.count
        try await pause(0.8)
        try require(!panel.isVisible && ticks.count == hiddenCount,
                    "Hiding the actual window must stop animation ticks")
        print("PASS: hidden native window stops animation ticks")

        panel.orderFrontRegardless()
        try await pause(0.25)
        try await awaitTicks(ticks, after: ticks.count)
        try require(!app.isActive, "Reopening generated-art panel must not take app focus")
        panel.close()
        try await pause(0.35)
        let closedCount = ticks.count
        try await pause(0.8)
        try require(ticks.count == closedCount, "Closing the native window must stop animation ticks")
        print("PASS: reopening resumes without focus; closing stops ticks")
        print("PASS: starfield native visibility lifecycle; generated pixels only, no sensors, desktop capture, or app preferences")

        try require(!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                    "Full-stage animation check requires system Reduce Motion off; no setting was changed")
        for compact in [false, true] {
            for permission in AirVeilPermission.allCases {
                try await runPermissionStage(app, permission: permission, compact: compact, output: output)
            }
        }
        print("PASS: six full permission stages animate in their uncovered header at both supported sizes; fake providers only")
    }

    private static func runPermissionStage(_ app: NSApplication, permission: AirVeilPermission,
                                          compact: Bool, output: URL) async throws {
        // Same isolated test-fixture boundary as the permission-card harness;
        // never read or write AirVeil's real preference domain.
        let suite = "AirVeil.StarfieldFullStage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let setup = PermissionOnboarding(defaults: defaults, provider: StarfieldPermissionProvider())
        setup.begin()
        for _ in AirVeilPermission.allCases.prefix(while: { $0 != permission }) {
            setup.continueWithoutAccess()
        }
        let ticks = StarfieldTickRecorder()
        let host = NSHostingView(rootView: PermissionOnboardingView(onboarding: setup,
            onBackgroundAnimationTick: { ticks.record($0) }))
        let size = compact ? CGSize(width: 740, height: 660) : CGSize(width: 800, height: 850)
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 900)
        let frame = CGRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height,
                           width: size.width, height: size.height)
        let panel = StarfieldHarnessPanel(contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        defer { panel.close() }
        panel.orderFrontRegardless()
        try await pause(0.35)
        try require(!app.isActive && panel.isVisible && panel.occlusionState.contains(.visible),
                    "Full permission stage must be visibly rendered without taking app focus")
        try await awaitTicks(ticks, after: ticks.count)
        let label = "full-\(compact ? "compact" : "regular")-\(permission.rawValue)"
        let first = try capture(host, to: output.appendingPathComponent("\(label)-a.png"))
        let firstElapsed = ticks.elapsed
        let count = ticks.count
        try await pause(1.4)
        let second = try capture(host, to: output.appendingPathComponent("\(label)-b.png"))
        let headerChanges = second.changedHeaderBytes(comparedTo: first, viewHeight: size.height)
        try require(!app.isActive && ticks.count > count,
                    "Background tick must reach the full unfocused permission view")
        try require(headerChanges >= 48,
                    "Actual clear-header star pixels must change in the full permission composition")
        print("PASS: \(label) \(Int(size.width))×\(Int(size.height)); \(ticks.count - count) ticks, \(headerChanges) changed uncovered-header pixel bytes; frame times \(String(format: "%.2f", firstElapsed))/\(String(format: "%.2f", ticks.elapsed))s")
    }
}
