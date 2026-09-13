import Foundation

@MainActor private final class FakeCameraCapture: CameraAnchorCapturing {
    var authorization = CameraAuthorization.authorized
    var permissionRequests = 0
    var starts = 0
    var stops = 0
    var holdStart = false
    var continuation: CheckedContinuation<CameraAnchorConfiguration, Error>?
    var frameHandlers: [@MainActor (CameraAnchorFrame) -> Void] = []
    var failureHandlers: [@MainActor (String) -> Void] = []
    let configuration = CameraAnchorConfiguration(cameraID: "fake-camera", cameraName: "Fake",
        configurationID: "vision3-up-unmirrored", captureFramesPerSecond: 3)
    func requestPermission() async -> Bool {
        permissionRequests += 1; authorization = .authorized; return true
    }
    func start(onFrame: @escaping @MainActor (CameraAnchorFrame) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) async throws -> CameraAnchorConfiguration {
        starts += 1; frameHandlers.append(onFrame); failureHandlers.append(onFailure)
        if holdStart { return try await withCheckedThrowingContinuation { continuation = $0 } }
        return configuration
    }
    func releaseStart() { continuation?.resume(returning: configuration); continuation = nil }
    func stop() { stops += 1 }
}

@main struct CameraAnchorServiceTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { fatalError(message) }
        }
        func settle() async { for _ in 0..<20 { await Task.yield() } }
        let frame = CameraAnchorFrame(cameraID: "fake-camera", configurationID: "vision3-up-unmirrored",
            faceCount: 1, yawDegrees: -35, pitchDegrees: 0, rollDegrees: 0,
            detectionConfidence: 0.9, faceBounds: CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3),
            captureHostTime: 10, receiptHostTime: 10.01, processedHostTime: 10.03)
        do {
            let capture = FakeCameraCapture(); capture.authorization = .notDetermined
            let service = CameraAnchorService(capture: capture)
            do { try await service.startBurst { _ in }; fatalError("Unapproved capture started") }
            catch CameraAnchorError.permissionRequired {}
            check(capture.starts == 0 && capture.permissionRequests == 0, "Burst cannot request permission implicitly")
            check(!service.isRunning, "Denied startup stays inactive")
            let granted = await service.requestPermission()
            check(granted, "Explicit permission action succeeds")
            check(capture.permissionRequests == 1 && capture.starts == 0, "Permission never automatically starts capture")
        }
        do {
            let capture = FakeCameraCapture()
            let tested = CameraAnchorService(capture: capture)
            var received: [Double] = []
            try await tested.startBurst { sample in received.append(sample.yawDegrees!) }
            check(tested.isRunning && tested.deviceID == "fake-camera", "Configured identity is published")
            capture.frameHandlers[0](frame)
            check(received == [-35], "Vision turned angle is forwarded without recentering or sign guessing")
            tested.stop()
            capture.frameHandlers[0](frame)
            check(received.count == 1 && !tested.isRunning, "Stop rejects queued old frames")
            try await tested.startBurst { sample in received.append(sample.yawDegrees!) }
            capture.failureHandlers[0]("obsolete failure")
            capture.frameHandlers[0](frame)
            check(tested.isRunning && received.count == 1, "Old run cannot cancel or feed a new run")
            capture.frameHandlers[1](frame)
            check(received.count == 2, "New run accepts its own frames")
            capture.failureHandlers[1]("unplugged")
            check(!tested.isRunning && tested.status.contains("unplugged"), "Runtime interruption stops current capture")
        }
        do {
            let capture = FakeCameraCapture(); capture.holdStart = true
            let service = CameraAnchorService(capture: capture)
            let task = Task { try await service.startBurst { _ in fatalError("Cancelled startup delivered a frame") } }
            await settle()
            check(capture.starts == 1, "Fake startup reached suspended boundary")
            service.stop(); capture.releaseStart()
            do { try await task.value; fatalError("Stopped startup completed successfully") }
            catch CameraAnchorError.cancelled {}
            check(!service.isRunning && service.configuration == nil, "Post-await guard prevents cancelled startup publication")
        }
        do {
            let capture = FakeCameraCapture(); capture.holdStart = true
            let service = CameraAnchorService(capture: capture)
            let task = Task { try await service.startBurst(maxDuration: 0.03) { _ in fatalError("Timed out run delivered a frame") } }
            await settle()
            try await Task.sleep(nanoseconds: 80_000_000)
            check(!service.isRunning && capture.starts == 1, "Timeout covers startup and never renews capture")
            capture.releaseStart()
            do { try await task.value; fatalError("Timed out startup completed successfully") }
            catch CameraAnchorError.cancelled {}
            check(service.configuration == nil, "Timed out startup cannot publish a camera configuration")
        }
        print("PASS: \(checks) CameraAnchorService lifecycle checks with injected camera; no hardware or permission access")
    }
}
