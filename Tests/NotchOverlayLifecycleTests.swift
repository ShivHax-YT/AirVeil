import AppKit
import Combine
import SwiftUI

// The actual native controller/view run against a fake application boundary.
// No motion, permission request, camera capture, power action, or preference writes.
@MainActor final class StubMotion { var isFresh = true }
@MainActor final class StubCoordinator: ObservableObject {
    @Published var coach = NotchCoachSnapshot()
    let camera = CameraAnchorService()
    let notchMotion = NotchMotionFeedback()
    var isBusy = false
    var isEnabled = true
    var hasCenter = true
    var lightToggleCalls = 0
    func toggleAssistLight() { lightToggleCalls += 1 }
}
@MainActor final class AppModel {
    let motion = StubMotion()
    let cameraHeading = StubCoordinator()
    var centerBusy = false
    var enabled = false
    var starting = false
    var showWindow: (() -> Void)?
    var centerCalls = 0, refreshCalls = 0, enableCameraCalls = 0
    func calibrate() { centerCalls += 1 }
    func refreshCameraDirection() { refreshCalls += 1 }
    func enableCameraAssistance() { enableCameraCalls += 1 }
    func pause() { enabled = false; cameraHeading.coach = .init() }
    func enable() { enabled = true }
}

@main struct NotchOverlayLifecycleTests {
    @MainActor static func main() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = AppModel()
        let controller = NotchOverlayController(model: model)
        defer { controller.shutdown() }
        var checks = 0
        func check(_ result: Bool, _ message: String) {
            checks += 1
            if !result { fatalError(message) }
        }
        // Combine delivers on the main queue, matching production.
        func drain() async { try? await Task.sleep(nanoseconds: 30_000_000) }
        await drain()
        guard let panel = app.windows.first(where: { $0.title == "AirVeil Notch Coach" }),
              let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else {
            fatalError("Native panel and screen must exist")
        }
        check(panel.styleMask.contains(.nonactivatingPanel) && !panel.canBecomeKey && !panel.canBecomeMain,
              "The notch cannot take keyboard focus")
        check(panel.level == .statusBar && panel.collectionBehavior.contains(.fullScreenAuxiliary),
              "Panel supports fullscreen auxiliary presentation")
        check(panel.frame.midX >= screen.frame.minX && panel.frame.midX <= screen.frame.maxX,
              "Panel targets the notched screen even with an external main display")
        if screen.safeAreaInsets.top > 0 {
            check(panel.frame.maxY == screen.frame.maxY, "Panel attaches flush to actual notch top")
        }
        // Every intermediate reveal keeps the hardware region exactly cutout-wide.
        // Outside shoulders and rounded lower corners must remain click-through.
        for amount in [0.0, 0.15, 0.5, 1.0] {
            let silhouette = NotchCanopy(hardwareWidth: 180, topInset: 32, bodyWidth: 212, bodyHeight: 190, reveal: amount)
                .path(in: CGRect(x: 0, y: 0, width: 360, height: 292))
            check(!silhouette.contains(CGPoint(x: 85, y: 10)) && !silhouette.contains(CGPoint(x: 275, y: 10)),
                  "Animation must never cover menu-bar content outside the hardware cutout")
            check(silhouette.contains(CGPoint(x: 180, y: 16)), "Stem stays joined to physical notch throughout reveal")
            check(!silhouette.contains(CGPoint(x: 74, y: 221)), "Rounded lower corners stay transparent")
        }
        check(controller.presentation.contentWidth < 250, "Camera coach uses the compact vertical silhouette")
        model.cameraHeading.coach = .init(phase: .lighting, title: "Light too low", detail: "Face light starts off", issue: .lowLight)
        await drain()
        controller.presentation.toggleAssistLight()
        check(model.cameraHeading.lightToggleCalls == 1, "The center light control routes to the real light owner")
        check(!controller.presentation.controls && controller.presentation.snapshot.phase == .lighting,
              "Light help is a dedicated compact coach stage")
        model.cameraHeading.coach = .init(phase: .failure, title: "Camera changed", detail: "Set center again", issue: .configuration)
        await drain()
        controller.presentation.refresh()
        check(model.centerCalls == 1 && model.refreshCalls == 0, "Configuration mismatch retry replaces the incompatible reference")
        model.cameraHeading.isEnabled = false
        controller.presentation.refresh()
        check(model.enableCameraCalls == 1 && model.centerCalls == 1, "Camera opt-in retry cannot calibrate the legacy sensor instead")
        model.cameraHeading.isEnabled = true
        model.cameraHeading.coach = .init(phase: .failure, title: "Try again", detail: "", issue: .faceMissing)
        await drain()
        controller.presentation.refresh()
        check(model.refreshCalls == 1 && model.centerCalls == 1, "Ordinary retry preserves saved center")
        model.cameraHeading.coach = .init(phase: .failure, title: "Retry center", detail: "", issue: .camera, retryAction: .setCenter)
        await drain()
        controller.presentation.refresh()
        check(model.centerCalls == 2 && model.refreshCalls == 1, "Failed explicit recenter retries that operation despite an old saved center")
        model.cameraHeading.coach = .init(phase: .failure, title: "Camera permission changed", detail: "", issue: .camera, retryAction: .enableCamera)
        await drain()
        controller.presentation.refresh()
        check(model.enableCameraCalls == 2, "Revoked camera permission retries opt-in despite persisted enablement")
        model.cameraHeading.coach = .init()
        await drain()
        controller.previewAnimation()
        await drain()
        check(controller.presentation.demo && controller.presentation.expanded, "Explicit animation preview appears")
        check(panel.isVisible && !panel.isKeyWindow, "Visible native overlay leaves the key window unchanged")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        check(!controller.presentation.demo && !controller.presentation.expanded, "Sleep clears demo and hides panel synchronously")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        controller.showControls()
        check(controller.presentation.controls && controller.presentation.expanded, "Controls remain available after canceled preview and wake")
        check(controller.presentation.contentWidth == 360, "Only disclosed controls use the wider body")
        model.cameraHeading.coach = .init(phase: .holding, title: "Hold", detail: "", progress: 0.4)
        await drain()
        check(!controller.presentation.controls && !controller.presentation.demo, "Real calibration takes ownership of the panel")
        controller.presentation.cancel()
        await drain()
        check(!controller.presentation.expanded && model.cameraHeading.coach.phase == .idle, "Cancel stops the task and dismisses coach")
        model.cameraHeading.coach = .init(phase: .success, title: "Center confirmed", detail: "", progress: 1)
        await drain()
        model.cameraHeading.coach = .init()
        await drain()
        check(!controller.presentation.expanded && controller.presentation.snapshot.phase == .success,
              "Retraction keeps the green smile instead of flashing an idle camera")
        model.cameraHeading.coach = .init(phase: .offCenter, title: "Look ahead", detail: "", issue: .pose)
        await drain()
        try? await Task.sleep(nanoseconds: 550_000_000)
        check(controller.presentation.expanded && controller.presentation.snapshot.phase == .offCenter,
              "An old dismissal cannot clear or hide a newer live check")
        model.cameraHeading.coach = .init()
        await drain()
        try? await Task.sleep(nanoseconds: 550_000_000)
        check(!panel.isVisible && controller.presentation.snapshot.phase == .idle,
              "Only the finished retraction clears the old visual snapshot")
        check(!model.cameraHeading.camera.isRunning && model.cameraHeading.camera.previewImage == nil, "Lifecycle tests never start the camera")
        print("Passed \(checks) native notch controller lifecycle checks")
    }
}
