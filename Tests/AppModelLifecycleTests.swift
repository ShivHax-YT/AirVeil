import AppKit
import Combine
import Foundation

// Compile with the real AppModel.swift and VeilMath.swift, without the live
// MotionService/DesktopOverlayController implementations. Local declarations
// also replace both permission entry points: this test never requests capture
// access, starts Core Motion, displays overlays, or accesses desktop frames.
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
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    func start() async throws { startCalls += 1; isRunning = true; isReady = true }
    func stop() { stopCalls += 1; isRunning = false; isReady = false }
    func update(left: Double, right: Double, blurPoints: Double, feather: Double,
                opaque: Bool, shield: Bool, wholeScreen: Bool) {}
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

    static func main() async {
        // Each cancellation happens synchronously in the same main-actor turn
        // as scheduling, before the unstructured operation can enter its body.
        do {
            let model = AppModel()
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
            let model = AppModel()
            model.enable()
            model.shutdown()
            await drainTasks()
            check(model.overlay.startCalls == 0, "Immediate shutdown prevents capture start")
            check(!model.enabled && !model.starting && !model.overlay.isRunning && !model.motion.isRunning,
                  "Shutdown stays stopped after queued tasks drain")
        }
        do {
            let model = AppModel()
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
            let model = AppModel()
            model.enable()
            await drainTasks()
            check(model.overlay.startCalls == 1 && model.enabled,
                  "Uncancelled enable executes, proving the scheduler was drained")
            model.shutdown()
        }
        do {
            let model = AppModel()
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
            let model = AppModel()
            let before = SCShareableContent.requestCalls
            model.requestScreenPermission()
            model.shutdown()
            await drainTasks()
            check(SCShareableContent.requestCalls == before, "Shutdown prevents queued permission request")
        }
        do {
            let model = AppModel()
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
            let model = AppModel()
            model.motion.isCalibrated = false
            model.calibrate()
            model.pause()
            await drainTasks()
            check(model.motion.calibrateCalls == 0 && !model.calibrating,
                  "Pause invalidates queued calibration")
            model.shutdown()
        }
        print("PASS: \(checks) real AppModel lifecycle assertions; motion, capture, and permission APIs stubbed")
    }
}
