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
}

@MainActor final class MotionService: ObservableObject {
    @Published var isFresh = true
    @Published var isCalibrated = true
    @Published var isRunning = true
    @Published var yawDegrees = 0.0
    @Published var status = "Test motion"
    var canCalibrate = true
    var trackingValid: Bool { isRunning && isFresh && isCalibrated }
    private(set) var calibrateCalls = 0
    func start() { isRunning = true }
    func stop() { isRunning = false; isFresh = false; isCalibrated = false }
    func calibrate() { calibrateCalls += 1; isCalibrated = true }
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
                blockInput: Bool, blocksEntireDisplay: Bool) {}
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

    private static func makeModel() -> AppModel {
        UserDefaults.standard.clear()
        return AppModel()
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
            model.strengths = .full
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
        print("PASS: \(checks) real AppModel lifecycle assertions; motion, capture, permissions, and preferences stubbed")
    }
}
