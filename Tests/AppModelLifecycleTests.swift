import AppKit
import Combine
import Foundation

// Compile with the real AppModel.swift and VeilMath.swift, without the live
// MotionService/DesktopOverlayController implementations. Local declarations
// also replace both permission entry points: this test never requests capture
// access, starts Core Motion, displays overlays, or accesses desktop frames.
// AppModel's defaults dependency is also replaced, so selection and policy
// persistence tests cannot alter the user's real preferences, even on failure.
// RemovalPresenceCoordinator/PresenceTracker remain real. Only their physical
// camera, brightness, idle assertion, and screen sleep boundaries are replaced.
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

@MainActor final class TestHeadingCamera {
    var holdStop = false
    private(set) var stopWaits = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func waitUntilStopped() async {
        stopWaits += 1
        if holdStop { await withCheckedContinuation { continuation = $0 } }
    }
    func releaseStop() { holdStop = false; continuation?.resume(); continuation = nil }
}

@MainActor final class PresenceService: ObservableObject {
    @Published var state = PresenceState.unknown
    @Published var status = "Injected presence"
    private(set) var startReferences: [PresenceSeatReference] = []
    private(set) var stopCalls = 0
    private(set) var isRunning = false
    var holdStop = false
    private var continuation: CheckedContinuation<Void, Never>?
    func start(reference: PresenceSeatReference) async throws {
        startReferences.append(reference); isRunning = true; state = .unknown
    }
    func stop() async {
        stopCalls += 1
        if holdStop { await withCheckedContinuation { continuation = $0 } }
        isRunning = false
    }
    func releaseStop() { holdStop = false; continuation?.resume(); continuation = nil }
    func refresh() {}
}

@MainActor final class DisplayDimmingService: ObservableObject {
    @Published var isDimmed = false
    @Published var isBusy = false
    @Published var hasPendingRestore = false
    var awaitingWakeStability = false
    @Published var status = "Injected brightness"
    private(set) var isSuspended = false
    private(set) var dimTargets: [Double] = []
    private(set) var restoreCalls = 0
    private(set) var suspendCalls = 0
    private(set) var brightnessWrites = 0
    private(set) var keepsDisplayAwake = false
    var holdRestore = false
    var failRestore = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func setDimmed(_ dimmed: Bool, targetBrightness: Double = 0,
                   keepDisplayAwake: Bool = true) async -> Bool {
        if !dimmed { return await restore() }
        guard !isSuspended else { return false }
        dimTargets.append(targetBrightness); brightnessWrites += 1
        isDimmed = true; hasPendingRestore = true; keepsDisplayAwake = keepDisplayAwake
        return true
    }
    func restore() async -> Bool {
        restoreCalls += 1; isSuspended = false; keepsDisplayAwake = false
        isBusy = true
        if holdRestore { await withCheckedContinuation { continuations.append($0) } }
        isBusy = false
        guard !isSuspended, !failRestore else { return false }
        if hasPendingRestore { brightnessWrites += 1 }
        hasPendingRestore = false; isDimmed = false; awaitingWakeStability = false
        return true
    }
    func releaseRestore() {
        holdRestore = false
        let waiting = continuations; continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
    func recoverIfNeeded() async -> Bool { await restore() }
    func suspendUntilActive() async -> Bool {
        suspendCalls += 1; isSuspended = true; keepsDisplayAwake = false
        return true
    }
}

/// Device/persistence boundary only. The real AppModel remains responsible for
/// selecting headings, scheduling capture, recovery intent, and session gates.
@MainActor final class CameraHeadingCoordinator: ObservableObject {
    let camera = TestHeadingCamera()
    var onAcceptedFace: ((String, String, CGRect, Double) -> Void)?
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
    func resumeTracking() { refreshCalls += 1; if sessionActive && isEnabled && !trackingValid { isBusy = true } }
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
    var removalStateOverride: MotionConnectionState?
    var removalCountOverride: UInt64?
    var removalConnectionState: MotionConnectionState { removalStateOverride ?? connectionState }
    var removalEventCount: UInt64 { removalCountOverride ?? disconnectEventCount }
    var wearStatus = "Injected wear state"
    func clearRemovalEvidence() { removalStateOverride = nil; removalCountOverride = nil }
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

// System power observation and persistence are exercised separately with the
// real EnergyController. Here only its delivery boundary is injected.
@MainActor final class EnergyController {
    var targetFramesPerSecond = 60
    var onChange: ((Int) -> Void)?
    private(set) var stopped = false
    func request(_ fps: Int) { targetFramesPerSecond = fps; onChange?(fps) }
    func refresh() {}
    func reset() { request(60) }
    func shutdown() { stopped = true }
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
    private(set) var requestedCaptureFPS = 60
    private(set) var cadenceRequests = 0
    func setCaptureFramesPerSecond(_ fps: Int) { requestedCaptureFPS = fps; cadenceRequests += 1 }
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
        let model = AppModel()
        model.motionAccessAllowedByOnboarding = true
        return model
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

    private static func acceptSeat(_ model: AppModel, now: Double) {
        model.cameraHeading.onAcceptedFace?("builtin-camera", "640x480-upright",
            CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.25), now)
    }

    /// Use real removal debounce and coordinator policy, injecting only the
    /// accepted face geometry and the physical acquisition results.
    private static func beginPresence(_ model: AppModel, now: Double,
                                      rememberSeat: Bool = true,
                                      dim: Bool = true, lock: Bool = true) async {
        model.sleepDisplaysOnRemoval = lock
        model.dimWhilePresent = dim
        useCamera(model)
        if rememberSeat { acceptSeat(model, now: now) }
        model.checkAirPodsRemoval(now: now)
        removeAirPods(model)
        model.checkAirPodsRemoval(now: now + 1)
        model.checkAirPodsRemoval(now: now + 3)
        await drainTasks()
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
            check(model.sleepDisplaysOnRemoval && !model.dimWhilePresent,
                  "Locking defaults on and dimming requires an explicit opt-in")
            useCamera(model)
            acceptSeat(model, now: now)
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
            check(model.displaySleep.requests == 0 && model.presence.isRunning,
                  "Confirmed disconnect starts the seat camera before any display-sleep action")
            model.presence.state = .absent
            model.checkAirPodsRemoval(now: now + 12.7)
            await drainTasks()
            check(model.displaySleep.requests == 1 && !model.enabled, "Confirmed empty seat requests display sleep with blur paused")
            model.checkAirPodsRemoval(now: now + 100)
            await drainTasks()
            check(model.displaySleep.requests == 1, "Remaining disconnected does not repeatedly sleep displays")
            model.shutdown()
            let restored = AppModel()
            check(restored.sleepDisplaysOnRemoval, "Chosen removal behavior persists")
            restored.resetDefaults()
            check(restored.sleepDisplaysOnRemoval && !restored.dimWhilePresent,
                  "Reset defaults restores independent locking-on and dimming-off preferences")
            restored.shutdown()
        }
        for cancellation in ["reconnect", "new-disconnect", "pause", "off", "shutdown"] {
            let model = makeModel()
            let now = ProcessInfo.processInfo.systemUptime
            await beginPresence(model, now: now, dim: false)
            model.presence.state = .absent
            model.checkAirPodsRemoval(now: now + 3.1)
            switch cancellation {
            case "reconnect": freshWear(model)
            case "new-disconnect": model.motion.disconnectEventCount += 1
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
            useCamera(model)
            acceptSeat(model, now: now)
            model.enable()
            await drainTasks()
            model.checkAirPodsRemoval(now: now)
            removeAirPods(model)
            check(!model.enabled, "Tracking loss clears blur promptly before removal delay")
            model.checkAirPodsRemoval(now: now + 1)
            model.checkAirPodsRemoval(now: now + 3)
            await drainTasks()
            model.presence.state = .absent
            model.checkAirPodsRemoval(now: now + 3.1)
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
            await drainTasks()
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
            acceptSeat(model, now: now)
            model.enable()
            await drainTasks()
            model.checkAirPodsRemoval(now: now)
            removeAirPods(model)
            model.checkAirPodsRemoval(now: now + 1)
            model.checkAirPodsRemoval(now: now + 3)
            await drainTasks()
            model.presence.state = .absent
            model.checkAirPodsRemoval(now: now + 3.1)
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
            await drainTasks()
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
            await drainTasks()
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
        do {
            let model = makeModel()
            check(!model.dimWhilePresent && model.removalBrightness == 0 && model.sleepDisplaysOnRemoval,
                  "The saved dim target defaults to zero while dimming starts off and locking starts on")
            check(!model.presenceReady && model.presence.startReferences.isEmpty && model.dimming.brightnessWrites == 0,
                  "Cold initialization neither invents a seat nor starts presence or brightness")
            model.dimWhilePresent = true; model.sleepDisplaysOnRemoval = false; model.removalBrightness = 0.12
            let restored = AppModel()
            check(restored.dimWhilePresent && !restored.sleepDisplaysOnRemoval && restored.removalBrightness == 0.12,
                  "Independent removal preferences and chosen brightness persist")
            restored.resetDefaults()
            check(!restored.dimWhilePresent && restored.removalBrightness == 0 && restored.sleepDisplaysOnRemoval,
                  "Reset restores locking on, dimming off, and the zero target")
            model.shutdown(); restored.shutdown()
        }
        for priorLock in [false, true] {
            UserDefaults.standard.clear()
            UserDefaults.standard.set(priorLock, forKey: "sleepDisplaysOnRemoval")
            UserDefaults.standard.set(true, forKey: "dimWhilePresent")
            UserDefaults.standard.set(0.23, forKey: "removalBrightnessV2")
            let model = AppModel()
            check(model.sleepDisplaysOnRemoval == priorLock && !model.dimWhilePresent && model.removalBrightness == 0.23,
                  "Legacy lock choices survive migration; an old implicit dim default does not opt in")
            model.sleepDisplaysOnRemoval = !priorLock
            model.dimWhilePresent = true
            let restored = AppModel()
            check(restored.sleepDisplaysOnRemoval == !priorLock && restored.dimWhilePresent,
                  "New independent removal preferences take precedence over stale legacy keys")
            model.shutdown(); restored.shutdown()
        }
        for dim in [false, true] {
            for lock in [false, true] {
                let model = makeModel()
                let now = ProcessInfo.processInfo.systemUptime
                await beginPresence(model, now: now, dim: dim, lock: lock)
                check(model.presence.isRunning == (dim || lock),
                      "dim=\(dim), lock=\(lock): removal starts a seat check only when a feature is on")
                model.presence.state = .present
                model.checkAirPodsRemoval(now: now + 3.2); await drainTasks()
                check(model.dimming.isDimmed == dim,
                      "dim=\(dim), lock=\(lock): occupied seat obeys only the dim toggle")
                check(model.displaySleep.requests == 0,
                      "dim=\(dim), lock=\(lock): an occupied seat never requests display sleep")
                if dim || lock {
                    check(model.presence.isRunning,
                          "A lock-only check continues watching an occupied seat without dimming")
                }
                model.presence.state = .absent
                model.checkAirPodsRemoval(now: now + 4); await drainTasks()
                check(model.displaySleep.requests == (lock ? 1 : 0),
                      "dim=\(dim), lock=\(lock): confirmed departure obeys only the lock toggle")
                if !lock {
                    freshWear(model); model.checkAirPodsRemoval(now: now + 5); await drainTasks()
                    check(!model.dimming.isDimmed && !model.presence.isRunning,
                          "Returning AirPods ends a dim-only episode and restores brightness")
                }
                model.shutdown()
            }
        }
        do {
            let model = makeModel()
            let now = ProcessInfo.processInfo.systemUptime
            await beginPresence(model, now: now)
            model.presence.state = .present; model.checkAirPodsRemoval(now: now + 3.2); await drainTasks()
            let starts = model.presence.startReferences.count
            let stops = model.presence.stopCalls
            model.dimWhilePresent = false; await drainTasks()
            check(!model.dimming.isDimmed && !model.dimming.hasPendingRestore,
                  "Turning dimming off during removal restores the owned brightness")
            check(model.presence.isRunning && model.presence.startReferences.count == starts && model.presence.stopCalls == stops,
                  "Turning dimming off keeps the existing lock camera monitoring without a restart")
            model.presence.state = .absent; model.checkAirPodsRemoval(now: now + 4); await drainTasks()
            check(model.displaySleep.requests == 1,
                  "Locking still responds to a departure after dimming is switched off")
            model.shutdown()
        }
        do {
            let model = makeModel()
            let now = ProcessInfo.processInfo.systemUptime
            await beginPresence(model, now: now, dim: false)
            model.presence.state = .present; model.checkAirPodsRemoval(now: now + 3.2); await drainTasks()
            let starts = model.presence.startReferences.count
            model.dimWhilePresent = true
            model.checkAirPodsRemoval(now: now + 3.3); await drainTasks()
            check(model.dimming.isDimmed && model.presence.startReferences.count == starts,
                  "Dimming can be enabled during an existing occupied-seat check without another wear cycle")
            model.sleepDisplaysOnRemoval = false
            model.presence.state = .absent; model.checkAirPodsRemoval(now: now + 4); await drainTasks()
            check(model.displaySleep.requests == 0 && model.presence.isRunning,
                  "Turning locking off keeps the dim-only episode running without requesting sleep")
            model.dimWhilePresent = false; await drainTasks()
            check(!model.presence.isRunning && !model.dimming.isDimmed && !model.dimming.hasPendingRestore,
                  "Turning both removal options off stops the camera and restores owned brightness")
            model.shutdown()
        }
        do {
            let model = makeModel()
            let now = ProcessInfo.processInfo.systemUptime
            await beginPresence(model, now: now)
            model.presence.state = .present; model.checkAirPodsRemoval(now: now + 3.2); await drainTasks()
            model.presence.state = .absent; model.checkAirPodsRemoval(now: now + 4)
            model.sleepDisplaysOnRemoval = false
            await drainTasks()
            check(model.displaySleep.requests == 0 && model.removalPresence.isActive && model.presence.isRunning,
                  "Lock-off cancels a queued departure action while the dim-only seat check resumes safely")
            model.shutdown()
        }
        do {
            let model = makeModel()
            let now = ProcessInfo.processInfo.systemUptime
            model.dimWhilePresent = true
            model.checkAirPodsRemoval(now: now)
            removeAirPods(model)
            model.checkAirPodsRemoval(now: now + 1); model.checkAirPodsRemoval(now: now + 3)
            await drainTasks()
            check(model.presence.startReferences.isEmpty && model.displaySleep.requests == 0 && !model.dimming.isDimmed,
                  "Camera assistance being off cannot bypass the seat check and lock or dim on disconnection")
            check(model.removalStatus.contains("camera assistance"),
                  "Unavailable removal checks explain that camera assistance and a center are required")
            model.cancelWearWait()
            model.sleepDisplaysOnRemoval = false; model.sleepDisplaysOnRemoval = true
            model.dimWhilePresent = false; model.dimWhilePresent = true
            freshWear(model); model.checkAirPodsRemoval(now: now + 4)
            removeAirPods(model); model.checkAirPodsRemoval(now: now + 5); model.checkAirPodsRemoval(now: now + 8)
            await drainTasks()
            check(model.automaticFeaturesPaused && model.displaySleep.requests == 0 && !model.presence.isRunning,
                  "Changing independent removal preferences does not override the global feature-off action")
            model.shutdown()
        }
        for (stored, expected) in [(-0.1, 0.0), (0.01, 0.01), (0.99, 0.5), (Double.nan, 0.0)] {
            UserDefaults.standard.clear()
            UserDefaults.standard.set(stored, forKey: "removalBrightnessV2")
            let model = AppModel()
            check(model.removalBrightness == expected, "Saved brightness is finite and clamped to the supported control range")
            model.shutdown()
        }
        do {
            let model = makeModel()
            let now = ProcessInfo.processInfo.systemUptime
            useCamera(model)
            check(!model.presenceReady, "Camera tracking availability alone does not create foreground geometry")
            acceptSeat(model, now: now)
            check(model.presenceReady, "Only accepted camera-check geometry makes the foreground seat ready")
            var displays = model.overlay.availableDisplays
            displays[0].frame.origin.x += 20
            model.overlay.availableDisplays = displays
            check(!model.presenceReady, "Changed display geometry prevents reusing the previous seat layout")
            acceptSeat(model, now: now)
            check(model.presenceReady, "A new accepted check anchors the updated layout")
            model.disableCameraAssistance()
            check(!model.presenceReady, "Disabling camera assistance discards the in-memory seat reference")
            model.shutdown()
        }
        do {
            let model = makeModel()
            let now = ProcessInfo.processInfo.systemUptime
            model.cameraHeading.camera.holdStop = true
            await beginPresence(model, now: now)
            check(model.cameraHeading.camera.stopWaits == 1 && !model.cameraHeading.sessionActive,
                  "Removal disables heading and awaits actual camera-stop completion")
            check(model.presence.startReferences.isEmpty && !model.removalPresence.canResumeHeading,
                  "Presence capture cannot begin before heading capture has fully stopped")
            model.cameraHeading.camera.releaseStop()
            await drainTasks()
            check(model.presence.startReferences.count == 1 && model.presence.isRunning,
                  "Presence capture starts once after the heading-stop barrier")
            let seat = model.presence.startReferences[0]
            check(seat.cameraID == "builtin-camera" && seat.configurationID == "640x480-upright" && seat.captureHostTime == now,
                  "Accepted camera identity, framing, and capture timestamp reach the presence provider")
            let centerCalls = model.cameraHeading.centerCalls, refreshCalls = model.cameraHeading.refreshCalls
            freshWear(model)
            model.calibrate(); model.refreshCameraDirection(); model.enable(); model.checkReferenceRecovery()
            check(model.cameraHeading.centerCalls == centerCalls && model.cameraHeading.refreshCalls == refreshCalls,
                  "Presence ownership blocks explicit and automatic heading checks")
            check(!model.enabled && !model.starting && model.overlay.startCalls == 0,
                  "Presence ownership blocks desktop capture even when AirPods data becomes fresh")
            model.presence.state = .present
            model.motion.connectionState = .disconnected
            model.checkAirPodsRemoval(now: now + 3.2)
            await drainTasks()
            check(model.dimming.dimTargets == [0] && model.dimming.keepsDisplayAwake,
                  "Confirmed seated presence requests the chosen real-brightness boundary and idle assertion")
            check(model.displaySleep.requests == 0, "Seated presence does not request display sleep")
            model.removalBrightness = 0.1
            await drainTasks()
            check(model.dimming.dimTargets == [0, 0.1], "Slider changes reach the active dim episode")
            model.dimWhilePresent = false
            await drainTasks()
            check(model.presence.isRunning && !model.dimming.hasPendingRestore && !model.dimming.keepsDisplayAwake,
                  "Turning dimming off restores brightness and releases the assertion while locking keeps watching")
            model.sleepDisplaysOnRemoval = false
            await drainTasks()
            check(model.removalPresence.canResumeHeading && model.displaySleep.requests == 0,
                  "Disabling both options cancels the consumed event without an unexpected sleep request")
            model.shutdown()
        }
        do {
            let model = makeModel()
            let now = ProcessInfo.processInfo.systemUptime
            useCamera(model); model.enable(); await drainTasks()
            await beginPresence(model, now: now)
            model.presence.state = .present; model.checkAirPodsRemoval(now: now + 3.2)
            await drainTasks()
            model.presence.holdStop = true; model.dimming.holdRestore = true
            freshWear(model); model.checkAirPodsRemoval(now: now + 4)
            await drainTasks()
            check(!model.removalPresence.canResumeHeading && !model.cameraHeading.sessionActive,
                  "Rewear keeps heading blocked while camera release and brightness restoration are pending")
            model.enable(); model.calibrate(); recoveryTicks(model)
            check(model.overlay.startCalls == 1 && model.cameraHeading.centerCalls == 0 && model.motion.calibrateCalls == 0,
                  "Fresh rewear cannot restart capture or choose a center through incomplete cleanup")
            model.dimming.releaseRestore(); await drainTasks()
            check(!model.removalPresence.canResumeHeading && !model.cameraHeading.sessionActive,
                  "Brightness restoration alone cannot bypass the presence-camera stop barrier")
            model.presence.releaseStop(); await drainTasks()
            check(model.removalPresence.canResumeHeading && model.cameraHeading.sessionActive && !model.dimming.hasPendingRestore,
                  "Both completed barriers permit heading recovery after rewear")
            returnLookingAway(model); recoveryTicks(model); await drainTasks()
            check(model.enabled && model.overlay.startCalls == 2 && model.effectiveYaw == 45 && model.motion.calibrateCalls == 0,
                  "Post-removal camera alignment restores prior capture at the actual heading without recentering")
            model.shutdown()
        }
        do {
            let model = makeModel()
            let now = ProcessInfo.processInfo.systemUptime
            await beginPresence(model, now: now)
            model.presence.state = .present; model.checkAirPodsRemoval(now: now + 3.2); await drainTasks()
            model.dimming.failRestore = true
            freshWear(model); model.checkAirPodsRemoval(now: now + 4); await drainTasks()
            check(!model.removalPresence.canResumeHeading && model.dimming.hasPendingRestore && !model.cameraHeading.sessionActive,
                  "Failed rewear restoration retains ownership and blocks heading instead of claiming completion")
            model.dimming.failRestore = false
            let attempts = model.dimming.restoreCalls
            model.checkAirPodsRemoval(now: now + 4.2); await drainTasks()
            check(model.dimming.restoreCalls == attempts && !model.removalPresence.canResumeHeading,
                  "Failed rewear restoration observes a bounded retry delay instead of hammering the driver")
            model.checkAirPodsRemoval(now: now + 6.1); await drainTasks()
            check(model.removalPresence.canResumeHeading && !model.dimming.hasPendingRestore,
                  "A later rewear tick retries failed restoration successfully")
            model.shutdown()
        }
        for inactivity in ["screen", "system", "session", "lock"] {
            let model = makeModel()
            let now = ProcessInfo.processInfo.systemUptime
            await beginPresence(model, now: now)
            model.presence.state = .present; model.checkAirPodsRemoval(now: now + 3.2); await drainTasks()
            let writes = model.dimming.brightnessWrites, restoreCalls = model.dimming.restoreCalls
            switch inactivity {
            case "screen": model.handleWorkspaceEvent(NSWorkspace.screensDidSleepNotification)
            case "system": model.handleWorkspaceEvent(NSWorkspace.willSleepNotification)
            case "session": model.handleWorkspaceEvent(NSWorkspace.sessionDidResignActiveNotification)
            default: model.handleScreenLock(true)
            }
            await drainTasks()
            check(model.dimming.isSuspended && !model.dimming.keepsDisplayAwake && model.dimming.hasPendingRestore,
                  "\(inactivity): inactive session releases idle protection and retains pending brightness restoration")
            model.removalBrightness = 0.2; model.refreshCameraDirection(); model.calibrate(); model.enable()
            model.checkAirPodsRemoval(now: now + 5); recoveryTicks(model); await drainTasks()
            check(model.dimming.brightnessWrites == writes && model.dimming.restoreCalls == restoreCalls,
                  "\(inactivity): no brightness write or active restoration starts while inactive")
            check(!model.presence.isRunning && !model.cameraHeading.sessionActive && model.displaySleep.requests == 0,
                  "\(inactivity): presence, heading, and removal action remain stopped")
            switch inactivity {
            case "screen": model.handleWorkspaceEvent(NSWorkspace.screensDidWakeNotification)
            case "system": model.handleWorkspaceEvent(NSWorkspace.didWakeNotification)
            case "session": model.handleWorkspaceEvent(NSWorkspace.sessionDidBecomeActiveNotification)
            default: model.handleScreenLock(false)
            }
            await drainTasks()
            check(!model.dimming.hasPendingRestore && model.presence.startReferences.count == 2,
                  "\(inactivity): active recovery restores owned brightness then resumes the same removal episode")
            model.presence.state = .absent
            model.checkAirPodsRemoval(now: now + 6); await drainTasks()
            check(model.displaySleep.requests == 0,
                  "\(inactivity): manual wake cannot immediately replay removal sleep before fresh seated presence")
            model.shutdown()
        }
        do {
            let model = makeModel()
            let now = ProcessInfo.processInfo.systemUptime
            await beginPresence(model, now: now)
            model.handleScreenLock(true); await drainTasks()
            model.sessionLockState = { true }
            model.handleWorkspaceEvent(NSWorkspace.screensDidWakeNotification); await drainTasks()
            check(model.dimming.isSuspended && !model.cameraHeading.sessionActive && model.presence.startReferences.count == 1,
                  "Display wake while independently locked cannot resume camera or brightness")
            model.sessionLockState = { false }
            freshWear(model)
            model.handleScreenLock(false); await drainTasks()
            check(model.presence.startReferences.count == 1 && model.removalPresence.canResumeHeading,
                  "AirPods rewear during lock restores normally without replaying the suspended removal event")
            model.shutdown()
        }
        do {
            let model = makeModel()
            let now = ProcessInfo.processInfo.systemUptime
            await beginPresence(model, now: now)
            model.handleScreenLock(true); await drainTasks()
            model.motion.disconnectEventCount += 1
            model.handleScreenLock(false); await drainTasks()
            check(model.presence.startReferences.count == 1 && model.displaySleep.requests == 0,
                  "A different disconnect epoch cannot inherit the previously suspended removal action")
            model.shutdown()
        }
        for asleep in [false, true] {
            let model = makeModel()
            let now = ProcessInfo.processInfo.systemUptime
            await beginPresence(model, now: now)
            model.presence.state = .present; model.checkAirPodsRemoval(now: now + 3.2); await drainTasks()
            if asleep { model.handleWorkspaceEvent(NSWorkspace.screensDidSleepNotification); await drainTasks() }
            let writes = model.dimming.brightnessWrites
            await model.prepareForTermination(); await drainTasks()
            check(!model.presence.isRunning && !model.dimming.keepsDisplayAwake,
                  "Termination stops presence and releases idle protection")
            check(asleep ? model.dimming.hasPendingRestore && model.dimming.brightnessWrites == writes
                  : !model.dimming.hasPendingRestore && model.dimming.brightnessWrites == writes + 1,
                  "Termination restores only while active and leaves sleeping brightness recovery pending")
            model.shutdown()
        }
        for failureOrigin in ["startup", "cancellation"] {
            let model = makeModel()
            let now = ProcessInfo.processInfo.systemUptime
            if failureOrigin == "cancellation" {
                await beginPresence(model, now: now)
                model.presence.state = .present; model.checkAirPodsRemoval(now: now + 3.2); await drainTasks()
            } else { model.dimming.hasPendingRestore = true }
            model.dimming.failRestore = true
            if failureOrigin == "startup" { model.prepareAfterLaunch() }
            else { model.dimWhilePresent = false }
            await drainTasks()
            check(model.removalPresence.phase == .failed && !model.removalPresence.canResumeHeading,
                  "\(failureOrigin): failed cleanup does not advertise a ready heading camera")
            // Model the brightness worker's late completion after a reported
            // timeout. Physical ownership may settle without a new wear event.
            model.dimming.isBusy = true
            let attempts = model.dimming.restoreCalls
            model.checkAirPodsRemoval(now: now + 5); await drainTasks()
            check(model.dimming.restoreCalls == attempts,
                  "\(failureOrigin): recovery waits for the previous physical driver operation")
            model.dimming.isBusy = false; model.dimming.failRestore = false
            model.dimming.hasPendingRestore = false; model.dimming.isDimmed = false
            model.checkAirPodsRemoval(now: now + 7); await drainTasks()
            check(model.removalPresence.canResumeHeading && model.dimming.restoreCalls == attempts + 1,
                  "\(failureOrigin): normal ticks reconcile late settled ownership without requiring another rewear or workspace event")
            check(model.displaySleep.requests == 0, "\(failureOrigin): cleanup retry cannot invent a removal sleep")
            model.shutdown()
        }
        for freshRewear in [true, false] {
            let model = makeModel()
            let now = ProcessInfo.processInfo.systemUptime
            await beginPresence(model, now: now)
            model.presence.state = .present; model.checkAirPodsRemoval(now: now + 3.2); await drainTasks()
            model.presence.holdStop = true; model.dimming.holdRestore = true
            freshWear(model); model.motion.isFresh = freshRewear
            model.checkAirPodsRemoval(now: now + 4); await drainTasks()
            removeAirPods(model)
            model.checkAirPodsRemoval(now: now + 4.2); await drainTasks()
            check(model.presence.startReferences.count == 1 && model.displaySleep.requests == 0,
                  "A new disconnect while old cleanup is held cannot open a competing camera or sleep early")
            model.dimming.releaseRestore(); model.presence.releaseStop(); await drainTasks()
            let afterCleanup = ProcessInfo.processInfo.systemUptime
            model.checkAirPodsRemoval(now: afterCleanup); await drainTasks()
            check(model.presence.startReferences.count == 1,
                  "Rapid re-removal still observes its independent disconnect debounce")
            model.checkAirPodsRemoval(now: afterCleanup + 2); await drainTasks()
            check(model.presence.startReferences.count == (freshRewear ? 2 : 1),
                  "Only a genuinely fresh intervening rewear arms a new removal episode after old cleanup")
            check(model.displaySleep.requests == 0, "Rapid episode handoff waits for new presence instead of replaying old sleep")
            await model.prepareForTermination(); model.shutdown()
        }
        for inactiveDuringQuit in ["lock", "sleep"] {
            let model = makeModel()
            let now = ProcessInfo.processInfo.systemUptime
            await beginPresence(model, now: now)
            model.presence.state = .present; model.checkAirPodsRemoval(now: now + 3.2); await drainTasks()
            model.dimming.holdRestore = true
            let quitting = Task { await model.prepareForTermination() }
            await drainTasks()
            let writes = model.dimming.brightnessWrites
            if inactiveDuringQuit == "lock" { model.handleScreenLock(true) }
            else { model.handleWorkspaceEvent(NSWorkspace.screensDidSleepNotification) }
            await drainTasks()
            check(model.dimming.isSuspended && !model.dimming.keepsDisplayAwake,
                  "\(inactiveDuringQuit) during asynchronous quit supersedes brightness restoration and releases idle protection")
            model.dimming.releaseRestore(); await quitting.value; await drainTasks()
            check(model.dimming.hasPendingRestore && model.dimming.brightnessWrites == writes,
                  "\(inactiveDuringQuit) during quit prevents a delayed restore from writing while inactive")
            check(!model.presence.isRunning && !model.cameraHeading.sessionActive,
                  "An inactive quitting app cannot reopen presence or heading acquisition")
            model.shutdown()
        }
        do {
            UserDefaults.standard.clear()
            UserDefaults.standard.set(13.0, forKey: "onset")
            let model = AppModel()
            check(model.leftOnset == 13 && model.rightOnset == 13, "Legacy shared onset migrates to both sides")
            model.leftOnset = 18; model.rightOnset = 6
            check(model.onsetForTurn(12) == 18 && model.onsetForTurn(-12) == 6, "Positive left and negative right choose independent onset")
            let restored = AppModel()
            check(restored.leftOnset == 18 && restored.rightOnset == 6, "Independent onset values persist")
            model.leftOnset = 60
            check(model.fullAngle > 60 && model.minimumFullAngle == 61, "Later starting angle keeps a usable blur transition")
            model.resetDefaults()
            check(model.leftOnset == 8 && model.rightOnset == 8, "Reset restores both onset sides")
            model.shutdown(); restored.shutdown()
        }
        do {
            let model = makeModel()
            model.cameraHeading.isEnabled = true; model.cameraHeading.hasCenter = true
            model.cameraHeading.trackingValid = false
            check(model.canRequestEnable, "Enable can request recovery against a saved camera center")
            let centers = model.cameraHeading.centerCalls
            model.enable(); await drainTasks()
            check(model.cameraHeading.refreshCalls == 1 && model.cameraHeading.centerCalls == centers,
                  "Enable retries saved direction instead of requiring a new center")
            check(model.overlay.startCalls == 0, "Recovery never enables capture before verified heading")
            model.cameraHeading.isBusy = false; model.cameraHeading.trackingValid = true
            model.checkReferenceRecovery(); await drainTasks()
            check(model.enabled, "An explicit Enable intent resumes after camera recovery")
            model.shutdown()
        }
        do {
            let model = makeModel()
            useCamera(model); acceptSeat(model, now: ProcessInfo.processInfo.systemUptime)
            model.enable(); await drainTasks()
            check(model.enabled && model.presenceReady, "Display notification regression starts with valid active tracking")
            model.handleDisplayConfigurationChange(); await drainTasks()
            check(model.enabled && model.presenceReady, "Unchanged display inventory cannot pause or erase seat reference")
            model.overlay.availableDisplays[0].frame.size.width += 100
            model.handleDisplayConfigurationChange(); await drainTasks()
            check(!model.enabled && !model.presenceReady, "An actual geometry change pauses and invalidates the old seat")
            model.shutdown()
        }
        do {
            let model = makeModel()
            model.motion.stop()
            model.startupTourActive = true
            model.startMotionAutomatically()
            model.checkReferenceRecovery()
            check(!model.motion.isRunning, "Startup tutorial defers sensor startup")
            model.startTrackingFromTour()
            check(model.motion.isRunning && !model.startupTourActive,
                  "Explicit tutorial Start head tracking permits sensor setup before completing the tour")
            model.shutdown()
            model.startupTourActive = true
            model.startTrackingFromTour()
            check(!model.motion.isRunning && model.startupTourActive,
                  "Tutorial Start head tracking cannot restart a shutting-down app")
        }
        do {
            let model = makeModel()
            useCamera(model); acceptSeat(model, now: ProcessInfo.processInfo.systemUptime)
            model.enable(); await drainTasks()
            let starts = model.overlay.startCalls, stops = model.overlay.stopCalls
            let savedSeat = model.presenceReady
            let cameraStatus = model.cameraHeading.status
            let left = model.leftOnset, right = model.rightOnset, smoothing = model.response
            model.energy.request(30)
            await drainTasks()
            check(model.overlay.requestedCaptureFPS == 30, "Energy selection reaches desktop capture")
            check(model.enabled && model.overlay.startCalls == starts && model.overlay.stopCalls == stops,
                  "Energy selection cannot restart or pause capture")
            check(model.presenceReady == savedSeat && model.cameraHeading.status == cameraStatus,
                  "Energy selection leaves camera and seat state alone")
            check(model.leftOnset == left && model.rightOnset == right && model.response == smoothing,
                  "Energy selection cannot alter turn thresholds or smoothing")
            model.energy.request(60)
            check(model.overlay.requestedCaptureFPS == 60, "Smoothest returns requested desktop cadence")
            model.energy.request(30); model.resetDefaults()
            check(model.overlay.requestedCaptureFPS == 60 && !model.enabled, "Reset restores energy default and remains paused")
            model.shutdown()
            let requests = model.overlay.cadenceRequests
            model.energy.request(30)
            check(model.energy.stopped && model.overlay.cadenceRequests == requests,
                  "Shutdown prevents late energy delivery reaching capture")
        }
        for result in [PresenceState.present, .absent, .unknown] {
            let model = makeModel()
            let now = ProcessInfo.processInfo.systemUptime
            await beginPresence(model, now: now)
            check(model.presence.isRunning, "Both-out motion episode opens the configured seat camera")
            model.presence.state = result
            model.checkAirPodsRemoval(now: now + 3.2)
            if result == .unknown { model.checkAirPodsRemoval(now: now + 12) }
            await drainTasks()
            check(model.dimming.isDimmed == (result == .present),
                  "Seated removal dims to the saved target; unknown or absent observations never fabricate seated presence")
            check(model.displaySleep.requests == (result == .absent ? 1 : 0),
                  "Only confirmed absence requests display sleep; camera uncertainty restores safely")
            if result == .present {
                check(model.dimming.dimTargets == [0], "The default seated-removal target is exactly zero brightness")
                freshWear(model)
                model.checkAirPodsRemoval(now: now + 4); await drainTasks()
                check(!model.dimming.isDimmed && !model.presence.isRunning && model.cameraHeading.sessionActive,
                      "Fresh returned headphone motion restores brightness and stops presence before direction recovery")
            }
            model.shutdown()
        }
        do {
            let model = makeModel()
            let now = ProcessInfo.processInfo.systemUptime
            model.removalBrightness = 0.15
            await beginPresence(model, now: now)
            model.presence.state = .present
            model.checkAirPodsRemoval(now: now + 3.2); await drainTasks()
            check(model.dimming.isDimmed && model.dimming.dimTargets == [0.15],
                  "Confirmed seated removal uses the user's saved brightness target")
            model.presence.state = .unknown
            model.checkAirPodsRemoval(now: now + 4)
            model.checkAirPodsRemoval(now: now + 11.9); await drainTasks()
            check(model.dimming.isDimmed && model.displaySleep.requests == 0,
                  "Brief darkness preserves the dim target while camera assistance has time to recover")
            model.checkAirPodsRemoval(now: now + 12.1); await drainTasks()
            check(!model.dimming.isDimmed && !model.presence.isRunning && model.displaySleep.requests == 0,
                  "Sustained uncertain presence restores brightness and stops the camera without locking")
            model.shutdown()
        }
        do {
            let model = makeModel()
            let now = ProcessInfo.processInfo.systemUptime
            await beginPresence(model, now: now, rememberSeat: false)
            check(model.presence.startReferences.isEmpty && model.displaySleep.requests == 0,
                  "A both-out proxy without a seat reference cannot fall through to sleep")
            model.shutdown()
        }
        do {
            let model = makeModel()
            model.motion.stop(); model.motionAccessAllowedByOnboarding = false
            var permissionShows = 0
            model.showPermissionSetup = { permissionShows += 1 }
            model.startMotionAutomatically(); model.startTrackingFromTour()
            check(!model.motion.isRunning && permissionShows == 1,
                  "Skipping Head Tracking prevents automatic or tutorial sensor permission prompts and offers Permissions instead")
            model.motionAccessAllowedByOnboarding = true; model.permissionSetupActive = true
            model.startTrackingFromTour(); model.startMotionAutomatically()
            model.enableCameraAssistance(); model.refreshCameraDirection(); model.calibrate()
            model.requestScreenPermission(); model.enable(); model.checkReferenceRecovery()
            check(!model.motion.isRunning && !model.canRequestEnable && model.cameraHeading.enableCalls == 0 &&
                  model.cameraHeading.centerCalls == 0 && model.cameraHeading.refreshCalls == 0 && model.overlay.startCalls == 0,
                  "Active Permissions cards gate feature entry points until setup has finished")
            model.permissionSetupActive = false; model.startTrackingFromTour()
            check(model.motion.isRunning, "Finishing Permissions permits the user's explicit tracking start")
            model.shutdown()
        }
        do {
            let model = makeModel()
            removeAirPods(model)
            check(model.canRequestEnable, "Enable remains available with no AirPods motion")
            model.enable()
            check(model.wearAirPodsPrompt && model.overlay.startCalls == 0,
                  "No-motion Enable presents the wear request without desktop capture")
            check(model.cameraHeading.enableCalls == 0 && model.cameraHeading.centerCalls == 0,
                  "The wear wait never starts a camera before fresh AirPods motion")
            freshWear(model)
            model.checkReferenceRecovery(); model.checkReferenceRecovery()
            check(!model.wearAirPodsPrompt && model.cameraHeading.enableCalls == 1 && model.cameraHeading.centerCalls == 1,
                  "Returning AirPods hand the waiting panel to a real camera-centering request")
            check(model.overlay.startCalls == 0, "A requested camera check is not yet valid alignment")
            model.cameraHeading.isBusy = false; model.cameraHeading.trackingValid = true
            model.checkReferenceRecovery(); await drainTasks()
            check(model.enabled && model.overlay.startCalls == 1,
                  "Accepted alignment fulfills the original Enable intent automatically once")
            recoveryTicks(model); await drainTasks()
            check(model.overlay.startCalls == 1, "Subsequent updates do not duplicate the automatic start")
            model.shutdown()
        }
        for action in ["Set center", "Refresh direction"] {
            let model = makeModel()
            useCamera(model)
            model.cancelWearWait(); await drainTasks()
            freshWear(model)
            let centers = model.cameraHeading.centerCalls
            let refreshes = model.cameraHeading.refreshCalls
            model.handleScreenLock(true); await drainTasks()
            if action == "Set center" { model.calibrate() } else { model.refreshCameraDirection() }
            check(model.automaticFeaturesPaused && !model.cameraHeading.sessionActive &&
                  model.cameraHeading.centerCalls == centers && model.cameraHeading.refreshCalls == refreshes,
                  "\(action) cannot rearm the explicitly paused feature while locked")
            model.handleScreenLock(false); await drainTasks()
            freshWear(model); recoveryTicks(model)
            check(model.automaticFeaturesPaused && !model.cameraHeading.sessionActive,
                  "Passive unlock and motion preserve the feature-off choice before \(action)")
            if action == "Set center" { model.calibrate() } else { model.refreshCameraDirection() }
            check(!model.automaticFeaturesPaused && model.cameraHeading.sessionActive && model.cameraHeading.isBusy,
                  "Explicit \(action) rearms camera alignment after Turn off feature")
            check(model.cameraHeading.centerCalls == centers + (action == "Set center" ? 1 : 0) &&
                  model.cameraHeading.refreshCalls == refreshes + (action == "Refresh direction" ? 1 : 0) &&
                  model.overlay.startCalls == 0,
                  "\(action) starts one requested camera action without enabling desktop capture")
            model.shutdown()
        }
        for cancellation in ["waiting", "aligning"] {
            let model = makeModel()
            removeAirPods(model); model.enable()
            if cancellation == "aligning" {
                freshWear(model); model.checkReferenceRecovery(); model.checkReferenceRecovery()
                check(model.cameraHeading.isBusy, "Cancellation fixture reaches alignment")
            }
            model.cancelWearWait(); await drainTasks()
            let centerCalls = model.cameraHeading.centerCalls
            freshWear(model); recoveryTicks(model); model.checkAirPodsRemoval(); await drainTasks()
            check(model.automaticFeaturesPaused && !model.wearAirPodsPrompt && !model.cameraHeading.sessionActive,
                  "\(cancellation): Turn off feature keeps cameras and the wear prompt off")
            check(!model.enabled && model.overlay.startCalls == 0 && model.cameraHeading.centerCalls == centerCalls,
                  "\(cancellation): late motion cannot fulfill canceled Enable intent")
            let relaunched = AppModel()
            check(relaunched.automaticFeaturesPaused, "The explicit feature-off choice survives relaunch")
            relaunched.shutdown()
            model.motion.isFresh = false
            model.enable()
            check(!model.automaticFeaturesPaused && model.wearAirPodsPrompt,
                  "Only a later explicit Enable rearms the waiting workflow")
            model.shutdown()
        }
        do {
            let model = makeModel()
            let now = ProcessInfo.processInfo.systemUptime
            await beginPresence(model, now: now)
            model.presence.state = .present
            model.checkAirPodsRemoval(now: now + 3.2); await drainTasks()
            check(model.wearAirPodsPrompt && model.dimming.hasPendingRestore && model.presence.isRunning,
                  "Seated dimming keeps a visible AirPods reminder while presence is monitored")
            model.cancelWearWait(); await drainTasks()
            check(!model.dimming.hasPendingRestore && !model.presence.isRunning && !model.cameraHeading.sessionActive,
                  "Turning the waiting feature off restores brightness and stops both camera owners")
            freshWear(model); model.checkAirPodsRemoval(now: now + 4)
            removeAirPods(model); model.checkAirPodsRemoval(now: now + 5); model.checkAirPodsRemoval(now: now + 8)
            await drainTasks()
            check(model.presence.startReferences.count == 1 && model.displaySleep.requests == 0,
                  "Another removal cannot rearm the explicitly paused feature")
            model.shutdown()
        }
        do {
            let model = makeModel()
            useCamera(model)
            model.inverted = true
            let left = model.leftOnset, right = model.rightOnset
            model.startHeadPreviewSync()
            check(model.headPreviewSync.snapshot.requested && model.cameraHeading.centerCalls == 1,
                  "Sync head explicitly starts camera alignment with fresh AirPods")
            check(model.overlay.startCalls == 0, "Head sync alone does not enable desktop capture")
            model.cameraHeading.isBusy = false; model.cameraHeading.trackingValid = true
            for yaw in [-27.0, 22.0] {
                model.cameraHeading.yawDegrees = yaw; model.checkReferenceRecovery()
                check(model.headPreviewSync.snapshot.yaw == yaw,
                      "Live head illustration follows the actual signed head pose before blur inversion")
            }
            check(model.leftOnset == left && model.rightOnset == right,
                  "Head sync never changes either threshold control")
            model.handleScreenLock(true); await drainTasks()
            check(model.headPreviewSync.snapshot.yaw == nil,
                  "Head illustration drops stale pose immediately at lock")
            model.handleScreenLock(false); await drainTasks()
            model.stopHeadPreviewSync()
            model.cameraHeading.yawDegrees = 40; recoveryTicks(model)
            check(!model.headPreviewSync.snapshot.requested && model.headPreviewSync.snapshot.yaw == nil,
                  "Stopped or hidden head sync cannot keep updating the illustration")
            model.shutdown()
        }
        do {
            let model = makeModel()
            let now = ProcessInfo.processInfo.systemUptime
            await beginPresence(model, now: now)
            model.presence.state = .present; model.checkAirPodsRemoval(now: now + 3.2); await drainTasks()
            model.dimming.failRestore = true
            model.cancelWearWait(); await drainTasks()
            check(model.dimming.hasPendingRestore && model.automaticFeaturesPaused,
                  "Feature-off retains brightness ownership when the first restore fails")
            freshWear(model)
            let centers = model.cameraHeading.centerCalls, refreshes = model.cameraHeading.refreshCalls
            model.calibrate(); model.refreshCameraDirection()
            check(model.automaticFeaturesPaused && !model.cameraHeading.sessionActive &&
                  model.cameraHeading.centerCalls == centers && model.cameraHeading.refreshCalls == refreshes,
                  "Explicit camera actions cannot bypass pending brightness restoration")
            model.dimming.failRestore = false
            model.checkAirPodsRemoval(now: now + 6); await drainTasks()
            check(!model.dimming.hasPendingRestore && model.automaticFeaturesPaused && !model.cameraHeading.sessionActive,
                  "Restoration retries while the automatic feature stays explicitly off")
            check(!model.presence.isRunning && model.overlay.startCalls == 0,
                  "A brightness-only retry never starts presence or blur")
            model.shutdown()
        }
        do {
            let model = makeModel()
            let now = ProcessInfo.processInfo.systemUptime
            model.cancelWearWait(); await drainTasks()
            model.handleScreenLock(true); await drainTasks()
            model.dimming.awaitingWakeStability = true
            model.dimming.failRestore = true
            let calls = model.dimming.restoreCalls
            model.checkAirPodsRemoval(now: now + 1); await drainTasks()
            check(model.dimming.restoreCalls == calls,
                  "A no-journal wake-stability retry cannot run while locked")
            model.handleScreenLock(false); await drainTasks()
            check(model.automaticFeaturesPaused && model.removalPresence.phase == .failed &&
                  !model.dimming.hasPendingRestore && model.dimming.awaitingWakeStability,
                  "Failed no-journal wake settling remains pending while automatic features are off")
            model.dimming.failRestore = false
            model.checkAirPodsRemoval(now: now + 3); await drainTasks()
            check(!model.dimming.awaitingWakeStability && model.removalPresence.canResumeHeading,
                  "An active lifecycle tick retries wake settling without requiring a dim journal")
            check(model.automaticFeaturesPaused && !model.cameraHeading.sessionActive &&
                  !model.presence.isRunning && model.overlay.startCalls == 0,
                  "No-journal recovery preserves feature-off and starts no camera or desktop effect")
            model.shutdown()
        }
        do {
            let active: [String: Any] = [kCGSessionOnConsoleKey as String: true, kCGSessionLoginDoneKey as String: true]
            check(SessionLockEvidence.read(active) == .unlocked,
                  "The observed active-console schema with absent lock key is valid unlocked evidence")
            var explicit = active; explicit["CGSSessionScreenIsLocked"] = false
            check(SessionLockEvidence.read(explicit) == .unlocked, "An explicit false lock flag is valid unlocked evidence")
            explicit["CGSSessionScreenIsLocked"] = true
            check(SessionLockEvidence.read(explicit) == .locked, "An explicit lock flag remains authoritative suspension evidence")
            for malformed: Any in ["false", NSNull(), 0, 1, 2, NSNumber(value: 0), NSNumber(value: 1), NSNumber(value: 0.0)] {
                explicit["CGSSessionScreenIsLocked"] = malformed
                check(SessionLockEvidence.read(explicit) == .unavailable,
                      "A malformed present lock value is unavailable rather than an inferred unlock")
            }
            check(SessionLockEvidence.read(nil) == .unavailable && SessionLockEvidence.read([:]) == .unavailable,
                  "A missing session dictionary or flags cannot establish an unlocked session")
            var missing = active; missing.removeValue(forKey: kCGSessionLoginDoneKey as String)
            check(SessionLockEvidence.read(missing) == .unavailable, "An absent login-done flag cannot clear a lock")
            missing = active; missing[kCGSessionOnConsoleKey as String] = NSNumber(value: 1)
            check(SessionLockEvidence.read(missing) == .unavailable, "A numeric console flag is not accepted as Boolean session evidence")
            missing = active; missing[kCGSessionOnConsoleKey as String] = false
            check(SessionLockEvidence.read(missing) == .locked, "An off-console session remains inactive even without a lock key")
        }
        do {
            let model = makeModel()
            var time = 100.0, reads = 0
            model.sessionStateClock = { time }
            model.sessionLockEvidence = { reads += 1; return .unlocked }
            useCamera(model); model.enable(); await drainTasks()
            model.handleScreenLock(false)
            model.handleScreenLock(true)
            check(!model.enabled && !model.cameraHeading.sessionActive && model.sessionDiagnosticState["screenLocked"] == true,
                  "A delayed or real lock hint still clears blur and disables camera work immediately")
            for value in [100.0, 100.5, 101, 101.99] { time = value; model.reconcileSessionLockState() }
            check(reads == 0 && model.sessionDiagnosticState["screenLocked"] == true,
                  "A transient unlocked query at the notification boundary cannot bypass the two-second quiet interval")
            for value in [102.0, 102.25, 102.5, 102.75] { time = value; model.reconcileSessionLockState() }
            for _ in 0..<20 { model.reconcileSessionLockState() }
            check(reads == 4 && model.sessionDiagnosticState["screenLocked"] == true,
                  "Four samples and repeated same-time ticks cannot falsely complete unlocked confirmation")
            time = 103; model.reconcileSessionLockState(); await drainTasks()
            check(model.sessionDiagnosticState["active"] == true && reads == 5 && model.cameraHeading.sessionActive,
                  "Five independent unlocked samples over one second reconcile the stale app lock gate")
            check(model.recentSessionEvents.last?["source"] as? String == "screen-state-reconciled",
                  "A bounded diagnostic event distinguishes app-state reconciliation from a macOS unlock notification")
            let events = model.recentSessionEvents.count, restores = model.dimming.restoreCalls
            for value in [104.0, 105, 110] { time = value; model.reconcileSessionLockState() }
            check(model.recentSessionEvents.count == events && model.dimming.restoreCalls == restores && reads == 5,
                  "A corrected active session does not repeatedly query, restore brightness, or append reconciliation events")
            model.shutdown()
        }
        do {
            let model = makeModel()
            var time = 100.0
            var evidence = SessionLockEvidence.unlocked
            model.sessionStateClock = { time }; model.sessionLockEvidence = { evidence }
            model.handleScreenLock(true); await drainTasks()
            for value in [102.0, 102.25] { time = value; model.reconcileSessionLockState() }
            evidence = .unavailable; time = 102.5; model.reconcileSessionLockState()
            evidence = .unlocked
            for value in [102.75, 103, 103.25, 103.5] { time = value; model.reconcileSessionLockState() }
            check(model.sessionDiagnosticState["screenLocked"] == true,
                  "Unavailable session evidence resets the consecutive-unlocked proof")
            evidence = .locked; time = 103.75; model.reconcileSessionLockState()
            evidence = .unlocked
            for value in [104.0, 105, 105.74] { time = value; model.reconcileSessionLockState() }
            check(model.sessionDiagnosticState["screenLocked"] == true,
                  "A newly observed lock resets the quiet interval before any later unlocked confirmation")
            for value in [105.75, 106, 106.25, 106.5] { time = value; model.reconcileSessionLockState() }
            time = 110; model.reconcileSessionLockState()
            check(model.sessionDiagnosticState["screenLocked"] == true,
                  "A long polling gap cannot count as continuous unlocked evidence")
            for value in [110.25, 110.5, 110.75, 111] { time = value; model.reconcileSessionLockState() }
            await drainTasks()
            check(model.sessionDiagnosticState["active"] == true,
                  "A complete later stable sequence can recover after transient and unavailable results")
            model.shutdown()
        }
        do {
            let model = makeModel()
            var time = 100.0
            model.sessionStateClock = { time }; model.sessionLockEvidence = { .unlocked }
            model.handleScreenLock(true); await drainTasks()
            for value in [102.0, 102.25, 102.5, 102.75] { time = value; model.reconcileSessionLockState() }
            model.handleScreenLock(true)
            time = 103; model.reconcileSessionLockState()
            check(model.sessionDiagnosticState["screenLocked"] == true,
                  "A second delayed lock hint invalidates an almost-complete unlocked proof")
            for value in [104.75, 105, 105.25, 105.5, 105.75] { time = value; model.reconcileSessionLockState() }
            await drainTasks()
            check(model.sessionDiagnosticState["active"] == true,
                  "Stable current session evidence can recover after repeated delayed lock hints stop")
            model.shutdown()
        }
        for inactivity in ["screen", "system", "session"] {
            let model = makeModel()
            var time = 100.0, reads = 0
            model.sessionStateClock = { time }; model.sessionLockEvidence = { reads += 1; return .unlocked }
            model.handleScreenLock(true)
            switch inactivity {
            case "screen": model.handleWorkspaceEvent(NSWorkspace.screensDidSleepNotification)
            case "system": model.handleWorkspaceEvent(NSWorkspace.willSleepNotification)
            default: model.handleWorkspaceEvent(NSWorkspace.sessionDidResignActiveNotification)
            }
            for value in [102.0, 102.25, 102.5, 102.75, 103, 110] { time = value; model.reconcileSessionLockState() }
            check(reads == 0 && model.sessionDiagnosticState["active"] == false,
                  "\(inactivity): independent unlocked evidence cannot bypass an inactive workspace flag")
            switch inactivity {
            case "screen": model.handleWorkspaceEvent(NSWorkspace.screensDidWakeNotification)
            case "system": model.handleWorkspaceEvent(NSWorkspace.didWakeNotification)
            default: model.handleWorkspaceEvent(NSWorkspace.sessionDidBecomeActiveNotification)
            }
            check(model.sessionDiagnosticState["screenLocked"] == true,
                  "\(inactivity): one instantaneous unlocked query on a workspace event cannot erase the latched lock")
            for value in [112.0, 112.25, 112.5, 112.75, 113] { time = value; model.reconcileSessionLockState() }
            await drainTasks()
            check(model.sessionDiagnosticState["active"] == true,
                  "\(inactivity): recovery is possible only after every workspace flag and unlocked confirmation agree")
            model.shutdown()
        }
        do {
            let model = makeModel()
            var time = 100.0
            model.sessionStateClock = { time }; model.sessionLockEvidence = { .unlocked }
            let now = ProcessInfo.processInfo.systemUptime
            await beginPresence(model, now: now)
            model.presence.state = .present; model.checkAirPodsRemoval(now: now + 3.2); await drainTasks()
            model.handleScreenLock(true); await drainTasks()
            model.dimming.holdRestore = true
            freshWear(model)
            for value in [102.0, 102.25, 102.5, 102.75, 103] { time = value; model.reconcileSessionLockState() }
            await drainTasks()
            check(model.sessionDiagnosticState["active"] == true && model.dimming.hasPendingRestore &&
                  !model.cameraHeading.sessionActive && !model.presence.isRunning && !model.enabled,
                  "Reconciled session state still waits for owned brightness restoration before any camera or blur resumes")
            time = 103.1; model.handleScreenLock(true); await drainTasks()
            model.dimming.releaseRestore(); await drainTasks()
            check(model.sessionDiagnosticState["screenLocked"] == true && model.dimming.hasPendingRestore &&
                  !model.cameraHeading.sessionActive && !model.presence.isRunning,
                  "A real lock during reconciled brightness recovery defeats its late acknowledgement")
            for value in [105.1, 105.35, 105.6, 105.85, 106.1] { time = value; model.reconcileSessionLockState() }
            await drainTasks()
            check(!model.dimming.hasPendingRestore && model.removalPresence.canResumeHeading && model.cameraHeading.sessionActive,
                  "A later independent stable session proof retries the original brightness barrier safely")
            model.shutdown()
        }
        do {
            let model = makeModel()
            var time = 100.0
            model.sessionStateClock = { time }; model.sessionLockEvidence = { .unlocked }
            model.cancelWearWait(); await drainTasks()
            model.handleScreenLock(true); await drainTasks()
            for value in [102.0, 102.25, 102.5, 102.75, 103] { time = value; model.reconcileSessionLockState() }
            await drainTasks()
            check(model.sessionDiagnosticState["active"] == true && model.automaticFeaturesPaused &&
                  !model.cameraHeading.sessionActive && !model.presence.isRunning && !model.enabled,
                  "Repairing stale session state preserves the user's explicit Turn off choice")
            model.handleScreenLock(true); model.shutdown()
            time = 106
            for _ in 0..<8 { model.reconcileSessionLockState(); time += 0.25 }
            check(model.sessionDiagnosticState["screenLocked"] == true && !model.cameraHeading.sessionActive,
                  "Shutdown prevents cached-state reconciliation from reactivating any work")
        }
        for returnFirst in [true, false] {
            let model = makeModel()
            var now = ProcessInfo.processInfo.systemUptime
            for cycle in 0..<3 {
                freshWear(model)
                await beginPresence(model, now: now)
                model.presence.state = .present; model.checkAirPodsRemoval(now: now + 3.2); await drainTasks()
                check(model.dimming.hasPendingRestore, "Cycle \(cycle) begins with owned dimming")
                model.presence.state = .absent; model.checkAirPodsRemoval(now: now + 3.5); await drainTasks()
                model.handleScreenLock(true)
                model.handleWorkspaceEvent(NSWorkspace.screensDidSleepNotification); await drainTasks()
                let writes = model.dimming.brightnessWrites
                if returnFirst { freshWear(model) }
                model.sessionLockState = { true }
                model.handleWorkspaceEvent(NSWorkspace.screensDidWakeNotification); await drainTasks()
                check(model.dimming.hasPendingRestore && model.dimming.brightnessWrites == writes,
                      "Return order \(returnFirst), cycle \(cycle): wake while locked retains brightness ownership")
                model.sessionLockState = { false }
                model.handleScreenLock(false); await drainTasks()
                if !returnFirst {
                    model.presence.state = .present
                    model.checkAirPodsRemoval(now: now + 4.2); await drainTasks()
                    freshWear(model); model.checkAirPodsRemoval(now: now + 5); await drainTasks()
                }
                check(!model.dimming.hasPendingRestore && model.removalPresence.canResumeHeading,
                      "Return order \(returnFirst), cycle \(cycle): restoration completes before heading after unlock")
                now += 12
            }
            model.shutdown()
        }
        print("PASS: \(checks) real AppModel and removal-coordinator lifecycle assertions; camera, motion, brightness, capture, display sleep, permissions, and preferences stubbed")
    }
}
