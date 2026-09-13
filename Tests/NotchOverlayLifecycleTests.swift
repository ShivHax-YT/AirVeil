import AppKit
import Combine

// The actual native controller/view run against a fake application boundary.
// No motion, permission request, camera capture, power action, or preference writes.
@MainActor final class StubMotion { var isFresh = true }
@MainActor final class StubCoordinator: ObservableObject {
    @Published var coach = NotchCoachSnapshot()
    let camera = CameraAnchorService()
    var isBusy = false
    var isEnabled = true
    var hasCenter = true
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
        model.cameraHeading.coach = .init(phase: .holding, title: "Hold", detail: "", progress: 0.4)
        await drain()
        check(!controller.presentation.controls && !controller.presentation.demo, "Real calibration takes ownership of the panel")
        controller.presentation.cancel()
        await drain()
        check(!controller.presentation.expanded && model.cameraHeading.coach.phase == .idle, "Cancel stops the task and dismisses coach")
        check(!model.cameraHeading.camera.isRunning && model.cameraHeading.camera.previewImage == nil, "Lifecycle tests never start the camera")
        print("Passed \(checks) native notch controller lifecycle checks")
    }
}
