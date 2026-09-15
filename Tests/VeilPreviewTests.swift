import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

@MainActor private final class PreviewProbe: ObservableObject {
    @Published var yaw: Double? = 0
}
private struct PreviewProbeView: View {
    let model: AppModel
    @ObservedObject var probe: PreviewProbe
    var body: some View { VeilPreview(model: model, simulationYaw: probe.yaw).frame(width: 660, height: 150) }
}

/// Synthetic preview pixels only. Does not start hardware, screen capture, or
/// change the user's preferences. The volatile argument domain is process-local.
@main @MainActor struct VeilPreviewTests {
    static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        UserDefaults.standard.setVolatileDomain(["fullAngle": 39.0, "wholeScreen": true,
            "blurOnsetLeft": 8.0, "blurOnsetRight": 8.0, "opaque": false, "inverted": false],
            forName: UserDefaults.argumentDomain)
        let model = AppModel()
        model.startupTourActive = true
        let probe = PreviewProbe()
        let host = NSHostingView(rootView: PreviewProbeView(model: model, probe: probe))
        let window = NSPanel(contentRect: CGRect(x: -20000, y: -20000, width: 660, height: 150),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close(); model.shutdown() }
        try await settle(host)
        guard let metal = metalView(in: host) else { fatalError("No hosted Metal preview") }
        precondition(metal.initializationError == nil)
        let destination = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let clear = try metal.renderOffscreen(width: 660, height: 150)
        try save(clear, to: destination.appendingPathComponent("clear.png"))
        probe.yaw = 44.38
        try await settle(host)
        let simulated = try metal.renderOffscreen(width: 660, height: 150)
        try save(simulated, to: destination.appendingPathComponent("simulated-44.png"))
        let changed = differingBytes(clear, simulated)
        print("Changed bytes after SwiftUI yaw update: \(changed); renderer enabled: \(metal.renderingEnabled); redraw requests: \(metal.redrawRequestCount); submitted draws: \(metal.drawSubmissionCount)")
        precondition(changed > 10000, "Changing tutorial yaw must update real Metal preview pixels")
        model.previewFrame?(.zero)
        let afterCallback = try metal.renderOffscreen(width: 660, height: 150)
        try save(afterCallback, to: destination.appendingPathComponent("after-normal-callback.png"))
        precondition(differingBytes(simulated, afterCallback) == 0,
                     "The model's ordinary preview callback must not overwrite tutorial simulation")
        probe.yaw = 0
        try await settle(host)
        let centered = try metal.renderOffscreen(width: 660, height: 150)
        precondition(differingBytes(clear, centered) == 0, "Center must restore unblurred preview pixels")
        probe.yaw = nil
        try await settle(host)
        model.previewFrame?(.full)
        let live = try metal.renderOffscreen(width: 660, height: 150)
        precondition(differingBytes(clear, live) > 10000, "Leaving simulation must restore model-driven preview frames")
        model.setPreviewVisible(false)
        try await settle(host)
        let hiddenSubmissions = metal.drawSubmissionCount
        probe.yaw = 0
        try await settle(host)
        precondition(!metal.renderingEnabled && metal.drawSubmissionCount == hiddenSubmissions,
                     "A hidden preview must not submit draws when its simulation changes")
        model.setPreviewVisible(true)
        try await settle(host)
        precondition(metal.renderingEnabled && metal.drawSubmissionCount > hiddenSubmissions,
                     "Showing the preview must restart rendering after hidden simulation changes")
        let visibleAgain = try metal.renderOffscreen(width: 660, height: 150)
        precondition(differingBytes(clear, visibleAgain) == 0,
                     "Showing the preview must use the latest simulation value")
        precondition(!model.motion.isRunning && !model.cameraHeading.camera.isRunning && !model.enabled)
        print("PASS: SwiftUI simulation updates, normal callback isolation, Center, return to model-driven preview, and hide/show redraw recovery; no sensors or desktop capture started")
    }
    private static func settle(_ host: NSView) async throws {
        try await Task.sleep(nanoseconds: 180_000_000)
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    }
    private static func metalView(in view: NSView) -> VeilMetalView? {
        if let metal = view as? VeilMetalView { return metal }
        return view.subviews.lazy.compactMap { metalView(in: $0) }.first
    }
    private static func differingBytes(_ a: CGImage, _ b: CGImage) -> Int {
        let left = Array(a.dataProvider!.data! as Data), right = Array(b.dataProvider!.data! as Data)
        precondition(left.count == right.count)
        return zip(left, right).reduce(0) { $0 + ($1.0 != $1.1 ? 1 : 0) }
    }
    private static func save(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw VeilRenderError.unavailable("Cannot create preview test image")
        }
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
    }
}
