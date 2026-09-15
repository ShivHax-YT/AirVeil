import AppKit
import SwiftUI

@main struct NotchViewRender {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        // Constructing the service does not start or request access to the camera.
        let camera = CameraAnchorService()
        let p = NotchOverlayPresentation()
        p.expanded = true; p.demo = true; p.canCenter = true; p.canEnable = true; p.cameraEnabled = true
        let states: [(String, NotchCoachSnapshot)] = [
            ("seeking", .init(phase: .seeking, title: "Looking for your face", detail: "Face the camera and keep your face visible.", issue: .faceMissing)),
            ("off-center", .init(phase: .offCenter, title: "Look straight ahead", detail: "13° from center. Aim within 5°.", horizontalError: -0.3, issue: .pose)),
            ("low-light", .init(phase: .lighting, title: "A little more light", detail: "Light your face so the camera can see you.", issue: .lowLight)),
            ("holding", .init(phase: .holding, title: "Hold at center", detail: "One quick camera and AirPods check.", progress: 0.65)),
            ("near-center", .init(phase: .offCenter, title: "Look straight ahead", detail: "6° from center. Aim within 5°.", horizontalError: -0.13, issue: .pose)),
            ("success", .init(phase: .success, title: "Direction restored", detail: "You're ready. Camera is off.", progress: 1)),
            ("failure", .init(phase: .failure, title: "Try the direction check again", detail: "Keep your face visible and hold still briefly.", issue: .camera))
        ]
        for (name, state) in states {
            p.snapshot = state
            p.animationTime = 1
            try render(name, p, camera, destination)
        }
        p.snapshot = states[5].1
        for (index, time) in [0.0, 0.12, 0.3, 0.48, 0.6, 0.75].enumerated() {
            p.animationTime = time
            try render("smile-keyframe-\(index)", p, camera, destination)
        }
        p.animationTime = 1
        p.snapshot = states[0].1
        var previousMetrics: RevealMetrics?
        for (index, amount) in [0.0, 0.15, 0.35, 0.65, 0.9, 1.0].enumerated() {
            p.revealProgress = amount
            let frame = try render("reveal-keyframe-\(index)", p, camera, destination)
            let metrics = revealMetrics(frame)
            renderRequire(abs(metrics.center - 180) <= 0.5,
                         "Rendered screen-edge expansion must remain symmetric")
            if let previousMetrics {
                renderRequire(metrics.width > previousMetrics.width,
                             "Rendered screen-edge keyframes must grow left and right")
            } else {
                renderRequire(abs(metrics.width - p.hardwareWidth) <= 1,
                             "First rendered screen-edge band must fit the hardware notch")
            }
            if amount == 1 {
                renderRequire(abs(metrics.width - p.canopyWidth) <= 1,
                             "Fully open rendered screen-edge band must use the expanded canopy")
                renderRequire(metrics.width > p.contentWidth,
                             "The open black surround grows without widening camera content")
            }
            previousMetrics = metrics
            print("PASS: reveal keyframe \(index), screen-edge width \(metrics.width)pt")
        }
        p.revealProgress = nil
        p.wearAirPodsPrompt = true
        var firstWearArt: [UInt8]?
        for (index, time) in [0.0, 2.0, 4.0, 6.0].enumerated() {
            p.animationTime = time
            let frame = try render("wear-airpods-keyframe-\(index)", p, camera, destination)
            // Nonzero 3D transforms may omit unrelated sibling layers in
            // ImageRenderer. Compare the artwork region itself, never treat
            // missing text as proof of animation or live layout acceptance.
            let art = imageRegion(frame, points: CGRect(x: 100, y: 32, width: 160, height: 105))
            if let firstWearArt {
                renderRequire(art != firstWearArt, "The AirPods artwork itself must change over time")
            } else {
                firstWearArt = art
                let button = frame.colorAt(x: 160, y: 528)?.usingColorSpace(.deviceRGB)
                renderRequire((button?.redComponent ?? 0) > 0.8,
                              "The static full composition must include its visible Turn off feature button")
            }
        }
        renderRequire(NSImage(systemSymbolName: "airpodspro", accessibilityDescription: nil) != nil,
                      "The AirPods waiting illustration must use an available native symbol")
        let staticA = try renderStaticWearGlyph(time: 0, name: "wear-reduced-motion-a", destination: destination)
        let staticB = try renderStaticWearGlyph(time: 6, name: "wear-reduced-motion-b", destination: destination)
        renderRequire(staticA == staticB, "Reduced-motion AirPods artwork must remain identical across times")
        p.wearAirPodsPrompt = false
        for reason in [NotchBrightnessRecoveryReason.lowLight, .seatRecheck] {
            for stage in [NotchBrightnessRecoveryStage.announcing, .restoring, .restored, .monitoring] {
                let recovery = NotchOverlayPresentation()
                recovery.expanded = true; recovery.brightnessRecovery = stage
                recovery.brightnessRecoveryReason = reason; recovery.animationTime = 0.75
                let prefix = reason == .lowLight ? "brightness" : "seat-recheck"
                let frame = try render("\(prefix)-\(stage.rawValue)", recovery, camera, destination)
                let button = frame.colorAt(x: 160, y: 528)?.usingColorSpace(.deviceRGB)
                renderRequire((button?.redComponent ?? 0) > 0.8,
                              "Every brightness stage must retain the visible Turn off feature button")
                let closeVisible = (92..<132).contains { y in
                    (566..<606).contains { x in
                        (frame.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.redComponent ?? 0) > 0.55
                    }
                }
                renderRequire(closeVisible,
                              "Every brightness stage must keep the dismiss control visible")
            }
        }
        let recoveryMovingA = try renderRecoveryGlyph(time: 0, moving: true, name: "brightness-moving-a", destination: destination)
        let recoveryMovingB = try renderRecoveryGlyph(time: 0.5, moving: true, name: "brightness-moving-b", destination: destination)
        renderRequire(recoveryMovingA != recoveryMovingB, "The brightness symbol gently changes over time")
        let recoveryStaticA = try renderRecoveryGlyph(time: 0, moving: false, name: "brightness-reduced-motion-a", destination: destination)
        let recoveryStaticB = try renderRecoveryGlyph(time: 0.5, moving: false, name: "brightness-reduced-motion-b", destination: destination)
        renderRequire(recoveryStaticA == recoveryStaticB, "Reduce Motion stops the brightness animation while retaining its message")
        p.brightnessRecovery = .none
        p.animationTime = 1
        p.controls = true
        try render("controls", p, camera, destination)
        for name in ["paused", "enabled", "waiting", "camera-setup", "unavailable"] {
            let controls = NotchOverlayPresentation()
            controls.expanded = true; controls.controls = true
            controls.cameraEnabled = name != "camera-setup"
            controls.canCenter = name == "paused" || name == "enabled"
            controls.enabled = name == "enabled"
            controls.canTurnOffFeature = name == "waiting"
            controls.canEnable = name != "unavailable"
            try render("controls-\(name)", controls, camera, destination)
        }
        p.topInset = 0; p.controls = false; p.snapshot = states[1].1
        try render("external-display", p, camera, destination)
        p.topInset = 32; p.demo = false
        for step in NotchTutorialStep.allCases {
            p.tutorialStep = step
            try render("tutorial-\(step.rawValue)", p, camera, destination)
        }
        p.topInset = 0
        try render("tutorial-unnotched", p, camera, destination)
        p.tutorialStep = nil
        renderRequire(!camera.isRunning && camera.previewImage == nil, "Rendering must not activate camera")
        let lightCamera = CameraAnchorService(capture: RenderCamera(), showVideoEffects: { renderFailure("Rendering cannot open system UI") })
        try await lightCamera.startBurst { _ in }
        p.topInset = 32; p.demo = false; p.snapshot = states[2].1
        try render("edge-light-controls", p, lightCamera, destination)
        lightCamera.stop()
        print("Rendered \(states.count + 37) notch states at 2x plus AirPods and brightness motion fixtures without camera capture")
    }
    @discardableResult
    @MainActor static func render(_ name: String, _ p: NotchOverlayPresentation, _ camera: CameraAnchorService, _ destination: URL) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: NotchCoachView(presentation: p, camera: camera, headMotion: NotchMotionFeedback())
            .background(Color(white: 0.20))
            .transaction { $0.animation = nil; $0.disablesAnimations = true })
        renderer.scale = 2
        guard let cg = renderer.cgImage else {
            renderFailure("Could not render \(name)")
        }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { renderFailure("Could not encode \(name)") }
        renderRequire(bitmap.pixelsWide == 720 && bitmap.pixelsHigh == Int((p.topInset + 380) * 2),
                     "The animated view must retain its full native panel bounds")
        try data.write(to: destination.appendingPathComponent("\(name).png"))
        return bitmap
    }
    private struct RevealMetrics {
        let width: CGFloat
        let center: CGFloat
    }
    private static func imageRegion(_ bitmap: NSBitmapImageRep, points: CGRect) -> [UInt8] {
        guard let bytes = bitmap.bitmapData else { renderFailure("Could not inspect generated art pixels") }
        let channels = bitmap.bitsPerPixel / 8
        var result: [UInt8] = []
        for y in Int(points.minY * 2)..<min(bitmap.pixelsHigh, Int(points.maxY * 2)) {
            let start = y * bitmap.bytesPerRow + Int(points.minX * 2) * channels
            let length = Int(points.width * 2) * channels
            result.append(contentsOf: UnsafeBufferPointer(start: bytes + start, count: length))
        }
        return result
    }
    @MainActor private static func renderRecoveryGlyph(time: Double, moving: Bool, name: String, destination: URL) throws -> Data {
        let renderer = ImageRenderer(content: NotchBrightnessRecoveryGlyph(stage: .announcing, elapsed: time, moving: moving)
            .frame(width: 160, height: 100).background(.black))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            renderFailure("Could not render brightness artwork")
        }
        try data.write(to: destination.appendingPathComponent("\(name).png"))
        return data
    }
    @MainActor private static func renderStaticWearGlyph(time: Double, name: String, destination: URL) throws -> Data {
        let renderer = ImageRenderer(content: NotchAirPodsWaitGlyph(elapsed: time, moving: false)
            .frame(width: 160, height: 100).background(.black))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            renderFailure("Could not render static AirPods artwork")
        }
        try data.write(to: destination.appendingPathComponent("\(name).png"))
        return data
    }
    /// Measure actual black output against the fixture's gray background. This
    /// catches a view still drawing a fixed-width stem even if Shape tests pass.
    @MainActor private static func revealMetrics(_ bitmap: NSBitmapImageRep) -> RevealMetrics {
        func isBlack(_ x: Int, _ y: Int) -> Bool {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return color.alphaComponent > 0.95 && max(color.redComponent, color.greenComponent, color.blueComponent) < 0.025
        }
        let occupied = (0..<bitmap.pixelsWide).filter { isBlack($0, 16) }
        guard let left = occupied.first, let right = occupied.last else {
            renderFailure("Rendered notch must have a connected black screen-edge band")
        }
        return RevealMetrics(width: CGFloat(right - left + 1) / 2,
                             center: CGFloat(left + right + 1) / 4)
    }
}

@MainActor private final class RenderCamera: CameraAnchorCapturing {
    var authorization: CameraAuthorization { .authorized }
    func requestPermission() async -> Bool { renderFailure("Rendering cannot request permission") }
    func start(onFrame: @escaping @MainActor (CameraAnchorFrame) -> Void,
               onPreview: @escaping @MainActor (CGImage) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) async throws -> CameraAnchorConfiguration {
        .init(cameraID: "render-only", cameraName: "Render only", configurationID: "render-only",
              captureFramesPerSecond: 15, supportsEdgeLight: true)
    }
    func stop() {}
}

private func renderRequire(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { renderFailure(message) }
}

private func renderFailure(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(EXIT_FAILURE)
}
