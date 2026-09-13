import Foundation
import CoreGraphics
import Combine

/// Standalone test-module shadows: the real coordinator/engine/service execute,
/// but no actual MotionService or persistent preferences are constructed.
@MainActor final class UserDefaults {
    static let standard = UserDefaults()
    private var values: [String: Any] = [:]
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
@MainActor final class MotionService: ObservableObject {
    @Published var fusionSample: HeadingMotionSample?
    var fusionEpoch: UInt64 = 1
    var isFresh = true
}
@MainActor private final class CoordinatorCameraCapture: CameraAnchorCapturing {
    var authorization = CameraAuthorization.authorized
    var permissionAllowed = true
    var permissionRequests = 0
    var starts = 0
    var stops = 0
    var holdStart = false
    var startContinuation: CheckedContinuation<CameraAnchorConfiguration, Error>?
    var handlers: [@MainActor (CameraAnchorFrame) -> Void] = []
    func requestPermission() async -> Bool {
        permissionRequests += 1
        authorization = permissionAllowed ? .authorized : .denied
        return permissionAllowed
    }
    func start(onFrame: @escaping @MainActor (CameraAnchorFrame) -> Void,
               onPreview: @escaping @MainActor (CGImage) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) async throws -> CameraAnchorConfiguration {
        starts += 1; handlers.append(onFrame)
        if holdStart { return try await withCheckedThrowingContinuation { startContinuation = $0 } }
        return configuration
    }
    var configuration: CameraAnchorConfiguration {
        CameraAnchorConfiguration(cameraID: "builtin-test", cameraName: "Fake camera",
            configurationID: "vision3-up-unmirrored-vga", captureFramesPerSecond: 3)
    }
    func releaseStart() { startContinuation?.resume(returning: configuration); startContinuation = nil }
    func stop() { stops += 1 }
}
private struct StoredCameraProbe: Codable {
    let center: HeadingCameraCenter
    let layoutKey: String
    let configurationID: String
}
@MainActor private final class CoordinatorFixture {
    var time = 100.0
    let motion = MotionService()
    let capture = CoordinatorCameraCapture()
    let defaults = UserDefaults()
    let camera: CameraAnchorService
    var coordinator: CameraHeadingCoordinator!
    var layout = "display-A"
    init(enabled: Bool = true, stored: Bool = false) {
        camera = CameraAnchorService(capture: capture)
        defaults.set(enabled, forKey: "cameraAssistance")
        if stored {
            let value = StoredCameraProbe(center: HeadingCameraCenter(cameraID: "builtin-test", neutralYawRadians: 0,
                cameraSign: 1, sensorSign: 1, revision: 5), layoutKey: "display-A", configurationID: "vision3-up-unmirrored-vga")
            defaults.set(try! JSONEncoder().encode(value), forKey: "cameraScreenCenterV1")
        }
        coordinator = CameraHeadingCoordinator(motion: motion, camera: camera, defaults: defaults, now: { [unowned self] in self.time })
    }
    func advance(_ seconds: Double, yaw: Double = 0, update: Bool = true) {
        let end = time + seconds
        while time < end - 0.000001 {
            time = min(end, time + 0.02)
            motion.fusionSample = HeadingMotionSample(epoch: motion.fusionEpoch, sourceTimestamp: time - 90,
                receiptHostTime: time, yawRadians: yaw * .pi / 180, angularSpeed: 0)
            if update { coordinator.update(layoutKey: layout) }
        }
    }
    func frame(yaw: Double?, faces: Int = 1, handler: Int? = nil,
               confidence: Float = 0.95, luminance: Double? = nil,
               bounds: CGRect = CGRect(x: 0.3, y: 0.25, width: 0.3, height: 0.4)) {
        let index = handler ?? capture.handlers.count - 1
        guard index >= 0 else { fatalError("Camera burst has not started") }
        capture.handlers[index](CameraAnchorFrame(cameraID: "builtin-test", configurationID: "vision3-up-unmirrored-vga",
            faceCount: faces, yawDegrees: yaw, pitchDegrees: 0, rollDegrees: 0, detectionConfidence: confidence,
            faceBounds: bounds, captureHostTime: time,
            receiptHostTime: time, processedHostTime: time, luminance: luminance))
    }
    func frames(_ count: Int, cameraYaw: Double, motionYaw: Double) {
        for _ in 0..<count { frame(yaw: cameraYaw); advance(0.34, yaw: motionYaw) }
    }
    func end() { coordinator.shutdown() }
}

@main struct CameraHeadingCoordinatorTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { fatalError(message) }
        }
        func settle() async { for _ in 0..<20 { await Task.yield() } }
        func close(_ a: Double, _ b: Double) -> Bool { abs(a-b) < 0.001 }

        for cancellation in ["disable", "sleep"] {
            let f = CoordinatorFixture(enabled: false)
            f.coordinator.requestEnable()
            if cancellation == "disable" { f.coordinator.disable() }
            else { f.coordinator.setSessionActive(false) }
            await settle()
            check(f.capture.permissionRequests == 0 && f.capture.starts == 0,
                  "Queued permission is cancelled before entry by \(cancellation)")
            check(!f.coordinator.isBusy && !f.coordinator.isEnabled, "Cancelled enable stays off")
            check(f.coordinator.coach.phase == .idle, "Cancelled enable hides coach")
            f.end()
        }
        do {
            let f = CoordinatorFixture(enabled: false)
            f.capture.permissionAllowed = false
            f.coordinator.requestEnable(); await settle()
            check(f.capture.permissionRequests == 1 && !f.coordinator.isEnabled, "Explicit denial leaves assistance off")
            check(f.coordinator.coach.retryAction == .enableCamera, "Permission denial retries permission instead of direction capture")
            f.advance(1)
            check(f.capture.starts == 0, "Denial never activates camera")
            f.end()
        }
        do {
            let f = CoordinatorFixture(stored: true)
            f.capture.authorization = .denied
            f.advance(0.8, yaw: 8); await settle()
            check(f.coordinator.isEnabled && f.coordinator.coach.phase == .failure && f.coordinator.coach.retryAction == .enableCamera,
                  "Revoked camera authorization retries permission even when the enabled preference remains true")
            check(f.capture.starts == 0, "Revoked permission cannot start acquisition")
            f.capture.permissionAllowed = false
            f.coordinator.requestEnable(); await settle()
            check(f.coordinator.isEnabled && f.coordinator.coach.retryAction == .enableCamera,
                  "An explicit permission failure preserves enable-camera retry with a persisted enabled preference")
            f.end()
        }
        for recenter in [false, true] {
            let f = CoordinatorFixture(stored: true)
            let saved = f.defaults.data(forKey: "cameraScreenCenterV1")
            f.advance(0.8, yaw: 8); await settle()
            if recenter { f.coordinator.setCenter(layoutKey: f.layout); await settle() }
            f.camera.stop() // Same boundary used by the service's bounded timeout.
            f.coordinator.update(layoutKey: f.layout)
            check(f.coordinator.coach.phase == .failure && f.coordinator.coach.issue == .camera,
                  "Stopped camera publishes a reviewable failure")
            check(f.coordinator.coach.retryAction == (recenter ? .setCenter : .refreshDirection),
                  "A \(recenter ? "recenter" : "recovery") timeout retains its requested operation before phase cancellation")
            check(f.coordinator.centerRevision == 5 && f.defaults.data(forKey: "cameraScreenCenterV1") == saved,
                  "Failure leaves the existing saved center unchanged")
            f.coordinator.cancelPendingRecovery()
            check(f.coordinator.coach.retryAction == nil, "Cancellation clears stale retry intent")
            f.end()
        }
        do {
            let f = CoordinatorFixture(enabled: false)
            f.advance(1); await settle()
            check(f.capture.starts == 0 && f.capture.permissionRequests == 0, "Disabled coordinator has no automatic camera work")
            f.coordinator.requestEnable(); await settle()
            check(f.coordinator.isEnabled && f.capture.starts == 0, "Permission enable alone does not capture without a stored center")
            f.end()
        }
        do {
            let f = CoordinatorFixture()
            f.advance(0.8, yaw: 20)
            f.coordinator.setCenter(layoutKey: f.layout); await settle()
            f.advance(0.8, yaw: 20)
            f.frames(3, cameraYaw: 10, motionYaw: 20)
            check(!f.coordinator.hasCenter && f.coordinator.status.contains("Turn"), "Neutral alone waits for observed sign turn")
            f.advance(0.8, yaw: 40)
            f.frames(3, cameraYaw: -10, motionYaw: 40)
            check(f.coordinator.hasCenter && f.coordinator.centerRevision == 1, "Observed turn completes exactly one explicit screen anchor")
            check(f.coordinator.coach.phase != .success && !f.coordinator.isAligned,
                  "Saving center alone never shows a successful alignment")
            let data = f.defaults.data(forKey: "cameraScreenCenterV1")!
            let value = try JSONDecoder().decode(StoredCameraProbe.self, from: data)
            check(value.center.cameraSign == -1 && close(value.center.neutralYawRadians * 180 / .pi, -10),
                  "Stored neutral uses learned negative camera sign")
            check(value.layoutKey == "display-A", "Stored center belongs to original display layout")
            await settle()
            f.advance(0.8, yaw: 40); await settle()
            f.frames(3, cameraYaw: -10, motionYaw: 40)
            check(f.coordinator.trackingValid && close(f.coordinator.yawDegrees, 20), "Initial recovery preserves setup-ending turned pose")
            check(f.coordinator.coach.phase == .success && f.coordinator.coach.progress == 1 && !f.camera.isRunning,
                  "Real paired alignment shows success only after capture stops")
            let revision = f.coordinator.centerRevision
            f.motion.isFresh = false; f.motion.fusionEpoch += 1; f.motion.fusionSample = nil
            check(!f.coordinator.trackingValid, "Nil motion immediately invalidates aligned output")
            check(f.coordinator.coach.phase == .idle, "Loss of AirPods clears a visible success immediately")
            f.coordinator.update(layoutKey: f.layout)
            f.motion.isFresh = true
            f.advance(0.8, yaw: -25); await settle()
            f.frames(3, cameraYaw: -20, motionYaw: -25)
            check(f.coordinator.trackingValid && close(f.coordinator.yawDegrees, 30), "Turned rewear uses camera reference despite changed headphone zero")
            check(f.coordinator.centerRevision == revision && f.defaults.data(forKey: "cameraScreenCenterV1") == data,
                  "Rewear alignment never changes stored screen center or its revision")
            f.end()
        }
        for cancellation in ["manual", "epoch", "layout", "sleep"] {
            let f = CoordinatorFixture(stored: true)
            f.advance(0.8, yaw: 8); await settle()
            f.frames(2, cameraYaw: 35, motionYaw: 8)
            let oldHandler = f.capture.handlers.count - 1
            switch cancellation {
            case "manual": f.coordinator.cancelPendingRecovery()
            case "epoch": f.motion.isFresh = false; f.motion.fusionEpoch += 1; f.motion.fusionSample = nil; f.coordinator.update(layoutKey: f.layout)
            case "layout": f.layout = "display-B"; f.coordinator.update(layoutKey: f.layout)
            default: f.coordinator.setSessionActive(false)
            }
            f.frame(yaw: 35, handler: oldHandler)
            f.advance(0.4, yaw: 8)
            check(!f.coordinator.trackingValid && f.coordinator.centerRevision == 5,
                  "\(cancellation) prevents late candidate commit or reference replacement")
            check(!f.camera.isRunning, "\(cancellation) stops the camera burst")
            check(f.coordinator.coach.progress == 0 && f.coordinator.coach.phase != .success,
                  "\(cancellation) clears hold evidence and success presentation")
            f.end()
        }
        for malformed in ["missing-yaw", "multiple-faces"] {
            let f = CoordinatorFixture(stored: true)
            f.advance(0.8, yaw: 8); await settle()
            f.frames(2, cameraYaw: 35, motionYaw: 8)
            f.frame(yaw: malformed == "missing-yaw" ? nil : 35, faces: malformed == "multiple-faces" ? 2 : 1)
            check(f.coordinator.coach.phase == .seeking && f.coordinator.coach.progress == 0,
                  "\(malformed) immediately clears visual hold progress")
            f.advance(0.34, yaw: 8)
            f.frames(1, cameraYaw: 35, motionYaw: 8)
            check(!f.coordinator.trackingValid, "\(malformed) breaks candidate continuity; two earlier faces cannot combine with a later one")
            f.frames(2, cameraYaw: 35, motionYaw: 8)
            check(f.coordinator.trackingValid, "Three new valid frames recover after \(malformed)")
            f.end()
        }
        do {
            let f = CoordinatorFixture()
            f.advance(0.8, yaw: 20)
            f.coordinator.setCenter(layoutKey: f.layout); await settle()
            f.advance(0.8, yaw: 20)
            f.frames(5, cameraYaw: 35, motionYaw: 20)
            check(!f.coordinator.hasCenter && f.coordinator.coach.phase == .offCenter,
                  "Stable turned head cannot silently become the explicit screen center")
            check(f.coordinator.coach.issue == .pose && f.coordinator.coach.progress == 0,
                  "Turned center setup gets red pose guidance without fake progress")
            f.frame(yaw: nil, faces: 0, confidence: 0, luminance: 0.08)
            check(f.coordinator.coach.issue == .faceMissing, "One dim frame cannot flash a low-light warning")
            f.frame(yaw: nil, faces: 0, confidence: 0, luminance: 0.08)
            check(f.coordinator.coach.issue == .lowLight && f.coordinator.coach.title.contains("light"),
                  "Failed scan with measured darkness explains the need for light")
            f.frame(yaw: nil, faces: 0, confidence: 0)
            check(f.coordinator.coach.issue == .faceMissing,
                  "An unmeasured failed scan never guesses low light")
            f.frame(yaw: 0, bounds: CGRect(x: 0.03, y: 0.3, width: 0.2, height: 0.3))
            check(f.coordinator.coach.direction == .left && f.coordinator.coach.horizontalError > 0,
                  "A face at the mirrored preview's right edge gets a leftward guide")
            f.coordinator.cancelPendingRecovery()
            check(f.coordinator.coach.phase == .idle && !f.camera.isRunning, "Cancel hides all guidance")
            f.end()
        }
        do {
            let f = CoordinatorFixture(stored: true)
            f.advance(0.8, yaw: 8); await settle()
            f.frames(1, cameraYaw: 30, motionYaw: 8)
            check(f.coordinator.coach.phase == .holding && f.coordinator.coach.progress > 0 && f.coordinator.coach.progress < 1,
                  "Partial paired evidence advances a bounded hold indication")
            let progress = f.coordinator.coach.progress
            f.advance(0.3, yaw: 8)
            check(f.coordinator.coach.progress == progress, "Elapsed time alone cannot increase measured hold progress")
            f.advance(0.6, yaw: 8)
            check(f.coordinator.coach.phase == .seeking && f.coordinator.coach.progress == 0,
                  "Stale camera frames clear hold progress")
            f.frames(3, cameraYaw: 30, motionYaw: 8)
            check(f.coordinator.coach.phase == .success, "Three new paired samples finish real recovery after a frame gap")
            f.coordinator.refreshDirection(); await settle()
            try await Task.sleep(nanoseconds: 1_160_000_000)
            check(f.coordinator.coach.phase == .starting && f.camera.isRunning,
                  "Old success dismissal cannot hide a newly started attempt")
            f.end()
        }
        do {
            let f = CoordinatorFixture()
            f.advance(0.8, yaw: 20)
            f.coordinator.setCenter(layoutKey: f.layout); await settle()
            f.advance(0.8, yaw: 20); f.frames(2, cameraYaw: 10, motionYaw: 20)
            f.layout = "display-B"; f.coordinator.update(layoutKey: f.layout)
            f.frame(yaw: 10, handler: 0); f.advance(0.4, yaw: 20)
            check(!f.coordinator.hasCenter && !f.camera.isRunning, "Layout change during initial setup cannot save old neutral under new layout")
            f.end()
        }
        do {
            let f = CoordinatorFixture(stored: true)
            f.capture.holdStart = true
            f.advance(0.8, yaw: 8); await settle()
            check(f.coordinator.isBusy && f.camera.isRunning, "Coordinator startup is suspended at the fake capture boundary")
            // The service's own timeout is tested with a real short timer in
            // CameraAnchorServiceTests. Reproduce its stopped state here while
            // the underlying start call has still not returned.
            f.camera.stop()
            f.coordinator.update(layoutKey: f.layout)
            check(!f.coordinator.isBusy, "Service stop/timeout clears coordinator even before startup returns")
            f.capture.releaseStart(); await settle()
            check(!f.coordinator.trackingValid && !f.coordinator.isBusy && !f.camera.isRunning,
                  "Late startup completion cannot resurrect stopped coordinator")
            f.end()
        }
        do {
            let f = CoordinatorFixture(stored: true)
            f.layout = "display-B"
            var publications = 0
            let token = f.coordinator.objectWillChange.sink { publications += 1 }
            f.coordinator.update(layoutKey: f.layout)
            check(publications == 1 && f.coordinator.status.contains("display setup changed"),
                  "First layout mismatch publishes its meaningful status transition once")
            publications = 0
            for _ in 0..<100 { f.coordinator.update(layoutKey: f.layout) }
            check(publications == 0, "Repeated unchanged layout mismatch does not republish coordinator state")
            check(!f.coordinator.trackingValid && f.capture.starts == 0 && f.coordinator.centerRevision == 5,
                  "Deduplicated mismatch remains blocked without camera work or replacing the original center")
            token.cancel(); f.end()
        }
        print("PASS: \(checks) real camera coordinator/service/fusion checks; motion, capture, and preferences injected, no camera access")
    }
}
