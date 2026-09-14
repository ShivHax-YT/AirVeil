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
        p.expanded = true; p.demo = true; p.canCenter = true; p.cameraEnabled = true
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
        for (index, amount) in [0.0, 0.15, 0.35, 0.65, 0.9, 1.0].enumerated() {
            p.revealProgress = amount
            try render("reveal-keyframe-\(index)", p, camera, destination)
        }
        p.revealProgress = nil
        p.controls = true
        try render("controls", p, camera, destination)
        p.topInset = 0; p.controls = false; p.snapshot = states[1].1
        try render("external-display", p, camera, destination)
        precondition(!camera.isRunning && camera.previewImage == nil, "Rendering must not activate camera")
        let lightCamera = CameraAnchorService(capture: RenderCamera(), showVideoEffects: { fatalError("Rendering cannot open system UI") })
        try await lightCamera.startBurst { _ in }
        p.topInset = 32; p.demo = false; p.snapshot = states[2].1
        try render("edge-light-controls", p, lightCamera, destination)
        lightCamera.stop()
        print("Rendered \(states.count + 15) notch states at 2x without camera capture")
    }
    @MainActor static func render(_ name: String, _ p: NotchOverlayPresentation, _ camera: CameraAnchorService, _ destination: URL) throws {
        let renderer = ImageRenderer(content: NotchCoachView(presentation: p, camera: camera, headMotion: NotchMotionFeedback())
            .background(Color(white: 0.20)))
        renderer.scale = 2
        guard let cg = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            fatalError("Could not render \(name)")
        }
        try data.write(to: destination.appendingPathComponent("\(name).png"))
    }
}

@MainActor private final class RenderCamera: CameraAnchorCapturing {
    var authorization: CameraAuthorization { .authorized }
    func requestPermission() async -> Bool { fatalError("Rendering cannot request permission") }
    func start(onFrame: @escaping @MainActor (CameraAnchorFrame) -> Void,
               onPreview: @escaping @MainActor (CGImage) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) async throws -> CameraAnchorConfiguration {
        .init(cameraID: "render-only", cameraName: "Render only", configurationID: "render-only",
              captureFramesPerSecond: 15, supportsEdgeLight: true)
    }
    func stop() {}
}
