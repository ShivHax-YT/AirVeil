import AppKit
import SwiftUI
import Combine

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// This surface presents the coordinator's result. It never sets a reference,
/// opens a second camera, or authenticates/unlocks the Mac.
@MainActor final class NotchOverlayController {
    let presentation = NotchOverlayPresentation()
    private let model: AppModel
    private let defaults: UserDefaults
    static let tutorialCompletionKey = "notchTutorialCompletedV1"
    private var panel: NotchPanel?
    private var geometry: NotchGeometry?
    private var subscriptions = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var globalMouse: Any?
    private var localMouse: Any?
    private var hoverWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var demoTask: Task<Void, Never>?
    private var active = true
    private var pointerInside = false
    private var wearReminderDismissed = false
    private var recoveryNoticeDismissed = false
    private var lastRecoveryState: NotchBrightnessRecoveryStage = .none
    private var recoveryStage: NotchBrightnessRecoveryStage = .none
    private var recoveryCompletionWork: DispatchWorkItem?
    private var contentHeight: CGFloat = 190
    var windowLevel: Int { panel?.level.rawValue ?? -1 }

    init(model: AppModel, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
        presentation.endTutorial = { [weak self] in self?.endTutorial() }
        presentation.center = { [weak self] in self?.setCenter() }
        presentation.refresh = { [weak self] in self?.retry() }
        presentation.cancel = { [weak self] in self?.cancel() }
        presentation.settings = { [weak self] in self?.model.showWindow?() }
        presentation.toggleAssistLight = { [weak self] in self?.model.cameraHeading.toggleAssistLight() }
        presentation.turnOffFeature = { [weak self] in self?.model.cancelWearWait() }
        presentation.dismissReminder = { [weak self] in self?.dismissReminder() }
        presentation.toggleEffect = { [weak self] in
            guard let self else { return }
            if model.wearAirPodsPrompt || model.removalPresence.lowLightRecoveryState != .none { model.cancelWearWait() }
            else if model.enabled || model.starting { model.pause() } else { model.enable() }
            updateControls()
        }
        presentation.contentHeightChanged = { [weak self] height in
            guard height.isFinite, height > 0 else { return }
            self?.contentHeight = height
            self?.updateHitTesting()
        }
        model.cameraHeading.$coach.combineLatest(model.$wearAirPodsPrompt)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            // A queued old idle/wait event must not replace a newer camera check.
            self.receive(self.model.cameraHeading.coach)
        }.store(in: &subscriptions)
        model.removalPresence.$lowLightRecoveryState
            .combineLatest(model.removalPresence.$recoveryReason)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self else { return }
                self.receive(self.model.cameraHeading.coach)
            }.store(in: &subscriptions)
        rebuildPanel()
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildPanel() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.active = false; self?.demoTask?.cancel()
                    self?.presentation.demo = false
                    self?.hide(immediately: true)
                }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // AppModel gates actual camera work on all three session states.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.active = true
                    if self.model.wearAirPodsPrompt || self.model.removalPresence.lowLightRecoveryState != .none {
                        self.receive(self.model.cameraHeading.coach)
                    }
                    else if self.presentation.tutorialStep != nil { self.show() }
                }
            })
        }
        globalMouse = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        localMouse = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }
    }

    func updateControls() {
        presentation.canCenter = model.motion.isFresh && !model.centerBusy
        presentation.cameraEnabled = model.cameraHeading.isEnabled
        presentation.canEnable = model.canRequestEnable
        presentation.enabled = model.enabled
        presentation.canTurnOffFeature = model.wearAirPodsPrompt || model.removalPresence.lowLightRecoveryState != .none
    }
    func showControls() {
        guard active else { return }
        if model.removalPresence.lowLightRecoveryState != .none, !recoveryNoticeDismissed { receive(model.cameraHeading.coach); return }
        if model.wearAirPodsPrompt, !wearReminderDismissed { receive(model.cameraHeading.coach); return }
        if !model.wearAirPodsPrompt, model.removalPresence.lowLightRecoveryState == .none,
           model.cameraHeading.coach.phase != .idle { receive(model.cameraHeading.coach); return }
        updateControls(); presentation.demo = false; presentation.wearAirPodsPrompt = false
        presentation.brightnessRecovery = .none; presentation.controls = true
        show()
    }
    private func setCenter() {
        if model.cameraHeading.isEnabled { model.calibrate() }
        else { model.enableCameraAssistance() }
        updateControls()
    }
    private func retry() {
        if let action = presentation.snapshot.retryAction {
            switch action {
            case .enableCamera: model.enableCameraAssistance()
            case .setCenter: model.calibrate()
            case .refreshDirection: model.refreshCameraDirection()
            }
            return
        }
        if !model.cameraHeading.isEnabled { model.enableCameraAssistance() }
        else if presentation.snapshot.issue == .configuration { model.calibrate() }
        else if model.cameraHeading.hasCenter { model.refreshCameraDirection() }
        else { model.calibrate() }
    }
    private func endTutorial() {
        guard presentation.tutorialStep != nil else { return }
        defaults.set(true, forKey: Self.tutorialCompletionKey)
        presentation.tutorialStep = nil
        demoTask?.cancel(); presentation.demo = false
        if model.cameraHeading.coach.phase != .idle { receive(model.cameraHeading.coach) }
        else { updateControls(); presentation.controls = true; show() }
    }
    private func cancel() {
        if model.wearAirPodsPrompt || model.removalPresence.lowLightRecoveryState != .none { model.cancelWearWait(); return }
        // Stopping a camera check never dismisses the teaching surface.
        if presentation.tutorialStep != nil { model.pause(); return }
        if presentation.demo { demoTask?.cancel(); presentation.demo = false; hide(); return }
        model.pause()
        hide()
    }
    private func dismissReminder() {
        guard model.wearAirPodsPrompt || model.removalPresence.lowLightRecoveryState != .none else { return }
        wearReminderDismissed = model.wearAirPodsPrompt
        recoveryNoticeDismissed = model.removalPresence.lowLightRecoveryState != .none
        // This only retracts the panel. The model keeps monitoring, and a real
        // AirPods return still takes ownership with its camera check.
        hide(dismissingReminder: true)
    }
    private func receive(_ snapshot: NotchCoachSnapshot) {
        guard active else { return }
        if !model.wearAirPodsPrompt { wearReminderDismissed = false }
        let recovery = NotchBrightnessRecoveryStage(rawValue: model.removalPresence.lowLightRecoveryState.rawValue) ?? .none
        if recovery != lastRecoveryState {
            lastRecoveryState = recovery
            recoveryCompletionWork?.cancel(); recoveryCompletionWork = nil
            // A display dimmed to zero cannot show the advance notice. Keep
            // the reason legible after successful restoration before the camera.
            recoveryStage = recovery == .monitoring ? .restored : recovery
            if recovery == .monitoring {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.active, !self.recoveryNoticeDismissed,
                          self.model.removalPresence.lowLightRecoveryState == .monitoring else { return }
                    self.recoveryStage = .monitoring
                    self.receive(self.model.cameraHeading.coach)
                }
                recoveryCompletionWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
            }
        }
        if recovery == .none { recoveryNoticeDismissed = false }
        if recovery != .none {
            guard !recoveryNoticeDismissed else { return }
            demoTask?.cancel(); presentation.demo = false
            presentation.controls = false; presentation.wearAirPodsPrompt = false
            presentation.brightnessRecoveryReason = NotchBrightnessRecoveryReason(rawValue: model.removalPresence.recoveryReason.rawValue) ?? .seatRecheck
            presentation.brightnessRecovery = recoveryStage
            updateControls(); show()
            return
        }
        if model.wearAirPodsPrompt {
            guard !wearReminderDismissed else {
                if presentation.brightnessRecovery != .none { hide(dismissingReminder: true) }
                return
            }
            demoTask?.cancel(); presentation.demo = false
            presentation.brightnessRecovery = .none
            presentation.controls = false; presentation.wearAirPodsPrompt = true
            updateControls(); show()
            return
        }
        let wasWaiting = presentation.wearAirPodsPrompt || presentation.brightnessRecovery != .none
        if snapshot.phase != .idle {
            demoTask?.cancel(); presentation.demo = false
            presentation.wearAirPodsPrompt = false
            presentation.brightnessRecovery = .none
            presentation.controls = false; presentation.snapshot = snapshot
            show()
        } else if wasWaiting, presentation.tutorialStep != nil {
            presentation.wearAirPodsPrompt = false
            presentation.brightnessRecovery = .none
            show()
        } else if !presentation.demo {
            // Keep the accepted face (or last guidance) while the silhouette
            // retracts. Swapping to idle here flashes the camera during close.
            hide()
        }
    }

    private func rebuildPanel() {
        panel?.orderOut(nil); panel?.close(); panel = nil
        // A notched built-in screen wins even when an external display is main.
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let geometry = NotchGeometry(screen: screen.frame, safeTop: screen.safeAreaInsets.top,
                                     leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea)
        self.geometry = geometry
        presentation.topInset = geometry.topInset
        presentation.hardwareWidth = geometry.hardwareWidth
        let frame = geometry.panelFrame(width: 360, contentHeight: 380)
        let window = NotchPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true; window.hidesOnDeactivate = false
        window.canHide = false
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        // Above desktop coverage and face illumination, including the final
        // checkmark while Settings or another ordinary app is frontmost.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle, .canJoinAllApplications]
        window.ignoresMouseEvents = true
        window.title = "AirVeil Notch Coach"
        window.contentView = NSHostingView(rootView: NotchCoachView(presentation: presentation, camera: model.cameraHeading.camera,
                                                                  headMotion: model.cameraHeading.notchMotion)
            .frame(width: 360, height: frame.height, alignment: .top))
        window.setFrame(frame, display: false)
        panel = window
        if presentation.expanded && active { window.orderFrontRegardless() }
    }
    private func show() {
        if !presentation.wearAirPodsPrompt, presentation.brightnessRecovery == .none, presentation.tutorialStep == nil,
           !defaults.bool(forKey: Self.tutorialCompletionKey) {
            presentation.tutorialStep = .tracking
        }
        closeWork?.cancel(); closeWork = nil
        panel?.orderFrontRegardless()
        // The panel stays at one size; only the native view animates.
        presentation.expanded = true
        updateHitTesting()
    }
    private func hide(immediately: Bool = false, dismissingReminder: Bool = false) {
        // Only End tutorial records completion. Sleep hides it temporarily;
        // idle callbacks, pointer exit, and delayed closes cannot dismiss it.
        if presentation.tutorialStep != nil, !immediately, !dismissingReminder { return }
        hoverWork?.cancel(); hoverWork = nil; pointerInside = false
        closeWork?.cancel()
        presentation.expanded = false
        presentation.hovering = false
        panel?.ignoresMouseEvents = true
        if immediately {
            panel?.orderOut(nil)
            clearDismissedSnapshot()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.presentation.expanded,
                  self.presentation.tutorialStep == nil || dismissingReminder else { return }
            self.panel?.orderOut(nil)
            self.clearDismissedSnapshot()
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchOverlayPresentation.expansionDuration + 0.04, execute: work)
    }
    private func clearDismissedSnapshot() {
        guard !presentation.expanded, !presentation.demo,
              !model.wearAirPodsPrompt, model.removalPresence.lowLightRecoveryState == .none,
              model.cameraHeading.coach.phase == .idle else { return }
        presentation.wearAirPodsPrompt = false
        presentation.brightnessRecovery = .none
        presentation.snapshot = NotchCoachSnapshot()
    }
    private var visibleContentRect: CGRect? {
        guard let panel, let geometry else { return nil }
        let height = contentHeight
        return CGRect(x: panel.frame.midX - presentation.contentWidth / 2, y: panel.frame.maxY - geometry.topInset - height,
                      width: presentation.contentWidth, height: height)
    }
    private func updateHitTesting() {
        let inside = presentation.expanded && contentContains(NSEvent.mouseLocation)
        if presentation.hovering != inside { presentation.hovering = inside }
        panel?.ignoresMouseEvents = !inside
    }
    private func contentContains(_ point: CGPoint) -> Bool {
        guard let panel, let geometry, visibleContentRect?.contains(point) == true else { return false }
        let local = CGPoint(x: point.x - panel.frame.minX, y: panel.frame.maxY - point.y)
        let bounds = CGRect(x: 0, y: 0, width: panel.frame.width, height: geometry.topInset + contentHeight)
        return NotchCanopy(hardwareWidth: geometry.hardwareWidth, topInset: geometry.topInset,
                           bodyWidth: presentation.canopyWidth, bodyHeight: contentHeight).path(in: bounds).contains(local)
    }
    private func pointerMoved() { updatePointerPosition(NSEvent.mouseLocation) }
    func updatePointerPosition(_ point: CGPoint) {
        guard active, let geometry else { return }
        updateHitTesting()
        guard (!model.wearAirPodsPrompt || wearReminderDismissed),
              (model.removalPresence.lowLightRecoveryState == .none || recoveryNoticeDismissed), presentation.tutorialStep == nil,
              (model.wearAirPodsPrompt || model.removalPresence.lowLightRecoveryState != .none || model.cameraHeading.coach.phase == .idle),
              !presentation.demo else { return }
        let inside = geometry.hoverRect.contains(point) || (presentation.expanded && contentContains(point))
        guard inside != pointerInside else { return }
        pointerInside = inside
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if inside { self.showControls() } else if self.presentation.controls { self.hide() }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.22 : 0.45), execute: work)
    }

    /// Explicit visual preview. Never touches camera, AirPods, saved center or blur.
    func previewAnimation() {
        guard active, !model.wearAirPodsPrompt, model.removalPresence.lowLightRecoveryState == .none,
              !model.cameraHeading.isBusy else { return }
        demoTask?.cancel()
        presentation.controls = false; presentation.demo = true
        demoTask = Task { [weak self] in
            guard let self else { return }
            let stages: [(NotchCoachSnapshot, UInt64)] = [
                (.init(phase: .seeking, title: "Find your frame", detail: "A small camera preview lives here."), 1_200_000_000),
                (.init(phase: .offCenter, title: "Look straight ahead", detail: "13° from center. Aim within 5°.", horizontalError: -0.3, issue: .pose), 1_600_000_000),
                (.init(phase: .lighting, title: "More light needed", detail: "Face light starts off.", issue: .lowLight), 1_500_000_000),
                (.init(phase: .holding, title: "Hold at center", detail: "One quick camera and AirPods check.", progress: 0.65), 1_300_000_000),
                (.init(phase: .success, title: "Ready", detail: "", progress: 1), 1_450_000_000)
            ]
            for (snapshot, duration) in stages {
                guard !Task.isCancelled else { return }
                presentation.snapshot = snapshot; show()
                do { try await Task.sleep(nanoseconds: duration) } catch { return }
            }
            presentation.demo = false; hide()
        }
    }
    func shutdown() {
        demoTask?.cancel(); hoverWork?.cancel(); closeWork?.cancel(); recoveryCompletionWork?.cancel()
        presentation.expanded = false
        if let globalMouse { NSEvent.removeMonitor(globalMouse) }
        if let localMouse { NSEvent.removeMonitor(localMouse) }
        globalMouse = nil; localMouse = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        subscriptions.removeAll(); panel?.orderOut(nil); panel?.close(); panel = nil
        observers.removeAll()
    }
}
