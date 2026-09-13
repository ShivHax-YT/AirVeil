import AppKit
import Combine
import Foundation

// Compile with the real AppModel.swift and VeilMath.swift, without the live
// MotionService/DesktopOverlayController implementations. Local declarations
// also replace both permission entry points: this test never requests capture
// access, starts Core Motion, displays overlays, or accesses desktop frames.
// AppModel's defaults dependency is also replaced, so selection and policy
// persistence tests cannot alter the user's real preferences, even on failure.
final class UserDefaults {
    static let standard = UserDefaults()
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func double(forKey key: String) -> Double { values[key] as? Double ?? 0 }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func clear() { values.removeAll() }
}

struct VeilDisplayInfo {
    let id: UInt32
    let stableID: String
    var frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    var backingScale = 2.0
}

/// Device/persistence boundary only. The real AppModel remains responsible for
/// selecting headings, scheduling capture, recovery intent, and session gates.
@MainActor final class CameraHeadingCoordinator: ObservableObject {
    @Published var isEnabled = false
    @Published var status = "Test camera assistance off"
    @Published var isBusy = false
    @Published var hasCenter = false
    @Published var yawDegrees = 0.0
    private var alignmentValid = false
    private(set) var sessionActive = true
    var trackingValid: Bool {
        get { isEnabled && sessionActive && alignmentValid && motion.isRunning && motion.isFresh }
        set { alignmentValid = newValue && sessionActive }
    }
    private let motion: MotionService
    private(set) var enableCalls = 0
    private(set) var disableCalls = 0
    private(set) var cancelCalls = 0
    private(set) var refreshCalls = 0
    private(set) var centerCalls = 0
    private(set) var shutdownCalls = 0
    private(set) var lastLayoutKey = ""
    init(motion: MotionService) { self.motion = motion }
    func requestEnable() { enableCalls += 1; isEnabled = true }
    func disable() { disableCalls += 1; isEnabled = false; alignmentValid = false; isBusy = false }
    func refreshDirection() { refreshCalls += 1; if sessionActive && isEnabled { isBusy = true } }
    func cancelPendingRecovery() { cancelCalls += 1; isBusy = false }
    func update(layoutKey: String) { lastLayoutKey = layoutKey }
    func setSessionActive(_ active: Bool) {
        sessionActive = active
        if !active { alignmentValid = false; isBusy = false }
    }
    func setCenter(layoutKey: String) { centerCalls += 1; lastLayoutKey = layoutKey; isBusy = true }
    func shutdown() { shutdownCalls += 1; disable() }
}

enum MotionConnectionState { case unknown, connected, disconnected }
enum MotionReferenceState { case unset, established, awaitingReturn, retainedAfterGap, invalid }

@MainActor final class DisplaySleepService {
    private(set) var requests = 0
    private(set) var cancellations = 0
    var failRequest = false
    func requestDisplaySleep() async throws {
        requests += 1
        if failRequest { throw NSError(domain: "TestSleep", code: 1) }
    }
    func cancel() { cancellations += 1 }
}

@MainActor final class MotionService: ObservableObject {
    // The real AppModel consumes only the publisher notification, not its
    // payload. No Core Motion or fusion-engine dependency is needed here.
    @Published var fusionSample: Int?
    @Published var sourceName = "Test AirPod"
    @Published var sampleRate = 50.0
    @Published var isFresh = true
    @Published var isCalibrated = true
    @Published var isRunning = true
    @Published var yawDegrees = 0.0
    @Published var status = "Test motion"
    var connectionState = MotionConnectionState.connected
    var disconnectEventCount: UInt64 = 0
    var canCalibrate = true
    var referenceState = MotionReferenceState.established
    var hasSavedCenter: Bool { referenceState != .unset }
    var referenceUsable: Bool {
        isCalibrated && referenceState != .unset && referenceState != .invalid
    }
    var trackingValid: Bool { isRunning && isFresh && referenceUsable }
    private(set) var calibrateCalls = 0
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    func start() {
        guard !isRunning else { return }
        startCalls += 1; isRunning = true; connectionState = .unknown
    }
    func stop() {
        stopCalls += 1; isRunning = false; isFresh = false; isCalibrated = false
        if hasSavedCenter { referenceState = .invalid }
        connectionState = .unknown
    }
    func calibrate() {
        calibrateCalls += 1; isCalibrated = true; referenceState = .established; yawDegrees = 0
    }
}

@MainActor final class DesktopOverlayController: ObservableObject {
    @Published var isRunning = false
    @Published var isReady = false
    @Published var failureReason: String?
    @Published var availableDisplays = [VeilDisplayInfo(id: 10, stableID: "display-a"),
                                       VeilDisplayInfo(id: 20, stableID: "display-b")]
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var lastSelectedIDs: Set<UInt32>?
    private(set) var updateCalls = 0
    var suspendNextStart = false
    private var startupContinuation: CheckedContinuation<Void, Never>?
    func start(selectedDisplayIDs: Set<UInt32>?) async throws {
        startCalls += 1; lastSelectedIDs = selectedDisplayIDs; isRunning = true
        if suspendNextStart {
            suspendNextStart = false
            await withCheckedContinuation { startupContinuation = $0 }
        }
        isReady = true
    }
    func releaseStartup() { startupContinuation?.resume(); startupContinuation = nil }
    func stop() { stopCalls += 1; isRunning = false; isReady = false; failureReason = nil }
    func update(left: Double, right: Double, blurPoints: Double, feather: Double,
                opaque: Bool, shield: Bool, wholeScreen: Bool,
                blockInput: Bool, blocksEntireDisplay: Bool) { updateCalls += 1 }
}

enum VeilRenderError: Error { case unavailable(String) }

// Name resolution selects these module-local declarations over imported APIs.
func CGPreflightScreenCaptureAccess() -> Bool { false }
@MainActor enum SCShareableContent {
    struct Content { let displays = [1] }
    static var requestCalls = 0
    static func excludingDesktopWindows(_ exclude: Bool,
                                        onScreenWindowsOnly: Bool) async throws -> Content {
        requestCalls += 1
        return Content()
    }
}

@main @MainActor struct AppModelLifecycleTests {
    private static var checks = 0
    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        guard condition() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
    }

    private static func drainTasks() async {
        for _ in 0..<8 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    private static func renderFrame(_ model: AppModel) {
        // Invoke the actual @objc display-link entry point deterministically.
        // Its link argument is unused; no screen display link needs scheduling.
        _ = model.perform(NSSelectorFromString("frame:"), with: nil)
    }

    private static func makeModel() -> AppModel {
        UserDefaults.standard.clear()
        return AppModel()
    }

    private static func freshWear(_ model: AppModel) {
        model.motion.isRunning = true
        model.motion.connectionState = .connected
        model.motion.isFresh = true
        model.motion.canCalibrate = true
    }

    private static func recoveryTicks(_ model: AppModel, count: Int = 20) {
        for _ in 0..<count { model.checkReferenceRecovery() }
    }

    private static func removeAirPods(_ model: AppModel) {
        model.motion.isFresh = false
        model.motion.referenceState = .invalid
        model.motion.isCalibrated = false
        model.cameraHeading.trackingValid = false
        model.motion.connectionState = .disconnected
        model.motion.disconnectEventCount += 1
        model.checkTrackingSafety()
    }

    private static func returnLookingAway(_ model: AppModel) {
        freshWear(model)
        model.motion.referenceState = .invalid
        model.motion.isCalibrated = false
        model.motion.yawDegrees = 45
        if model.cameraHeading.isEnabled {
            model.cameraHeading.yawDegrees = 45
            model.cameraHeading.trackingValid = true
        }
    }

    private static func useCamera(_ model: AppModel, yaw: Double = 0) {
        model.cameraHeading.isEnabled = true
        model.cameraHeading.hasCenter = true
        model.cameraHeading.yawDegrees = yaw
        model.cameraHeading.trackingValid = true
    }

    static func main() async {
        // Each cancellation happens synchronously in the same main-actor turn
        // as scheduling, before the unstructured operation can enter its body.
        do {
            let model = makeModel()
            model.enable()
            check(model.starting, "Enable queued before cancellation")
            model.pause()
            await drainTasks()
            check(model.overlay.startCalls == 0, "Immediate pause prevents capture start")
            check(!model.enabled && !model.starting && !model.overlay.isRunning,
                  "Immediate pause remains clear after queued tasks drain")
            model.shutdown()
        }
        do {
            let model = makeModel()
            model.enable()
            model.shutdown()
            await drainTasks()
            check(model.overlay.startCalls == 0, "Immediate shutdown prevents capture start")
            check(!model.enabled && !model.starting && !model.overlay.isRunning && !model.motion.isRunning,
                  "Shutdown stays stopped after queued tasks drain")
        }
        do {
            let model = makeModel()
            model.enable()
            model.pause()
            model.enable()
            await drainTasks()
            check(model.overlay.startCalls == 1, "Only replacement enable reaches capture")
            check(model.enabled && model.overlay.isRunning, "Replacement enable remains usable")
            model.pause()
            check(!model.overlay.isRunning, "Pause stops an already started effect synchronously")
            model.shutdown()
        }
        do {
            let model = makeModel()
            model.enable()
            await drainTasks()
            check(model.overlay.startCalls == 1 && model.enabled,
                  "Uncancelled enable executes, proving the scheduler was drained")
            model.shutdown()
        }
        do {
            let model = makeModel()
            let before = SCShareableContent.requestCalls
            model.requestScreenPermission()
            check(model.checkingAccess, "Access check queued before cancellation")
            model.pause()
            await drainTasks()
            check(SCShareableContent.requestCalls == before, "Pause prevents queued permission request")
            check(!model.checkingAccess && !model.permissionGranted,
                  "Cancelled access check cannot publish approval")
            model.shutdown()
        }
        do {
            let model = makeModel()
            let before = SCShareableContent.requestCalls
            model.requestScreenPermission()
            model.shutdown()
            await drainTasks()
            check(SCShareableContent.requestCalls == before, "Shutdown prevents queued permission request")
        }
        do {
            let model = makeModel()
            let before = SCShareableContent.requestCalls
            model.requestScreenPermission()
            await drainTasks()
            check(SCShareableContent.requestCalls == before + 1,
                  "Uncancelled access check reaches only the fake API")
            check(model.permissionGranted && !model.checkingAccess,
                  "Uncancelled fake access result reaches the real model")
            model.shutdown()
        }
        do {
            let model = makeModel()
            model.motion.isCalibrated = false
            model.calibrate()
            model.pause()
            await drainTasks()
            check(model.motion.calibrateCalls == 0 && !model.calibrating,
                  "Pause invalidates queued calibration")
            model.shutdown()
        }
        do {
            let model = makeModel()
            model.enable()
            await drainTasks()
            model.motion.yawDegrees = 45
            renderFrame(model)
            model.motion.isFresh = false
            model.motion.isCalibrated = false
            let stops = model.overlay.stopCalls
            model.checkTrackingSafety()
            check(!model.enabled && !model.overlay.isRunning && model.strengths == .zero,
                  "Invalid motion synchronously clears the running effect")
            check(model.overlay.stopCalls == stops + 1, "Recovery clears the renderer through stop")
            model.checkTrackingSafety()
            check(model.overlay.stopCalls == stops + 1, "Repeated invalid checks do not repeat cleanup")
            model.motion.isFresh = true
            await drainTasks()
            check(!model.enabled && model.overlay.startCalls == 1,
                  "Fresh samples alone cannot resume after losing center")
            model.calibrate()
            await drainTasks()
            check(model.motion.calibrateCalls == 1 && model.enabled && model.overlay.startCalls == 2,
                  "Explicit successful recenter resumes the interrupted effect once")
            model.shutdown()
        }
        do {
            let model = makeModel()
            model.enable()
            await drainTasks()
            model.motion.isFresh = false
            model.motion.isCalibrated = false
            model.checkTrackingSafety()
            model.pause()
            model.motion.isFresh = true
            model.calibrate()
            await drainTasks()
            check(model.motion.isCalibrated && !model.enabled && model.overlay.startCalls == 1,
                  "Manual pause cancels recovery-driven re-enable after center")
            model.shutdown()
        }
        do {
            let model = makeModel()
            model.enable()
            await drainTasks()
            model.overlay.failureReason = "Synthetic capture interruption"
            model.checkTrackingSafety()
            check(!model.enabled && !model.overlay.isRunning && !model.starting,
                  "Capture failure clears effect without waiting for new input")
            check(model.message.contains("Synthetic capture interruption"),
                  "Capture failure keeps its actionable explanation after cleanup")
            model.calibrate()
            await drainTasks()
            check(model.overlay.startCalls == 1, "Capture failure does not turn recenter into implicit capture retry")
            model.shutdown()
        }
        do {
            let model = makeModel()
            model.overlay.availableDisplays = []
            model.enable()
            await drainTasks()
            check(model.overlay.startCalls == 0 && !model.starting,
                  "No available displays prevents capture startup")
            model.shutdown()
        }
        do {
            let model = makeModel()
            for display in model.overlay.availableDisplays { model.selectDisplay(display, selected: false) }
            check(model.selectedDisplayCount == 0, "Deselecting all displays is represented explicitly")
            model.enable()
            await drainTasks()
            check(model.overlay.startCalls == 0, "Empty display selection cannot start all displays accidentally")
            model.shutdown()
        }
        do {
            let model = makeModel()
            model.enable()
            await drainTasks()
            let removed = model.overlay.availableDisplays[1]
            model.selectDisplay(removed, selected: false)
            check(!model.enabled && !model.overlay.isRunning, "Changing selection pauses active capture")
            check(model.selectedDisplayIDs == Set([UInt32(10)]), "Selection resolves only chosen physical display")
            model.overlay.availableDisplays = [VeilDisplayInfo(id: 110, stableID: "display-a"),
                                               VeilDisplayInfo(id: 220, stableID: "display-b")]
            check(model.selectedDisplayIDs == Set([UInt32(110)]), "Stable identity survives changed runtime display IDs")
            model.enable()
            await drainTasks()
            check(model.overlay.lastSelectedIDs == Set([UInt32(110)]), "Only resolved selected display IDs reach capture")
            model.shutdown()
            let restored = AppModel()
            check(restored.selectedDisplayKeys == Set(["display-a"]), "Stable display selection is persisted")
            restored.shutdown()
        }
        do {
            let model = makeModel()
            model.enable()
            model.selectDisplay(model.overlay.availableDisplays[1], selected: false)
            await drainTasks()
            check(model.overlay.startCalls == 0 && !model.starting,
                  "Selection change cancels queued startup before capture")
            model.shutdown()
        }
        for action in ["selection", "reset"] {
            let model = makeModel()
            model.enable()
            await drainTasks()
            model.motion.isFresh = false
            model.motion.isCalibrated = false
            model.checkTrackingSafety()
            if action == "selection" {
                model.selectDisplay(model.overlay.availableDisplays[1], selected: false)
            } else {
                model.resetDefaults()
            }
            model.motion.isFresh = true
            model.calibrate()
            await drainTasks()
            check(model.motion.isCalibrated && !model.enabled && model.overlay.startCalls == 1,
                  "Explicit \(action) cancels pending recovery before recenter")
            model.shutdown()
        }
        do {
            let model = makeModel()
            model.overlay.suspendNextStart = true
            var publishedInvalidActivation = false
            model.stateChanged = { [weak model] in
                if let model, model.enabled && !model.motion.trackingValid { publishedInvalidActivation = true }
            }
            model.enable()
            await drainTasks()
            check(model.starting && !model.enabled && model.overlay.startCalls == 1,
                  "Fake capture suspends inside actual enable task")
            model.motion.isFresh = false
            model.motion.isCalibrated = false
            model.overlay.releaseStartup()
            await drainTasks()
            check(!model.starting && !model.enabled && !model.overlay.isRunning,
                  "Motion loss across capture await prevents enabling and clears capture")
            check(!publishedInvalidActivation, "No invalid activation is published even before the next safety frame")
            model.motion.isFresh = true
            model.calibrate()
            await drainTasks()
            check(model.enabled && model.overlay.startCalls == 2,
                  "Startup motion loss can resume only after explicit recenter")
            model.shutdown()
        }
        do {
            let model = makeModel()
            check(model.blockInput && !model.blocksEntireDisplay, "Pointer defaults block the blurred area")
            model.blockInput = false
            model.blocksEntireDisplay = true
            model.shutdown()
            let restored = AppModel()
            check(!restored.blockInput && restored.blocksEntireDisplay, "Pointer policy persists without real preferences")
            restored.shutdown()
        }
        do {
            let model = makeModel()
            let now = ProcessInfo.processInfo.systemUptime
            check(!model.sleepDisplaysOnRemoval, "Removal action starts off until chosen")
            model.sleepDisplaysOnRemoval = true
            model.checkAirPodsRemoval(now: now)
            model.motion.isFresh = false
            model.motion.isCalibrated = false
            model.checkAirPodsRemoval(now: now + 10)
            await drainTasks()
            check(model.displaySleep.requests == 0, "A stale stream or lost calibration never turns off displays")
            model.motion.connectionState = .disconnected
            model.motion.disconnectEventCount = 1
            model.checkAirPodsRemoval(now: now + 11)
            model.checkAirPodsRemoval(now: now + 12.4)
            check(model.displaySleep.requests == 0, "Actual disconnect waits for debounce")
            model.checkAirPodsRemoval(now: now + 12.6)
            await drainTasks()
            check(model.displaySleep.requests == 1 && !model.enabled, "Confirmed disconnect requests display sleep with blur paused")
            model.checkAirPodsRemoval(now: now + 100)
            await drainTasks()
            check(model.displaySleep.requests == 1, "Remaining disconnected does not repeatedly sleep displays")
            model.shutdown()
            let restored = AppModel()
            check(restored.sleepDisplaysOnRemoval, "Chosen removal behavior persists")
            restored.resetDefaults()
            check(!restored.sleepDisplaysOnRemoval, "Reset defaults disables removal action")
            restored.shutdown()
        }
        for cancellation in ["reconnect", "new-disconnect", "pause", "off", "shutdown"] {
            let model = makeModel()
            let now = ProcessInfo.processInfo.systemUptime
            model.sleepDisplaysOnRemoval = true
            model.checkAirPodsRemoval(now: now)
            model.motion.isFresh = false
            model.motion.connectionState = .disconnected
            model.motion.disconnectEventCount = 1
            model.checkAirPodsRemoval(now: now + 1)
            model.checkAirPodsRemoval(now: now + 3)
            switch cancellation {
            case "reconnect": model.motion.connectionState = .connected
            case "new-disconnect": model.motion.disconnectEventCount = 2
            case "pause": model.pause()
            case "off": model.sleepDisplaysOnRemoval = false
            default: model.shutdown()
            }
            await drainTasks()
            check(model.displaySleep.requests == 0, "\(cancellation) cancels queued display-off action before launch")
            model.shutdown()
        }
        do {
            let model = makeModel()
            let now = ProcessInfo.processInfo.systemUptime
            model.sleepDisplaysOnRemoval = true
            model.enable()
            await drainTasks()
            model.checkAirPodsRemoval(now: now)
            model.motion.isFresh = false
            model.motion.isCalibrated = false
            model.motion.connectionState = .disconnected
            model.motion.disconnectEventCount = 1
            model.checkTrackingSafety()
            check(!model.enabled, "Tracking loss clears blur promptly before removal delay")
            model.checkAirPodsRemoval(now: now + 1)
            model.checkAirPodsRemoval(now: now + 3)
            await drainTasks()
            check(model.displaySleep.requests == 1, "Automatic blur recovery does not cancel the chosen removal action")
            model.shutdown()
        }
        do {
            let model = makeModel()
            model.motion.referenceState = .unset
            model.motion.isCalibrated = false
            recoveryTicks(model, count: 100)
            model.enable()
            await drainTasks()
            check(model.motion.calibrateCalls == 0 && !model.motion.hasSavedCenter,
                  "Initial fresh still pose never silently establishes zero")
            check(!model.enabled && model.overlay.startCalls == 0, "Initial launch waits for explicit Set center")
            model.calibrate()
            await drainTasks()
            check(model.motion.calibrateCalls == 1 && model.motion.referenceUsable, "Explicit Set center establishes the initial reference")
            check(!model.enabled, "Initial Set center alone keeps cold capture paused")
            model.enable()
            await drainTasks()
            check(model.enabled, "Initial reference permits the user's explicit Enable")
            model.shutdown()
        }
        for cancellation in ["none", "pause", "selection", "reset"] {
            let model = makeModel()
            model.onset = 12; model.fullAngle = 44; model.inverted = true
            model.wholeScreen = true; model.blurPoints = 48
            model.enable()
            await drainTasks()
            removeAirPods(model)
            check(!model.enabled && !model.overlay.isRunning && !model.motion.isCalibrated,
                  "\(cancellation): removal clears capture and invalidates unverified legacy calibration")
            switch cancellation {
            case "pause": model.pause()
            case "selection": model.selectDisplay(model.overlay.availableDisplays[1], selected: false)
            case "reset": model.resetDefaults()
            default: break
            }
            returnLookingAway(model)
            recoveryTicks(model, count: 100)
            await drainTasks()
            let resumes = cancellation == "none"
            check(!model.enabled && model.overlay.startCalls == 1,
                  "\(cancellation): fresh legacy return cannot reuse disproven sensor reference")
            check(model.motion.calibrateCalls == 0 && model.motion.yawDegrees == 45,
                  "\(cancellation): returning or holding a 45-degree turn never changes original zero")
            model.calibrate()
            await drainTasks()
            check(model.enabled == resumes && model.overlay.startCalls == (resumes ? 2 : 1),
                  "\(cancellation): explicit legacy Set center recovery respects cancellation")
            if resumes {
                check(model.onset == 12 && model.fullAngle == 44 && model.inverted && model.wholeScreen && model.blurPoints == 48,
                      "Retained-reference resume preserves blur configuration")
            }
            model.shutdown()
        }
        do {
            let model = makeModel()
            removeAirPods(model)
            returnLookingAway(model)
            recoveryTicks(model)
            await drainTasks()
            check(!model.enabled && model.overlay.startCalls == 0 && model.motion.calibrateCalls == 0,
                  "Fresh saved-reference return does not enable previously paused capture")
            model.shutdown()
        }
        do {
            let model = makeModel()
            model.enable()
            await drainTasks()
            model.motion.referenceState = .invalid
            model.motion.isCalibrated = false
            recoveryTicks(model, count: 100)
            await drainTasks()
            check(!model.enabled && model.motion.hasSavedCenter && model.motion.calibrateCalls == 0,
                  "Fresh but invalid sensor reference stays paused without overwriting saved zero")
            check(model.overlay.startCalls == 1, "Invalid reference cannot automatically restart capture")
            model.calibrate()
            await drainTasks()
            check(model.motion.calibrateCalls == 1 && model.enabled && model.overlay.startCalls == 2,
                  "Explicit Set center can replace an invalid reference and restore prior capture intent")
            model.shutdown()
        }
        do {
            let model = makeModel()
            model.enable()
            await drainTasks()
            model.handleWorkspaceEvent(NSWorkspace.willSleepNotification)
            model.handleWorkspaceEvent(NSWorkspace.screensDidSleepNotification)
            model.handleWorkspaceEvent(NSWorkspace.sessionDidResignActiveNotification)
            check(model.motion.isRunning && model.motion.stopCalls == 0 && model.motion.hasSavedCenter,
                  "System, display, and session suspension preserve the running sensor and original center")
            model.handleWorkspaceEvent(NSWorkspace.screensDidWakeNotification)
            returnLookingAway(model)
            recoveryTicks(model)
            model.enable()
            await drainTasks()
            check(!model.enabled && model.overlay.startCalls == 1, "Display wake alone cannot resume capture in inactive system/session")
            model.handleWorkspaceEvent(NSWorkspace.didWakeNotification)
            recoveryTicks(model)
            await drainTasks()
            check(!model.enabled && model.overlay.startCalls == 1, "System wake still waits for active login session")
            model.handleWorkspaceEvent(NSWorkspace.sessionDidBecomeActiveNotification)
            recoveryTicks(model)
            await drainTasks()
            check(!model.enabled && model.overlay.startCalls == 1 && model.motion.calibrateCalls == 0,
                  "Legacy wake waits for explicit center after unobserved sensor gap")
            model.calibrate()
            await drainTasks()
            check(model.enabled && model.overlay.startCalls == 2 && model.motion.calibrateCalls == 1,
                  "Explicit center after fully active wake resumes prior legacy effect")
            check(model.motion.startCalls == 0 && model.motion.stopCalls == 0, "Wake never restarts an already running reference stream")
            model.shutdown()
            model.handleWorkspaceEvent(NSWorkspace.sessionDidBecomeActiveNotification)
            model.startMotionAutomatically()
            check(!model.motion.isRunning && model.motion.stopCalls == 1 && model.motion.startCalls == 0,
                  "Quit stops the sensor and later workspace events cannot restart it")
        }
        for phase in ["before-task", "during-capture-await"] {
            let model = makeModel()
            useCamera(model)
            model.enable()
            await drainTasks()
            removeAirPods(model)
            returnLookingAway(model)
            if phase == "during-capture-await" { model.overlay.suspendNextStart = true }
            recoveryTicks(model)
            if phase == "during-capture-await" {
                await drainTasks()
                check(model.starting && model.overlay.startCalls == 2, "Recovery capture is held inside its asynchronous startup")
            }
            model.handleWorkspaceEvent(NSWorkspace.sessionDidResignActiveNotification)
            if phase == "during-capture-await" { model.overlay.releaseStartup() }
            await drainTasks()
            check(!model.enabled && !model.starting && !model.overlay.isRunning,
                  "\(phase): inactive session cancels pending recovery activation")
            check(model.overlay.startCalls == (phase == "before-task" ? 1 : 2),
                  "\(phase): superseded capture cannot restart after cancellation")
            model.handleWorkspaceEvent(NSWorkspace.sessionDidBecomeActiveNotification)
            returnLookingAway(model)
            recoveryTicks(model)
            await drainTasks()
            check(model.enabled && model.motion.calibrateCalls == 0 && model.effectiveYaw == 45,
                  "\(phase): later active session resumes with unchanged reference")
            model.shutdown()
        }
        do {
            let model = makeModel()
            let now = ProcessInfo.processInfo.systemUptime
            model.sleepDisplaysOnRemoval = true
            useCamera(model)
            model.enable()
            await drainTasks()
            model.checkAirPodsRemoval(now: now)
            removeAirPods(model)
            model.checkAirPodsRemoval(now: now + 1)
            model.checkAirPodsRemoval(now: now + 3)
            await drainTasks()
            check(model.displaySleep.requests == 1, "Removal sleep remains a one-shot action with retained center")
            model.handleWorkspaceEvent(NSWorkspace.screensDidSleepNotification)
            model.handleWorkspaceEvent(NSWorkspace.sessionDidResignActiveNotification)
            returnLookingAway(model)
            model.checkAirPodsRemoval(now: now + 4)
            model.motion.connectionState = .disconnected
            model.motion.disconnectEventCount += 1
            model.motion.isFresh = false
            model.checkAirPodsRemoval(now: now + 5)
            model.checkAirPodsRemoval(now: now + 8)
            await drainTasks()
            check(model.displaySleep.requests == 1, "Keepalive motion cannot arm or repeat display sleep while Mac is inactive")
            model.handleWorkspaceEvent(NSWorkspace.screensDidWakeNotification)
            returnLookingAway(model)
            recoveryTicks(model)
            await drainTasks()
            check(!model.enabled, "Screen wake cannot resume effect while login session is inactive")
            model.handleWorkspaceEvent(NSWorkspace.sessionDidBecomeActiveNotification)
            returnLookingAway(model)
            recoveryTicks(model)
            model.checkAirPodsRemoval(now: now + 10)
            await drainTasks()
            check(model.enabled && model.motion.calibrateCalls == 0 && model.motion.yawDegrees == 45,
                  "Return after removal sleep resumes original reference without recalibration")
            check(model.displaySleep.requests == 1, "Return does not replay the earlier disconnect action")
            model.shutdown()
        }
        do {
            let model = makeModel()
            model.calibrate()
            model.handleWorkspaceEvent(NSWorkspace.screensDidSleepNotification)
            await drainTasks()
            check(model.motion.calibrateCalls == 0, "Sleep cancels queued explicit calibration before it changes center")
            model.shutdown()
        }
        do {
            let model = makeModel()
            model.enable()
            await drainTasks()
            removeAirPods(model)
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            await drainTasks()
            returnLookingAway(model)
            recoveryTicks(model)
            await drainTasks()
            check(model.motion.isRunning && model.motion.stopCalls == 0 && model.motion.calibrateCalls == 0,
                  "Display topology notification preserves sensor stream and original reference")
            check(!model.enabled && model.overlay.startCalls == 1 && model.motion.yawDegrees == 45,
                  "Display topology change cancels prior capture intent without changing zero")
            model.shutdown()
        }
        do {
            let model = makeModel()
            model.motion.referenceState = .invalid
            model.motion.isCalibrated = false
            model.motion.yawDegrees = -70
            useCamera(model, yaw: 28)
            model.cameraHeading.status = "Camera measured returning direction"
            check(model.trackingValid && model.effectiveYaw == 28,
                  "Camera mode selects fused heading without legacy manual calibration")
            check(model.hasSavedCenter && model.headTrackingStatus == model.cameraHeading.status,
                  "Camera center and status replace legacy diagnostics in the product state")
            model.inverted = true
            check(model.effectiveYaw == -28, "User inversion applies exactly once to fused heading")
            model.inverted = false
            model.enable()
            await drainTasks()
            check(model.enabled && model.overlay.startCalls == 1 && model.motion.calibrateCalls == 0,
                  "Valid fusion enables capture without overwriting the AirPods manual center")
            model.cameraHeading.trackingValid = false
            model.motion.referenceState = .established
            model.motion.isCalibrated = true
            model.checkTrackingSafety()
            check(!model.enabled && !model.overlay.isRunning,
                  "Invalid camera fusion cannot fall back silently to valid legacy yaw")
            model.motion.referenceState = .invalid
            model.motion.isCalibrated = false
            model.cameraHeading.yawDegrees = 35
            model.cameraHeading.trackingValid = true
            recoveryTicks(model)
            await drainTasks()
            check(model.enabled && model.overlay.startCalls == 2 && model.effectiveYaw == 35,
                  "New camera alignment resumes interrupted capture at actual off-axis angle")
            check(model.motion.calibrateCalls == 0, "Camera recovery never invokes manual zero calibration")
            model.shutdown()
            check(model.cameraHeading.shutdownCalls == 1, "Shutdown reaches the camera boundary")
        }
        do {
            let model = makeModel()
            useCamera(model)
            model.enable()
            await drainTasks()
            removeAirPods(model)
            model.refreshCameraDirection()
            check(model.cameraHeading.isBusy, "Camera recovery attempt is pending at its boundary")
            let cancellations = model.cameraHeading.cancelCalls
            model.pause()
            check(!model.cameraHeading.isBusy && model.cameraHeading.cancelCalls == cancellations+1,
                  "Manual Pause cancels pending camera recovery synchronously")
            returnLookingAway(model)
            recoveryTicks(model)
            await drainTasks()
            check(!model.enabled && model.overlay.startCalls == 1,
                  "Late camera alignment cannot restore capture after manual Pause")
            model.shutdown()
        }
        do {
            let model = makeModel()
            model.enableCameraAssistance()
            check(model.cameraHeading.enableCalls == 1 && model.cameraHeading.isEnabled && !model.enabled,
                  "Explicit camera enable pauses effect and delegates opt-in once")
            model.motion.referenceState = .invalid
            model.motion.isCalibrated = false
            model.calibrate()
            await drainTasks()
            check(model.cameraHeading.centerCalls == 1 && model.motion.calibrateCalls == 0,
                  "Set center in camera mode routes geometric setup without manual motion calibration")
            check(model.centerBusy && !model.simulate && !model.calibrating,
                  "Camera setup busy state reaches UI without starting legacy calibration loop")
            let layout = model.cameraHeading.lastLayoutKey
            check(layout.contains("display-a") && layout.contains("display-b"),
                  "Camera setup receives stable display geometry signature")
            var displays = model.overlay.availableDisplays
            displays[0].frame.origin.x = 100
            displays[0].backingScale = 1
            model.overlay.availableDisplays = displays
            recoveryTicks(model)
            check(model.cameraHeading.lastLayoutKey != layout,
                  "Display position or backing scale changes reach camera geometry validation")
            model.disableCameraAssistance()
            check(!model.cameraHeading.isEnabled && model.cameraHeading.disableCalls == 1 && !model.enabled,
                  "Explicit camera disable cancels capture and disables its boundary")
            model.shutdown()
        }
        do {
            let model = makeModel()
            useCamera(model, yaw: 30)
            model.enable()
            await drainTasks()
            model.refreshCameraDirection()
            model.handleWorkspaceEvent(NSWorkspace.screensDidSleepNotification)
            check(!model.cameraHeading.sessionActive && !model.cameraHeading.isBusy && !model.enabled,
                  "Display sleep suspends camera work and clears the active effect")
            let centers = model.cameraHeading.centerCalls
            model.calibrate()
            model.refreshCameraDirection()
            recoveryTicks(model)
            await drainTasks()
            check(model.cameraHeading.centerCalls == centers && !model.cameraHeading.isBusy,
                  "Inactive session blocks camera setup and camera work at the boundary")
            check(model.overlay.startCalls == 1, "Inactive session cannot restart capture")
            model.handleWorkspaceEvent(NSWorkspace.screensDidWakeNotification)
            recoveryTicks(model)
            await drainTasks()
            check(model.cameraHeading.sessionActive && !model.enabled,
                  "Wake alone cannot reuse a canceled camera alignment")
            returnLookingAway(model)
            recoveryTicks(model)
            await drainTasks()
            check(model.enabled && model.effectiveYaw == 45 && model.motion.calibrateCalls == 0,
                  "Fresh camera alignment after wake resumes original intent without choosing zero")
            model.shutdown()
        }
        do {
            let model = makeModel()
            model.simulate = false
            model.motion.yawDegrees = 21.01
            model.motion.sampleRate = 50.0
            model.checkReferenceRecovery()
            model.checkAirPodsRemoval()
            model.setPreviewVisible(true)
            await drainTasks()
            var fullModelChanges = 0
            var presentationChanges = 0
            let fullSubscription = model.objectWillChange.sink { fullModelChanges += 1 }
            let smallSubscription = model.presentation.objectWillChange.sink { presentationChanges += 1 }
            for i in 0..<100 {
                model.motion.yawDegrees = 21.01+Double(i)*0.001
                model.motion.sampleRate = 50.0+Double(i)*0.001
                model.motion.fusionSample = i
                model.setPreviewVisible(true)
            }
            await drainTasks()
            check(fullModelChanges == 0,
                  "Constant rounded high-frequency motion telemetry never invalidates full AppModel")
            check(presentationChanges == 0 && model.presentation.snapshot.angle == 21 && model.presentation.snapshot.sampleRate == 50,
                  "Small presentation ignores yaw and sample-rate changes inside displayed rounding buckets")
            model.motion.yawDegrees = 21.7
            model.setPreviewVisible(true)
            check(presentationChanges == 1 && model.presentation.snapshot.angle == 22,
                  "Crossing displayed angle rounding boundary publishes exactly one small snapshot")
            model.motion.sampleRate = 52.6
            model.setPreviewVisible(true)
            check(presentationChanges == 2 && model.presentation.snapshot.sampleRate == 55,
                  "Crossing displayed rate bucket publishes exactly one small snapshot")
            model.motion.status = "New test tracking state"
            model.setPreviewVisible(true)
            check(presentationChanges == 3 && model.presentation.snapshot.status == "New test tracking state",
                  "Meaningful tracking status change still reaches presentation")
            check(fullModelChanges == 0, "Visible telemetry changes remain isolated from full settings publication")
            fullSubscription.cancel(); smallSubscription.cancel()
            model.shutdown()
        }
        do {
            let model = makeModel()
            model.checkReferenceRecovery()
            model.checkAirPodsRemoval()
            model.previewYaw = 30
            model.setPreviewVisible(true)
            await drainTasks()
            var fullModelChanges = 0
            var previewDraws = 0
            var visibilityEvents: [Bool] = []
            model.previewFrame = { _ in previewDraws += 1 }
            model.previewVisibility = { visibilityEvents.append($0) }
            let subscription = model.objectWillChange.sink { fullModelChanges += 1 }
            for _ in 0..<100 { renderFrame(model) }
            check(model.strengths.right > 0 && previewDraws > 0,
                  "Actual animation entry point updates strengths and visible preview")
            check(fullModelChanges == 0, "High-frequency strength animation does not publish full AppModel changes")
            model.setPreviewVisible(false)
            let previousSnapshot = model.presentation.snapshot
            previewDraws = 0
            for i in 0..<100 {
                model.motion.yawDegrees = Double(i)
                model.motion.fusionSample = i
                renderFrame(model)
            }
            await drainTasks()
            check(previewDraws == 0, "Invisible paused preview receives no animation or telemetry draw callbacks")
            check(model.presentation.snapshot == previousSnapshot,
                  "Invisible preview does not refresh its presentation snapshot")
            model.pause()
            check(previewDraws == 0, "Pause does not render a hidden preview")
            model.setPreviewVisible(true)
            renderFrame(model)
            check(previewDraws > 0 && visibilityEvents == [false, true],
                  "Showing preview explicitly resumes rendering and visibility callbacks")
            subscription.cancel()
            model.shutdown()
        }
        do {
            let model = makeModel()
            var previewDraws = 0
            model.previewFrame = { _ in previewDraws += 1 }
            model.setPreviewVisible(false)
            model.enable()
            await drainTasks()
            model.motion.yawDegrees = 30
            for _ in 0..<20 { renderFrame(model) }
            check(model.enabled && model.overlay.updateCalls > 0 && model.strengths.right > 0,
                  "Hiding settings preserves active desktop effect animation")
            check(previewDraws == 0, "Active desktop animation never draws the invisible settings preview")
            model.shutdown()
        }
        for (inactive, active) in [
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification)
        ] {
            let model = makeModel()
            model.simulate = false
            model.motion.yawDegrees = 21
            model.setPreviewVisible(true)
            model.handleWorkspaceEvent(inactive)
            // The one clear callback during suspension is intentional. No
            // subsequent motion/frame/presentation work may redraw the preview.
            let snapshot = model.presentation.snapshot
            var previewDraws = 0
            model.previewFrame = { _ in previewDraws += 1 }
            var snapshotChanges = 0
            let token = model.presentation.objectWillChange.sink { snapshotChanges += 1 }
            for i in 0..<20 {
                model.motion.yawDegrees = 37
                model.motion.fusionSample = i
                model.setPreviewVisible(true)
                renderFrame(model)
            }
            await drainTasks()
            check(previewDraws == 0 && model.strengths.left == 0 && model.strengths.right == 0,
                  "\(inactive.rawValue): inactive session rejects preview animation even when window remains marked visible")
            check(snapshotChanges == 0 && model.presentation.snapshot == snapshot,
                  "\(inactive.rawValue): inactive session does not publish telemetry presentation")
            check(model.overlay.updateCalls == 0 && !model.enabled,
                  "\(inactive.rawValue): keepalive motion cannot render desktop capture")
            model.handleWorkspaceEvent(active)
            renderFrame(model)
            check(model.presentation.snapshot.angle == 37 && previewDraws > 0,
                  "\(active.rawValue): returning session explicitly refreshes latest telemetry and preview")
            token.cancel(); model.shutdown()
        }
        do {
            let model = makeModel()
            model.simulate = false
            model.motion.isCalibrated = false
            model.motion.referenceState = .invalid
            model.cameraHeading.isEnabled = true
            model.cameraHeading.hasCenter = true
            model.cameraHeading.trackingValid = true
            model.cameraHeading.yawDegrees = 25
            model.setPreviewVisible(true)
            check(!model.motion.trackingValid && model.presentation.snapshot.trackingValid,
                  "Small enable-button snapshot exposes valid camera fusion despite invalid legacy calibration")
            check(model.presentation.snapshot.angle == 25 && model.presentation.snapshot.hasSavedCenter,
                  "Fused snapshot uses restored camera direction and saved center")
            model.enable(); await drainTasks()
            check(model.enabled && model.overlay.startCalls == 1,
                  "Valid fused snapshot and actual Enable action agree when legacy center is invalid")
            model.pause()
            model.cameraHeading.trackingValid = false
            model.setPreviewVisible(true)
            check(!model.presentation.snapshot.trackingValid,
                  "Losing camera alignment disables the observed snapshot without requiring legacy motion publication")
            model.cameraHeading.isBusy = true
            model.setPreviewVisible(true)
            check(!model.presentation.snapshot.canSetCenter && model.presentation.snapshot.centerBusy,
                  "Observed tracking controls reflect busy camera recovery")
            model.shutdown()
        }
        print("PASS: \(checks) real AppModel lifecycle assertions; camera, motion, capture, display sleep, permissions, and preferences stubbed")
    }
}
