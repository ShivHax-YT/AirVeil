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
    var canRequestEnable = true
    @Published var wearAirPodsPrompt = false
    var showWindow: (() -> Void)?
    var centerCalls = 0, refreshCalls = 0, enableCameraCalls = 0
    var enableCalls = 0, cancelWearCalls = 0
    func calibrate() { centerCalls += 1 }
    func refreshCameraDirection() { refreshCalls += 1 }
    func enableCameraAssistance() { enableCameraCalls += 1 }
    func pause() { enabled = false; wearAirPodsPrompt = false; cameraHeading.coach = .init() }
    func enable() {
        enableCalls += 1
        if motion.isFresh { enabled = true } else { wearAirPodsPrompt = true }
    }
    func cancelWearWait() { cancelWearCalls += 1; pause() }
}

@main struct NotchOverlayLifecycleTests {
    @MainActor static func main() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = AppModel()
        let suite = "AirVeil.NotchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: NotchOverlayController.tutorialCompletionKey)
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = NotchOverlayController(model: model, defaults: defaults)
        defer { controller.shutdown() }
        var checks = 0
        func fail(_ message: String) -> Never {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            controller.shutdown()
            for window in app.windows { window.close() }
            defaults.removePersistentDomain(forName: suite)
            exit(EXIT_FAILURE)
        }
        func check(_ result: Bool, _ message: String) {
            checks += 1
            if !result { fail(message) }
        }
        // Combine delivers on the main queue, matching production.
        func drain() async { try? await Task.sleep(nanoseconds: 30_000_000) }
        await drain()
        guard let panel = app.windows.first(where: { $0.title == "AirVeil Notch Coach" }),
              let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else {
            fail("Native panel and screen must exist")
        }
        check(panel.styleMask.contains(.nonactivatingPanel) && !panel.canBecomeKey && !panel.canBecomeMain,
              "The notch cannot take keyboard focus")
        check(!panel.canHide, "Hiding Settings does not hide an active camera check")
        check(panel.level.rawValue > NSWindow.Level.statusBar.rawValue && panel.collectionBehavior.contains(.fullScreenAuxiliary),
              "Coach stays above ordinary windows, desktop coverage, and face light in fullscreen spaces")
        check(panel.frame.midX >= screen.frame.minX && panel.frame.midX <= screen.frame.maxX,
              "Panel targets the notched screen even with an external main display")
        if screen.safeAreaInsets.top > 0 {
            check(panel.frame.maxY == screen.frame.maxY, "Panel attaches flush to actual notch top")
        }
        // Inspect the real mask's occupied pixels, rather than repeating its
        // interpolation formula. The attached screen-edge region expands too.
        let canvas = CGRect(x: 0, y: 0, width: 360, height: 412)
        for topInset in [0.0, 32.0] {
            var previous: Path?
            for amount in [0.0, 0.15, 0.35, 0.65, 0.9, 1.0] {
                let silhouette = NotchCanopy(hardwareWidth: 180, topInset: topInset,
                    bodyWidth: 236, bodyHeight: 190, reveal: amount).path(in: canvas)
                let bounds = silhouette.boundingRect
                if amount > 0 || topInset > 0 {
                    check(abs(bounds.midX - canvas.midX) < 0.001 && bounds.minY == 0,
                          "Expansion stays centered and attached to the top")
                    check(canvas.contains(bounds), "The complete silhouette stays inside its native panel")
                }
                var symmetric = true, retainsPrevious = true
                // Avoid exact integral edge points: CGPath containment includes
                // one boundary side and excludes the opposite boundary side.
                for y in stride(from: 2.25, through: 410.25, by: 4) {
                    for x in stride(from: 2.25, through: 178.25, by: 4) {
                        let left = CGPoint(x: x, y: y), right = CGPoint(x: 360 - x, y: y)
                        symmetric = symmetric && (silhouette.contains(left) == silhouette.contains(right))
                        for point in [left, right] where previous?.contains(point) == true {
                            retainsPrevious = retainsPrevious && silhouette.contains(point)
                        }
                    }
                }
                check(symmetric, "Left and right edges expand symmetrically at every reveal")
                if topInset > 0 {
                    check(retainsPrevious, "Attached-notch opening never removes previously revealed mask area")
                }
                // The external-display fallback also rounds its top corners;
                // that changing radius can move individual corner pixels even
                // while its overall silhouette grows in both directions.
                if let previous, amount > 0.15 {
                    check(bounds.width > previous.boundingRect.width && bounds.maxY > previous.boundingRect.maxY,
                          "Each later keyframe grows both sideways and downward")
                }
                if topInset > 0 {
                    check(silhouette.contains(CGPoint(x: 180, y: 8)), "The center remains joined to the physical notch")
                    if amount == 0 {
                        check(bounds.width == 180 && bounds.height == 32,
                              "Collapsed silhouette occupies only the hardware notch bounds")
                    } else if amount == 1 {
                        check(silhouette.contains(CGPoint(x: 82, y: 8)) && silhouette.contains(CGPoint(x: 278, y: 8)),
                              "The screen-edge band visibly grows left and right beyond the cutout")
                    }
                }
                previous = silhouette
            }
        }
        check(controller.presentation.contentWidth < 250, "Camera coach uses the compact vertical silhouette")
        check(controller.presentation.canopyWidth > controller.presentation.contentWidth,
              "The wider black surround preserves the existing camera and rail layout width")
        for phase in [NotchCoachPhase.seeking, .lighting, .failure, .success] {
            let presentation = NotchOverlayPresentation()
            presentation.snapshot = .init(phase: phase, title: "Fixture", detail: "")
            let mask = NotchCanopy(hardwareWidth: presentation.hardwareWidth, topInset: presentation.topInset,
                bodyWidth: presentation.canopyWidth, bodyHeight: presentation.contentHeight).path(in: canvas)
            let halfWidth = presentation.contentWidth / 2 - 16
            let interior = [CGPoint(x: 180 - halfWidth, y: presentation.topInset + 14),
                            CGPoint(x: 180 + halfWidth, y: presentation.topInset + 14),
                            CGPoint(x: 180 - halfWidth, y: presentation.topInset + presentation.contentHeight - 16),
                            CGPoint(x: 180 + halfWidth, y: presentation.topInset + presentation.contentHeight - 16)]
            check(interior.allSatisfy { mask.contains($0) }, "Expanded \(phase) mask contains padded camera/rail/glyph bounds")
        }
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
        check(controller.presentation.canopyWidth == 360, "Controls fit the fixed native panel without extra width")
        model.cameraHeading.coach = .init(phase: .holding, title: "Hold", detail: "", progress: 0.4)
        await drain()
        check(!controller.presentation.controls && !controller.presentation.demo, "Real calibration takes ownership of the panel")
        controller.presentation.cancel()
        await drain()
        check(!controller.presentation.expanded && model.cameraHeading.coach.phase == .idle, "Cancel stops the task and dismisses coach")
        model.cameraHeading.coach = .init(phase: .success, title: "Center confirmed", detail: "", progress: 1)
        await drain()
        check(panel.isVisible && panel.level.rawValue > NSWindow.Level.statusBar.rawValue && !panel.isKeyWindow,
              "The completed check keeps the same elevated, nonactivating panel as camera guidance")
        model.cameraHeading.coach = .init()
        await drain()
        check(!controller.presentation.expanded && controller.presentation.snapshot.phase == .success,
              "Retraction keeps the green smile instead of flashing an idle camera")
        model.cameraHeading.coach = .init(phase: .offCenter, title: "Look ahead", detail: "", issue: .pose)
        await drain()
        try? await Task.sleep(for: .seconds(NotchOverlayPresentation.expansionDuration + 0.15))
        check(controller.presentation.expanded && controller.presentation.snapshot.phase == .offCenter,
              "An old dismissal cannot clear or hide a newer live check")
        model.cameraHeading.coach = .init()
        await drain()
        try? await Task.sleep(for: .seconds(NotchOverlayPresentation.expansionDuration + 0.15))
        check(!panel.isVisible && controller.presentation.snapshot.phase == .idle,
              "Only the finished retraction clears the old visual snapshot")
        let originalFrame = panel.frame
        model.motion.isFresh = false
        controller.showControls()
        check(controller.presentation.canEnable, "Missing AirPods motion alone does not disable Enable blur")
        model.canRequestEnable = false
        controller.updateControls()
        check(!controller.presentation.canEnable, "Notch enable readiness follows the model's permission/session gate")
        model.canRequestEnable = true
        controller.updateControls()
        controller.presentation.toggleEffect()
        await drain()
        check(model.enableCalls == 1 && controller.presentation.wearAirPodsPrompt && controller.presentation.expanded,
              "Enable blur without motion opens the model's wait surface")
        check(!controller.presentation.controls && !controller.presentation.demo && panel.frame == originalFrame,
              "Waiting morphs inside the existing panel instead of opening a separate window")
        check(controller.presentation.contentWidth == 280 && controller.presentation.canopyWidth <= panel.frame.width,
              "Wear illustration and button fit within the fixed panel")
        controller.showControls()
        controller.previewAnimation()
        model.cameraHeading.coach = .init()
        controller.updatePointerPosition(CGPoint(x: -20000, y: -20000))
        await drain()
        try? await Task.sleep(for: .seconds(NotchOverlayPresentation.expansionDuration + 0.15))
        check(controller.presentation.expanded && controller.presentation.wearAirPodsPrompt && !controller.presentation.demo,
              "Pointer exit, idle delivery, controls, and demo cannot replace the active wait")
        model.cameraHeading.coach = .init(phase: .failure, title: "Old check", detail: "")
        await drain()
        check(controller.presentation.wearAirPodsPrompt,
              "A previous camera result does not take priority over current removal waiting")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        check(!controller.presentation.expanded, "Session sleep collapses the wait surface")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        check(controller.presentation.expanded && controller.presentation.wearAirPodsPrompt,
              "A still-active wait returns after wake without enabling blur itself")
        model.wearAirPodsPrompt = false
        model.cameraHeading.coach = .init(phase: .starting, title: "Checking direction", detail: "")
        await drain()
        check(!controller.presentation.wearAirPodsPrompt && controller.presentation.snapshot.phase == .starting && controller.presentation.expanded,
              "Fresh return hands the same panel to the actual camera alignment state")
        model.cameraHeading.coach = .init()
        model.wearAirPodsPrompt = true
        await drain()
        try? await Task.sleep(for: .seconds(NotchOverlayPresentation.expansionDuration + 0.15))
        check(controller.presentation.wearAirPodsPrompt && controller.presentation.expanded,
              "Queued old idle or dismissal work cannot hide a new removal wait")
        controller.presentation.turnOffFeature()
        await drain()
        check(model.cancelWearCalls == 1 && !model.wearAirPodsPrompt && !controller.presentation.expanded,
              "Turn off feature delegates cancellation to the owner exactly once")
        check(controller.presentation.wearAirPodsPrompt,
              "Retraction retains the wear illustration instead of flashing an idle camera")
        try? await Task.sleep(for: .seconds(NotchOverlayPresentation.expansionDuration + 0.15))
        check(!panel.isVisible && !controller.presentation.wearAirPodsPrompt,
              "Finished cancellation clears and hides the old waiting artwork")
        controller.showControls()
        controller.presentation.toggleEffect()
        await drain()
        check(model.enableCalls == 2 && controller.presentation.wearAirPodsPrompt,
              "The ordinary Enable blur control can explicitly reenter waiting without motion")
        controller.presentation.cancel()
        await drain()
        check(model.cancelWearCalls == 2, "Accessible Cancel while waiting uses the same cancellation owner")
        try? await Task.sleep(for: .seconds(NotchOverlayPresentation.expansionDuration + 0.15))
        check(!model.cameraHeading.camera.isRunning && model.cameraHeading.camera.previewImage == nil, "Lifecycle tests never start the camera")
        controller.shutdown()
        defaults.removeObject(forKey: NotchOverlayController.tutorialCompletionKey)
        let firstUseModel = AppModel()
        firstUseModel.wearAirPodsPrompt = true
        let firstUse = NotchOverlayController(model: firstUseModel, defaults: defaults)
        firstUse.showControls()
        await drain()
        check(firstUse.presentation.wearAirPodsPrompt && firstUse.presentation.tutorialStep == nil,
              "An urgent first-use wear prompt does not start or complete the tutorial")
        firstUseModel.wearAirPodsPrompt = false
        await drain()
        try? await Task.sleep(for: .seconds(NotchOverlayPresentation.expansionDuration + 0.15))
        firstUse.showControls()
        check(firstUse.presentation.tutorialStep == .tracking && firstUse.presentation.expanded,
              "The very first notch appearance opens the tutorial")
        firstUseModel.wearAirPodsPrompt = true
        await drain()
        check(firstUse.presentation.wearAirPodsPrompt && firstUse.presentation.tutorialStep == .tracking,
              "A removal wait keeps an unfinished tutorial's place")
        firstUse.presentation.turnOffFeature()
        await drain()
        check(!firstUse.presentation.wearAirPodsPrompt && firstUse.presentation.tutorialStep == .tracking && firstUse.presentation.expanded,
              "Canceling removal returns to the pending tutorial without marking it complete")
        firstUse.updatePointerPosition(CGPoint(x: -20000, y: -20000))
        firstUse.presentation.cancel()
        await drain()
        try? await Task.sleep(for: .seconds(NotchOverlayPresentation.expansionDuration + 0.15))
        check(firstUse.presentation.expanded && firstUse.presentation.tutorialStep != nil,
              "Pointer exit, cancel, idle delivery and delayed dismissal cannot end the tutorial")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        check(!firstUse.presentation.expanded && firstUse.presentation.tutorialStep != nil,
              "Sleep temporarily hides the tutorial without completing it")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        check(firstUse.presentation.expanded, "The unfinished tutorial returns after wake")
        firstUse.shutdown()
        check(!defaults.bool(forKey: NotchOverlayController.tutorialCompletionKey), "Quit is not tutorial completion")
        let resumed = NotchOverlayController(model: AppModel(), defaults: defaults)
        resumed.showControls()
        check(resumed.presentation.tutorialStep != nil, "Unfinished first-use tutorial returns on next launch")
        resumed.presentation.tutorialStep = .controls
        resumed.presentation.endTutorial()
        check(resumed.presentation.tutorialStep == nil && defaults.bool(forKey: NotchOverlayController.tutorialCompletionKey),
              "Only End tutorial records completion")
        resumed.shutdown()
        let finished = NotchOverlayController(model: AppModel(), defaults: defaults)
        finished.showControls()
        check(finished.presentation.tutorialStep == nil && finished.presentation.controls,
              "Completed tutorial does not repeat on later notch appearances")
        finished.shutdown()
        print("Passed \(checks) native notch controller lifecycle checks")
    }
}
