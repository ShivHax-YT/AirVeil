import AppKit
import SwiftUI

@main struct NotchViewRender {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        // Constructing the service does not start or request access to the camera.
        let camera = CameraAnchorService()
        let p = NotchOverlayPresentation()
        p.expanded = true; p.demo = true; p.canCenter = true; p.cameraEnabled = true
        let states: [(String, NotchCoachSnapshot)] = [
            ("seeking", .init(phase: .seeking, title: "Looking for your face", detail: "Face the camera and keep your face visible.", issue: .faceMissing)),
            ("off-center", .init(phase: .offCenter, title: "A bit right", detail: "Bring your face toward the middle of the preview.", horizontalError: -0.55, direction: .right)),
            ("low-light", .init(phase: .seeking, title: "A little more light", detail: "Light your face so the camera can see you.", issue: .lowLight)),
            ("holding", .init(phase: .holding, title: "Hold your head still", detail: "Measuring camera and AirPods together.", progress: 0.65)),
            ("turning", .init(phase: .turning, title: "Make one gentle head turn", detail: "Turn left or right, then hold briefly.")),
            ("success", .init(phase: .success, title: "Direction restored", detail: "You're ready. Camera is off.", progress: 1)),
            ("failure", .init(phase: .failure, title: "Try the direction check again", detail: "Keep your face visible and hold still briefly.", issue: .camera))
        ]
        for (name, state) in states {
            p.snapshot = state
            try render(name, p, camera, destination)
        }
        p.controls = true
        try render("controls", p, camera, destination)
        p.topInset = 0; p.controls = false; p.snapshot = states[1].1
        try render("external-display", p, camera, destination)
        precondition(!camera.isRunning && camera.previewImage == nil, "Rendering must not activate camera")
        print("Rendered \(states.count + 2) notch states at 2x without camera capture")
    }
    @MainActor static func render(_ name: String, _ p: NotchOverlayPresentation, _ camera: CameraAnchorService, _ destination: URL) throws {
        let renderer = ImageRenderer(content: NotchCoachView(presentation: p, camera: camera))
        renderer.scale = 2
        guard let cg = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            fatalError("Could not render \(name)")
        }
        try data.write(to: destination.appendingPathComponent("\(name).png"))
    }
}
