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
    private var contentHeight: CGFloat = 232

    init(model: AppModel) {
        self.model = model
        presentation.center = { [weak self] in self?.setCenter() }
        presentation.refresh = { [weak self] in self?.retry() }
        presentation.cancel = { [weak self] in self?.cancel() }
        presentation.settings = { [weak self] in self?.model.showWindow?() }
        presentation.toggleEffect = { [weak self] in
            guard let self else { return }
            if model.enabled || model.starting { model.pause() } else { model.enable() }
            updateControls()
        }
        presentation.contentHeightChanged = { [weak self] height in
            guard height.isFinite, height > 0 else { return }
            self?.contentHeight = height
            self?.updateHitTesting()
        }
        model.cameraHeading.$coach.receive(on: DispatchQueue.main).sink { [weak self] state in
            self?.receive(state)
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
                MainActor.assumeIsolated { self?.active = true }
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
        presentation.enabled = model.enabled
    }
    func showControls() {
        guard active else { return }
        if model.cameraHeading.coach.phase != .idle { receive(model.cameraHeading.coach); return }
        updateControls(); presentation.demo = false; presentation.controls = true
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
    private func cancel() {
        if presentation.demo { demoTask?.cancel(); presentation.demo = false; hide(); return }
        model.pause()
        hide()
    }
    private func receive(_ snapshot: NotchCoachSnapshot) {
        guard active else { return }
        if snapshot.phase != .idle {
            demoTask?.cancel(); presentation.demo = false
            presentation.controls = false; presentation.snapshot = snapshot
            show()
        } else if !presentation.demo {
            presentation.snapshot = snapshot
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
        let frame = geometry.panelFrame(width: 360, contentHeight: 260)
        let window = NotchPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true; window.hidesOnDeactivate = false
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.level = .statusBar
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
        closeWork?.cancel(); closeWork = nil
        panel?.orderFrontRegardless()
        // The panel stays at one size; only the native view animates.
        presentation.expanded = true
        updateHitTesting()
    }
    private func hide(immediately: Bool = false) {
        hoverWork?.cancel(); hoverWork = nil; pointerInside = false
        closeWork?.cancel()
        presentation.expanded = false
        panel?.ignoresMouseEvents = true
        if immediately { panel?.orderOut(nil); return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.presentation.expanded else { return }
            self.panel?.orderOut(nil)
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34, execute: work)
    }
    private var visibleContentRect: CGRect? {
        guard let panel, let geometry else { return nil }
        let height = contentHeight
        return CGRect(x: panel.frame.minX, y: panel.frame.maxY - geometry.topInset - height,
                      width: panel.frame.width, height: height)
    }
    private func updateHitTesting() {
        panel?.ignoresMouseEvents = !presentation.expanded || !contentContains(NSEvent.mouseLocation)
    }
    private func contentContains(_ point: CGPoint) -> Bool {
        guard let panel, let geometry, visibleContentRect?.contains(point) == true else { return false }
        let local = CGPoint(x: point.x - panel.frame.minX, y: panel.frame.maxY - point.y)
        let bounds = CGRect(x: 0, y: 0, width: panel.frame.width, height: geometry.topInset + contentHeight)
        return NotchCanopy(hardwareWidth: geometry.hardwareWidth, topInset: geometry.topInset).path(in: bounds).contains(local)
    }
    private func pointerMoved() {
        guard active, let geometry else { return }
        updateHitTesting()
        guard model.cameraHeading.coach.phase == .idle, !presentation.demo else { return }
        let point = NSEvent.mouseLocation
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
        guard active, !model.cameraHeading.isBusy else { return }
        demoTask?.cancel()
        presentation.controls = false; presentation.demo = true
        demoTask = Task { [weak self] in
            guard let self else { return }
            let stages: [(NotchCoachSnapshot, UInt64)] = [
                (.init(phase: .seeking, title: "Find your frame", detail: "A small camera preview lives here."), 1_200_000_000),
                (.init(phase: .offCenter, title: "Look straight ahead", detail: "13° from center. Aim within 5°.", horizontalError: -0.3, issue: .pose), 1_600_000_000),
                (.init(phase: .seeking, title: "More light needed", detail: "Light your face from the front.", issue: .lowLight), 1_500_000_000),
                (.init(phase: .holding, title: "Hold at center", detail: "One quick camera and AirPods check.", progress: 0.65), 1_300_000_000),
                (.init(phase: .success, title: "Ready", detail: "", progress: 1), 1_100_000_000)
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
        demoTask?.cancel(); hoverWork?.cancel(); closeWork?.cancel()
        if let globalMouse { NSEvent.removeMonitor(globalMouse) }
        if let localMouse { NSEvent.removeMonitor(localMouse) }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        subscriptions.removeAll(); panel?.orderOut(nil); panel?.close(); panel = nil
    }
}
