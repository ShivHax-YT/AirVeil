import Foundation
import CoreGraphics
import Combine
import Darwin

/// Standalone test-module shadows: the real coordinator/engine/service execute,
/// but no actual MotionService or persistent preferences are constructed.
@MainActor final class UserDefaults {
    static let standard = UserDefaults()
    private var values: [String: Any] = [:]
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
enum MotionConnectionState { case connected, disconnected, unknown }
@MainActor final class MotionService: ObservableObject {
    var removalEventCount: UInt64 = 0
    var disconnectEventCount: UInt64 = 0
    var connectionState = MotionConnectionState.connected
    var removalConnectionState = MotionConnectionState.connected
    @Published var fusionSample: HeadingMotionSample?
    var fusionEpoch: UInt64 = 1
    var isFresh = true
}
@MainActor private final class CoordinatorCameraCapture: CameraAnchorCapturing {
    var authorization = CameraAuthorization.authorized
    var permissionAllowed = true
    var permissionRequests = 0
    var holdPermission = false
    var permissionContinuation: CheckedContinuation<Bool, Never>?
    var starts = 0
    var stops = 0
    var cameraID = "builtin-test"
    var configurationID = "vision3-up-unmirrored-vga"
    var holdStart = false
    var startContinuation: CheckedContinuation<CameraAnchorConfiguration, Error>?
    var handlers: [@MainActor (CameraAnchorFrame) -> Void] = []
    func requestPermission() async -> Bool {
        permissionRequests += 1
        let allowed: Bool
        if holdPermission { allowed = await withCheckedContinuation { permissionContinuation = $0 } }
        else { allowed = permissionAllowed }
        authorization = allowed ? .authorized : .denied
        return allowed
    }
    func releasePermission(_ allowed: Bool) {
        let continuation = permissionContinuation
        permissionContinuation = nil
        continuation?.resume(returning: allowed)
    }
    func start(onFrame: @escaping @MainActor (CameraAnchorFrame) -> Void,
               onPreview: @escaping @MainActor (CGImage) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) async throws -> CameraAnchorConfiguration {
        starts += 1; handlers.append(onFrame)
        if holdStart { return try await withCheckedThrowingContinuation { startContinuation = $0 } }
        return configuration
    }
    var configuration: CameraAnchorConfiguration {
        CameraAnchorConfiguration(cameraID: cameraID, cameraName: "Fake camera",
            configurationID: configurationID, captureFramesPerSecond: 3)
    }
    func releaseStart() { startContinuation?.resume(returning: configuration); startContinuation = nil }
    func stop() { stops += 1 }
}
private struct StoredCameraProbe: Codable {
    let center: HeadingCameraCenter
    let layoutKey: String
    let configurationID: String
    var visualCameraSign: Double? = nil
}
@MainActor private final class CoordinatorFaceLight: FaceLighting {
    var isOn = false
    var available = true
    @discardableResult func setEnabled(_ enabled: Bool) -> Bool {
        if enabled && !available { return false }
        isOn = enabled; return true
    }
}
@MainActor private final class CoordinatorFixture {
    var time = 100.0
    let motion = MotionService()
    let capture = CoordinatorCameraCapture()
    let defaults = UserDefaults()
    let camera: CameraAnchorService
    let light = CoordinatorFaceLight()
    var coordinator: CameraHeadingCoordinator!
    var layout = "display-A"
    init(enabled: Bool = true, stored: Bool = false, legacy: Bool = false, holdPermission: Bool = false) {
        capture.holdPermission = holdPermission
        camera = CameraAnchorService(capture: capture, faceLight: light)
        defaults.set(enabled, forKey: "cameraAssistance")
        if stored {
            let value = StoredCameraProbe(center: HeadingCameraCenter(cameraID: "builtin-test", neutralYawRadians: legacy ? 15 * .pi / 180 : 0,
                cameraSign: legacy ? -1 : 0, sensorSign: 1, revision: 5, mode: legacy ? nil : .facingCamera), layoutKey: "display-A", configurationID: "vision3-up-unmirrored-vga")
            defaults.set(try! JSONEncoder().encode(value), forKey: "cameraScreenCenterV1")
        }
        coordinator = CameraHeadingCoordinator(motion: motion, camera: camera, defaults: defaults, now: { [unowned self] in self.time })
    }
    func advance(_ seconds: Double, yaw: Double = 0, update: Bool = true, angularSpeed: Double = 0) {
        let end = time + seconds
        while time < end - 0.000001 {
            time = min(end, time + 0.02)
            motion.fusionSample = HeadingMotionSample(epoch: motion.fusionEpoch, sourceTimestamp: time - 90,
                receiptHostTime: time, yawRadians: yaw * .pi / 180, angularSpeed: angularSpeed)
            if update { coordinator.update(layoutKey: layout) }
        }
    }
    func frame(yaw: Double?, faces: Int = 1, handler: Int? = nil,
               confidence: Float = 0.95, luminance: Double? = nil,
               bounds: CGRect = CGRect(x: 0.3, y: 0.25, width: 0.3, height: 0.4)) {
        let index = handler ?? capture.handlers.count - 1
        guard index >= 0 else { fatalError("Camera burst has not started") }
        capture.handlers[index](CameraAnchorFrame(cameraID: capture.cameraID, configurationID: capture.configurationID,
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
            if !condition() {
                FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
                Darwin.exit(1)
            }
        }
        func settle() async { for _ in 0..<20 { await Task.yield() } }
        func close(_ a: Double, _ b: Double) -> Bool { abs(a-b) < 0.001 }
        for stored in [false, true] {
            for fresh in [false, true] {
                let f = CoordinatorFixture(stored: stored)
                f.motion.isFresh = fresh
                f.motion.removalConnectionState = .unknown
                f.coordinator.setSessionActive(false)
                check(f.coordinator.status == "Head-direction checks are paused.",
                      "Paused heading guidance does not assume the Mac is asleep or the presence camera is off")
                f.coordinator.setSessionActive(true)
                await settle()
                let expected = fresh
                    ? (stored ? "Face the camera. Use Refresh direction to check your saved screen direction."
                              : "Face the camera and use Set center to set up camera assistance.")
                    : (stored ? "Waiting for AirPods before checking the saved screen direction."
                              : "Wear your AirPods, then face the camera and use Set center.")
                check(f.coordinator.status == expected,
                      "Activation replaces stale inactive guidance for saved=\(stored), fresh=\(fresh)")
                check(f.capture.starts == 0 && f.capture.permissionRequests == 0 &&
                      !f.camera.isRunning && !f.coordinator.isBusy && !f.light.isOn &&
                      f.coordinator.coach.phase == .idle && !f.coordinator.trackingValid,
                      "Refreshing activation guidance starts no camera, permission request, light, or alignment")
                f.end()
            }
        }
        do {
            let f = CoordinatorFixture(stored: true)
            f.coordinator.cancelPendingRecovery()
            f.coordinator.setSessionActive(false)
            f.coordinator.setSessionActive(true)
            f.advance(0.8)
            await settle()
            check(f.capture.starts == 0 && f.capture.permissionRequests == 0 && !f.coordinator.isBusy,
                  "New activation guidance preserves an explicitly cancelled automatic recovery policy")
            f.end()
        }
        do {
            let f = CoordinatorFixture(enabled: false)
            f.coordinator.setSessionActive(false)
            f.coordinator.requestEnable(); await settle()
            check(!f.coordinator.isBusy && !f.coordinator.isEnabled &&
                  f.capture.permissionRequests == 0 && f.capture.starts == 0,
                  "Inactive permission enable stays idle without asking for permission or opening capture")
            check(f.coordinator.status.contains("Wake and unlock"),
                  "Inactive enable explains how to retry")
            f.coordinator.setSessionActive(true)
            f.coordinator.requestEnable(); await settle()
            check(f.coordinator.isEnabled && !f.coordinator.isBusy && f.capture.permissionRequests == 1,
                  "An explicit retry after activation can enable camera assistance")
            f.end()
        }
        for cancellation in ["disable", "sleep"] {
            let f = CoordinatorFixture(enabled: false)
            f.coordinator.requestEnable()
            if cancellation == "disable" { f.coordinator.disable() } else { f.coordinator.setSessionActive(false) }
            await settle()
            check(f.capture.permissionRequests == 0 && f.capture.starts == 0, "Queued permission cancels before entry")
            check(!f.coordinator.isBusy && !f.coordinator.isEnabled && f.coordinator.coach.phase == .idle, "Cancelled enable stays idle")
            f.end()
        }
        do {
            let f = CoordinatorFixture(enabled: false, stored: true, holdPermission: true)
            f.advance(0.8)
            f.coordinator.requestEnable()
            for _ in 0..<200 where f.capture.permissionContinuation == nil { await Task.yield() }
            check(f.capture.permissionRequests == 1 && f.capture.permissionContinuation != nil &&
                  f.coordinator.isBusy && f.capture.starts == 0,
                  "The late-permission regression enters and holds the actual permission provider before cancellation")
            // This is the real coordinator sequence used by Turn off feature:
            // cancel the pending intent, then keep the camera session inactive.
            f.coordinator.cancelPendingRecovery()
            f.coordinator.setSessionActive(false)
            check(!f.coordinator.isBusy && !f.coordinator.isEnabled && f.coordinator.coach.phase == .idle,
                  "Turning the feature off immediately clears pending permission UI and enable intent")
            f.capture.releasePermission(true)
            await settle()
            check(f.camera.authorization == .authorized && !f.coordinator.isEnabled &&
                  !f.defaults.bool(forKey: "cameraAssistance") && !f.coordinator.isBusy,
                  "A real late permission grant updates authorization without reviving cancelled camera assistance")
            check(f.capture.starts == 0 && !f.camera.isRunning && !f.light.isOn && f.coordinator.coach.phase == .idle,
                  "Late approval cannot open capture, illuminate the face, or show another camera check")
            f.advance(0.8)
            // Even later activation and a new wear event cannot recreate the
            // cancelled Enable intent merely because OS permission is granted.
            f.coordinator.setSessionActive(true)
            f.motion.removalEventCount += 1
            f.advance(0.8)
            await settle()
            check(f.capture.permissionRequests == 1 && f.capture.starts == 0 &&
                  !f.coordinator.isEnabled && !f.camera.isRunning && !f.coordinator.isBusy,
                  "Fresh motion and later active ticks do not restart a cancelled permission/Enable request")
            f.end()
        }
        do {
            let f = CoordinatorFixture(enabled: false)
            f.capture.permissionAllowed = false
            f.coordinator.requestEnable(); await settle()
            check(f.capture.permissionRequests == 1 && !f.coordinator.isEnabled, "Permission denial leaves assistance off")
            check(f.coordinator.coach.retryAction == .enableCamera && f.capture.starts == 0, "Permission denial offers the right retry")
            f.end()
        }
        do {
            let f = CoordinatorFixture()
            f.advance(0.8, yaw: 20)
            f.coordinator.setCenter(layoutKey: f.layout); await settle()
            f.advance(0.8, yaw: 20)
            f.frames(3, cameraYaw: 0, motionYaw: 20)
            check(f.coordinator.hasCenter && f.coordinator.trackingValid && close(f.coordinator.yawDegrees, 0), "First setup saves and aligns in one centered batch without a sign turn")
            check(f.capture.starts == 1 && !f.camera.isRunning && f.coordinator.coach.phase == .success, "One capture stops directly at actual success")
            let saved = f.defaults.data(forKey: "cameraScreenCenterV1")!
            let value = try JSONDecoder().decode(StoredCameraProbe.self, from: saved)
            check(value.center.mode == .facingCamera && value.center.neutralYawRadians == 0 && value.center.cameraSign == 0, "New reference explicitly records camera-facing zero and no inferred camera sign")
            f.advance(0.3, yaw: 35); await settle()
            check(close(f.coordinator.yawDegrees, 15) && f.capture.starts == 1, "AirPods turn remains fifteen degrees after success; no second check or zero shift")
            f.motion.removalEventCount += 1
            f.motion.isFresh = false; f.motion.fusionEpoch += 1; f.motion.fusionSample = nil
            check(!f.coordinator.trackingValid && f.coordinator.coach.phase == .idle, "Epoch loss immediately removes aligned success")
            f.coordinator.update(layoutKey: f.layout); f.motion.isFresh = true
            f.advance(0.8, yaw: -30); await settle()
            for yaw in [-15.0, 15.0] {
                f.frames(3, cameraYaw: yaw, motionYaw: -30)
                check(!f.coordinator.trackingValid && f.coordinator.coach.progress == 0, "Recovery cannot turn an off-axis pose into zero")
            }
            f.frames(3, cameraYaw: 0, motionYaw: -30)
            check(f.coordinator.trackingValid && close(f.coordinator.yawDegrees, 0) && f.capture.starts == 2, "Rewear uses one new center-facing capture in the new sensor epoch")
            check(f.defaults.data(forKey: "cameraScreenCenterV1") == saved && f.coordinator.centerRevision == 1, "Recovery preserves the durable facing-center reference")
            f.end()
        }
        for operation in ["center", "recovery"] {
            let f = CoordinatorFixture(stored: operation == "recovery")
            var accepted: [(camera: String, configuration: String, bounds: CGRect, captured: Double)] = []
            f.coordinator.onAcceptedFace = { camera, configuration, bounds, captured in
                accepted.append((camera, configuration, bounds, captured))
            }
            f.advance(0.8, yaw: 20)
            if operation == "center" { f.coordinator.setCenter(layoutKey: f.layout) }
            await settle(); f.advance(0.8, yaw: 20)
            for rejection in ["off-axis", "missing", "stale"] {
                f.frames(2, cameraYaw: 0, motionYaw: 20)
                if rejection == "off-axis" { f.frame(yaw: 15) }
                else if rejection == "missing" { f.frame(yaw: nil, faces: 0) }
                else {
                    f.capture.handlers.last?(CameraAnchorFrame(cameraID: f.capture.cameraID,
                        configurationID: f.capture.configurationID, faceCount: 1, yawDegrees: 0,
                        pitchDegrees: 0, rollDegrees: 0, detectionConfidence: 0.95,
                        faceBounds: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.5),
                        captureHostTime: f.time - 2, receiptHostTime: f.time - 1.9, processedHostTime: f.time))
                }
                f.advance(0.34, yaw: 20)
                check(accepted.isEmpty && !f.coordinator.trackingValid,
                      "A partial \(operation) followed by a \(rejection) frame cannot publish accepted seat geometry")
            }
            f.frames(2, cameraYaw: 0, motionYaw: 20)
            let acceptedBounds = CGRect(x: 0.31, y: 0.29, width: 0.27, height: 0.38)
            let acceptedTime = f.time
            f.frame(yaw: 0, bounds: acceptedBounds)
            f.advance(0.1, yaw: 20)
            // A newer unpaired frame must not replace the geometry belonging
            // to the earlier sample that actually completes the accepted batch.
            f.frame(yaw: 0, bounds: CGRect(x: 0.4, y: 0.35, width: 0.22, height: 0.3))
            f.advance(0.13, yaw: 20)
            check(accepted.count == 1 && f.coordinator.trackingValid && !f.camera.isRunning,
                  "Successful \(operation) publishes one accepted-face callback only")
            check(accepted[0].camera == f.capture.cameraID && accepted[0].configuration == f.capture.configurationID &&
                  accepted[0].bounds == acceptedBounds && accepted[0].captured == acceptedTime,
                  "Accepted \(operation) geometry uses the exact committed sample's camera, framing, bounds, and capture timestamp")
            f.frame(yaw: 0); f.advance(0.4, yaw: 20)
            check(accepted.count == 1, "Queued frames cannot publish more seat references after \(operation) completes")
            f.end()
        }
        do {
            let f = CoordinatorFixture()
            f.advance(0.8, yaw: 20); f.coordinator.setCenter(layoutKey: f.layout); await settle()
            let started = f.time
            for _ in 0..<8 {
                f.frame(yaw: 0); f.advance(0.34, yaw: 20)
                if f.coordinator.trackingValid { break }
            }
            check(f.coordinator.trackingValid && f.time - started <= 2 && f.capture.starts == 1,
                  "A continuous three-fps stream completes the full centered check within about two seconds without extra warmup or restart")
            f.end()
        }
        for yaw in [-15.0, -13.0, -5.1, 5.1, 13.0, 15.0] {
            let f = CoordinatorFixture()
            f.advance(0.8, yaw: 25); f.coordinator.setCenter(layoutKey: f.layout); await settle()
            f.advance(0.8, yaw: 25); f.frames(4, cameraYaw: yaw, motionYaw: 25)
            check(!f.coordinator.hasCenter && !f.coordinator.trackingValid && f.coordinator.coach.progress == 0, "Yaw outside five degrees never counts as center on either side")
            f.frames(3, cameraYaw: 0, motionYaw: 25)
            check(f.coordinator.trackingValid && f.capture.starts == 1, "Returning to real center completes the same check")
            f.end()
        }
        for yaw in [-5.0, 5.0] {
            let f = CoordinatorFixture()
            f.advance(0.8, yaw: 20); f.coordinator.setCenter(layoutKey: f.layout); await settle()
            f.advance(0.8, yaw: 20); f.frames(3, cameraYaw: yaw, motionYaw: 20)
            check(f.coordinator.trackingValid && close(f.coordinator.yawDegrees, 0), "The explicit inclusive five-degree tolerance works on either side")
            f.end()
        }
        do {
            let f = CoordinatorFixture(stored: true)
            f.advance(0.8, yaw: 8); await settle()
            f.frames(2, cameraYaw: 0, motionYaw: 8)
            check(f.coordinator.coach.progress > 0 && f.coordinator.coach.progress < 1, "Progress comes from the accepted paired capture span")
            f.frame(yaw: 13)
            check(f.coordinator.coach.progress == 0 && !f.coordinator.trackingValid, "Leaving the five-degree center immediately clears hold evidence")
            f.advance(0.34, yaw: 8); f.frames(1, cameraYaw: 0, motionYaw: 8)
            check(!f.coordinator.trackingValid, "Old centered samples cannot bridge an off-center excursion")
            f.frames(2, cameraYaw: 0, motionYaw: 8)
            check(f.coordinator.trackingValid, "Three fresh centered samples finish the same stream")
            f.end()
        }
        do {
            let f = CoordinatorFixture(stored: true)
            f.advance(0.8, yaw: 8); await settle()
            for index in 0..<3 {
                let captureTime = f.time
                f.frame(yaw: 0); f.advance(0.18, yaw: 8)
                f.time = captureTime + 0.21; f.coordinator.update(layoutKey: f.layout)
                check(!f.coordinator.trackingValid, "UI time alone cannot stand in for actual post-capture motion")
                if index == 2 { check(f.coordinator.coach.progress > 0, "Waiting for a motion callback retains prior centered evidence") }
                f.advance(0.13, yaw: 8)
            }
            check(f.coordinator.trackingValid && f.capture.starts == 1, "Independent timer and AirPods callbacks complete one centered check")
            f.end()
        }
        do {
            let f = CoordinatorFixture(stored: true)
            f.advance(0.8, yaw: 8); await settle(); f.frames(2, cameraYaw: 0, motionYaw: 8)
            f.frame(yaw: 0); f.advance(0.08, yaw: 12, angularSpeed: 0.3); f.advance(0.26, yaw: 8)
            check(!f.coordinator.trackingValid && f.coordinator.coach.progress == 0, "Real motion resets the centered hold even while camera yaw appears zero")
            f.advance(0.8, yaw: 8); f.frames(1, cameraYaw: 0, motionYaw: 8)
            check(!f.coordinator.trackingValid, "Old stationary frames cannot bridge movement")
            f.frames(2, cameraYaw: 0, motionYaw: 8)
            check(f.coordinator.trackingValid, "A fresh stationary centered batch recovers after movement")
            f.end()
        }
        do {
            let f = CoordinatorFixture(stored: true, legacy: true)
            let old = f.defaults.data(forKey: "cameraScreenCenterV1")
            f.advance(1, yaw: 25); await settle()
            check(!f.coordinator.hasCenter && f.capture.starts == 0 && !f.coordinator.trackingValid, "Legacy arbitrary-neutral records cannot auto-recover as dead center")
            check(f.defaults.data(forKey: "cameraScreenCenterV1") == old, "Legacy data is not migrated without deliberate Set center")
            check(f.coordinator.visualCameraSign(cameraID: "builtin-test", configurationID: "vision3-up-unmirrored-vga") == -1, "A matching learned legacy sign remains available for visuals only")
            check(f.coordinator.visualCameraSign(cameraID: "wrong", configurationID: "vision3-up-unmirrored-vga") == nil, "Visual sign does not transfer between cameras")
            f.coordinator.setCenter(layoutKey: f.layout); await settle()
            f.advance(0.8, yaw: 25); f.frames(3, cameraYaw: 15, motionYaw: 25)
            check(!f.coordinator.hasCenter && f.defaults.data(forKey: "cameraScreenCenterV1") == old, "The previous fifteen-degree neutral cannot pass the new center gate")
            f.frames(3, cameraYaw: 0, motionYaw: 25)
            let value = try JSONDecoder().decode(StoredCameraProbe.self, from: f.defaults.data(forKey: "cameraScreenCenterV1")!)
            check(f.coordinator.trackingValid && value.center.mode == .facingCamera && value.center.neutralYawRadians == 0 && value.visualCameraSign == -1, "Explicit centered success migrates the reference atomically and preserves matched visual metadata")
            f.end()
        }
        do {
            let f = CoordinatorFixture(stored: true)
            let old = f.defaults.data(forKey: "cameraScreenCenterV1")
            f.layout = "display-B"; f.advance(0.8, yaw: 20); await settle()
            check(f.capture.starts == 0 && f.defaults.data(forKey: "cameraScreenCenterV1") == old, "Changed layout blocks automatic reference replacement")
            f.coordinator.setCenter(layoutKey: f.layout); await settle()
            f.advance(0.8, yaw: 20); f.frames(3, cameraYaw: 0, motionYaw: 20)
            let value = try JSONDecoder().decode(StoredCameraProbe.self, from: f.defaults.data(forKey: "cameraScreenCenterV1")!)
            check(f.coordinator.trackingValid && value.layoutKey == "display-B" && value.center.revision == 6 && f.capture.starts == 1, "Deliberate setup on a changed display uses one centered check")
            f.end()
        }
        for mismatch in ["camera", "configuration"] {
            let f = CoordinatorFixture(stored: true)
            if mismatch == "camera" { f.capture.cameraID = "different" } else { f.capture.configurationID = "different" }
            f.advance(0.8, yaw: 8); await settle(); f.frame(yaw: 0)
            check(f.coordinator.coach.phase == .failure && f.coordinator.coach.retryAction == .setCenter && !f.camera.isRunning, "Recovery cannot reuse a reference for a changed camera pipeline")
            f.coordinator.setCenter(layoutKey: f.layout); await settle()
            f.advance(0.8, yaw: 8); f.frames(3, cameraYaw: 0, motionYaw: 8)
            check(f.coordinator.trackingValid && f.coordinator.centerRevision == 6, "A new camera pipeline can be deliberately centered without a sign-learning turn")
            f.end()
        }
        for cancellation in ["manual", "epoch", "layout", "sleep"] {
            let f = CoordinatorFixture(stored: true)
            f.advance(0.8, yaw: 8); await settle(); f.frames(2, cameraYaw: 0, motionYaw: 8)
            let handler = f.capture.handlers.count - 1
            switch cancellation {
            case "manual": f.coordinator.cancelPendingRecovery()
            case "epoch": f.motion.isFresh = false; f.motion.fusionEpoch += 1; f.motion.fusionSample = nil; f.coordinator.update(layoutKey: f.layout)
            case "layout": f.layout = "display-B"; f.coordinator.update(layoutKey: f.layout)
            default: f.coordinator.setSessionActive(false)
            }
            f.frame(yaw: 0, handler: handler); f.advance(0.4, yaw: 8)
            check(!f.coordinator.trackingValid && !f.camera.isRunning && f.coordinator.centerRevision == 5, "Cancellation prevents late centered evidence from committing")
            check(f.coordinator.coach.progress == 0 && f.coordinator.coach.phase != .success, "Cancellation clears centered progress")
            f.end()
        }
        for obstacle in ["face", "motion", "framing"] {
            let f = CoordinatorFixture(stored: true)
            f.advance(0.8, yaw: 8); await settle()
            if obstacle == "face" { f.frame(yaw: nil, faces: 0) }
            else if obstacle == "framing" { f.frame(yaw: 0, bounds: CGRect(x: 0.45, y: 0.45, width: 0.08, height: 0.08)) }
            else { f.frame(yaw: 0); f.advance(0.08, yaw: 12, angularSpeed: 0.3); f.advance(0.26, yaw: 8) }
            let reason = f.coordinator.coach.detail
            f.camera.stop(); f.coordinator.update(layoutKey: f.layout)
            check(f.coordinator.coach.phase == .failure && f.coordinator.coach.detail.contains(reason) && f.coordinator.coach.retryAction == .refreshDirection, "Timeout retains the current obstacle and retry")
            f.coordinator.refreshDirection(); await settle(); f.advance(0.8, yaw: 8)
            f.frame(yaw: 0)
            check(f.coordinator.status == f.coordinator.coach.title + ". " + f.coordinator.coach.detail, "A valid frame clears stale status consistently")
            f.end()
        }
        do {
            let f = CoordinatorFixture(stored: true)
            f.capture.holdStart = true
            f.advance(0.8, yaw: 8); await settle()
            f.camera.stop(); f.coordinator.update(layoutKey: f.layout)
            f.capture.releaseStart(); await settle()
            check(!f.coordinator.trackingValid && !f.coordinator.isBusy && !f.camera.isRunning, "Late startup cannot resurrect a timed-out centered check")
            f.end()
        }
        do {
            let f = CoordinatorFixture(stored: true)
            f.advance(0.8, yaw: 20); await settle(); f.advance(0.8, yaw: 20)
            f.coordinator.toggleAssistLight()
            check(!f.light.isOn, "Light cannot turn on before measured low-light evidence")
            f.frame(yaw: nil, faces: 0, luminance: 0.01); f.advance(0.34, yaw: 20)
            f.frame(yaw: nil, faces: 0, luminance: 0.01)
            check(f.coordinator.coach.issue == .faceMissing && f.coordinator.coach.phase != .lighting,
                  "Repeated darkness without a face keeps the camera card and cannot offer a light")
            f.frame(yaw: 22, luminance: 0.01); f.advance(0.34, yaw: 20)
            f.frame(yaw: 22, luminance: 0.01)
            check(f.coordinator.coach.issue == .pose && !f.coordinator.coach.needsLightHelp,
                  "A visible twenty-two-degree turn never prompts lighting instead of center")
            f.frame(yaw: nil, luminance: 0.05)
            check(f.coordinator.coach.phase == .seeking && !f.coordinator.coach.needsLightHelp,
                  "One underexposed frame cannot flash a light card")
            f.advance(0.34, yaw: 20); f.frame(yaw: nil, luminance: 0.05)
            check(f.coordinator.coach.phase == .seeking && f.light.isOn,
                  "Two distinct close-face low-light failures automatically illuminate the screen edge")
            let starts = f.capture.starts, saved = f.defaults.data(forKey: "cameraScreenCenterV1")
            check(f.light.isOn && f.coordinator.coach.isAssistLightOn && f.coordinator.coach.phase == .seeking,
                  "Automatic light keeps the same camera check in face detection")
            check(f.capture.starts == starts && !f.coordinator.trackingValid && f.coordinator.coach.progress == 0,
                  "Light-on neither starts a second check nor grants calibration")
            f.advance(0.34, yaw: 20); f.frame(yaw: nil, luminance: 0.05)
            f.advance(0.34, yaw: 20); f.frame(yaw: nil, luminance: 0.05)
            check(f.coordinator.coach.phase == .seeking && f.light.isOn,
                  "Light already on does not loop back to its offer card")
            f.frames(3, cameraYaw: 0, motionYaw: 20)
            check(f.coordinator.trackingValid && f.coordinator.coach.phase == .success && !f.light.isOn && !f.camera.isRunning,
                  "The same one-pass evidence finishes recovery and turns camera plus light off")
            check(f.defaults.data(forKey: "cameraScreenCenterV1") == saved && f.capture.starts == starts,
                  "Illumination leaves the saved center and one-check count intact")
            f.end()
        }
        do {
            let f = CoordinatorFixture(stored: true)
            f.advance(0.8); await settle(); f.advance(0.8)
            f.frame(yaw: nil, luminance: 0.05)
            f.frame(yaw: nil, luminance: 0.05)
            check(!f.light.isOn, "Repeating one captured frame cannot activate illumination")
            f.advance(0.34); f.frame(yaw: nil, luminance: 0.05)
            check(f.light.isOn, "Distinct low-light evidence activates the light")
            f.coordinator.toggleAssistLight()
            for _ in 0..<5 { f.advance(0.34); f.frame(yaw: nil, luminance: 0.05) }
            check(!f.light.isOn, "Manual Off survives continuing darkness for this entire check")
            f.coordinator.refreshDirection(); await settle(); f.advance(0.8)
            f.frame(yaw: nil, luminance: 0.05); f.advance(0.34); f.frame(yaw: nil, luminance: 0.05)
            check(f.light.isOn, "A new explicit camera check may evaluate its own light need")
            f.end()
        }
        for cancellation in ["manual", "sleep", "disable", "face-left", "stale", "failure"] {
            let f = CoordinatorFixture(stored: true)
            f.advance(0.8, yaw: 8); await settle(); f.advance(0.8, yaw: 8)
            f.frame(yaw: nil, luminance: 0.05); f.advance(0.34, yaw: 8); f.frame(yaw: nil, luminance: 0.05)
            check(f.light.isOn, "Fixture begins with camera-triggered face light")
            switch cancellation {
            case "manual": f.coordinator.cancelPendingRecovery()
            case "sleep": f.coordinator.setSessionActive(false)
            case "disable": f.coordinator.disable()
            case "face-left": f.frame(yaw: nil, faces: 0); f.advance(0.34, yaw: 8); f.frame(yaw: nil, faces: 0)
            case "stale": f.advance(0.9, yaw: 8)
            default: f.camera.stop(); f.coordinator.update(layoutKey: f.layout)
            }
            check(!f.light.isOn && !f.coordinator.coach.isAssistLightOn,
                  "\(cancellation) cannot leave the face light on")
            f.end()
        }
        do {
            let f = CoordinatorFixture(stored: true)
            f.advance(0.8, yaw: 8); await settle(); f.advance(0.8, yaw: 8); f.frames(3, cameraYaw: 0, motionYaw: 8)
            let saved = f.defaults.data(forKey: "cameraScreenCenterV1"), starts = f.capture.starts
            f.advance(0.2, yaw: 28); f.coordinator.resumeTracking(); await settle()
            check(f.coordinator.trackingValid && close(f.coordinator.yawDegrees, 20) && f.capture.starts == starts,
                  "Enable preserves a valid twenty-degree turn without a second center check")
            f.motion.fusionSample = nil
            f.advance(0.02, yaw: 28); await settle()
            check(f.capture.starts == starts,
                  "Idle motion loss never starts an unsolicited camera recovery")
            f.camera.stop(); f.coordinator.update(layoutKey: f.layout)
            f.advance(2, yaw: 28); await settle()
            check(f.capture.starts == starts,
                  "An idle tracking gap cannot become an endless camera loop")
            f.coordinator.cancelPendingRecovery()
            f.coordinator.resumeTracking(); await settle()
            check(f.capture.starts == starts + 1,
                  "Explicit Enable rearms a paused saved-reference recovery")
            f.coordinator.resumeTracking(); await settle()
            check(f.capture.starts == starts + 1, "Enable during the active recovery does not restart it")
            f.advance(0.8, yaw: 8); f.frames(3, cameraYaw: 0, motionYaw: 8)
            check(f.coordinator.trackingValid && f.defaults.data(forKey: "cameraScreenCenterV1") == saved,
                  "Enable recovery leaves the durable center unchanged")
            f.end()
        }
        do {
            let f = CoordinatorFixture(stored: true)
            f.advance(0.8); await settle()
            let starts = f.capture.starts
            for _ in 0..<20 {
                f.motion.isFresh = false; f.motion.fusionEpoch += 1; f.motion.fusionSample = nil
                f.coordinator.update(layoutKey: f.layout)
                f.motion.isFresh = true; f.advance(0.8); await settle()
            }
            check(f.capture.starts == starts && !f.camera.isRunning,
                  "Twenty idle or handoff epochs cannot restart an interrupted camera check")
            f.motion.removalEventCount += 1
            f.advance(0.1); await settle()
            check(f.capture.starts == starts + 1, "Confirmed ear return permits one recovery after idle")
            f.end()
        }
        for cancelled in [false, true] {
            let f = CoordinatorFixture(stored: true)
            f.advance(0.8); await settle(); f.advance(0.8); f.frames(3, cameraYaw: 0, motionYaw: 0)
            let starts = f.capture.starts
            let saved = f.defaults.data(forKey: "cameraScreenCenterV1")
            f.motion.disconnectEventCount += 1; f.motion.connectionState = .disconnected
            f.motion.isFresh = false; f.motion.fusionSample = nil; f.coordinator.update(layoutKey: f.layout)
            f.time += 2
            f.motion.connectionState = .connected; f.motion.isFresh = true
            f.advance(0.8); await settle()
            check(f.capture.starts == starts,
                  "A raw disconnect, sample gap, or source epoch without a removal session cannot open another camera check")
            f.motion.removalEventCount += 1; f.motion.removalConnectionState = .disconnected
            f.motion.isFresh = false; f.coordinator.update(layoutKey: f.layout)
            if cancelled { f.coordinator.cancelPendingRecovery() }
            f.motion.removalConnectionState = .connected; f.motion.isFresh = true
            f.advance(0.8); await settle()
            check(f.capture.starts == starts + (cancelled ? 0 : 1),
                  "A completed both-out session rearms exactly one direction check unless explicitly cancelled")
            if !cancelled {
                f.advance(0.8); f.frames(3, cameraYaw: 0, motionYaw: 0)
                check(f.coordinator.trackingValid && f.defaults.data(forKey: "cameraScreenCenterV1") == saved,
                      "Return measurement preserves the saved screen center")
                f.advance(1); await settle()
                check(f.capture.starts == starts + 1, "The same return session cannot repeat the camera check")
            }
            f.end()
        }
        print("PASS: \(checks) centered coordinator/service/fusion checks; injected inputs, no hardware access")
    }
}
