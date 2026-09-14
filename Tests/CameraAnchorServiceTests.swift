import Foundation
import CoreGraphics
import CoreVideo

@MainActor private final class FakeCameraCapture: CameraAnchorCapturing {
    var authorization = CameraAuthorization.authorized
    var permissionRequests = 0
    var starts = 0
    var stops = 0
    var holdStart = false
    var holdStop = false
    var stopWaits = 0
    var stopContinuations: [CheckedContinuation<Void, Never>] = []
    var continuation: CheckedContinuation<CameraAnchorConfiguration, Error>?
    var frameHandlers: [@MainActor (CameraAnchorFrame) -> Void] = []
    var previewHandlers: [@MainActor (CGImage) -> Void] = []
    var failureHandlers: [@MainActor (String) -> Void] = []
    var configuration = CameraAnchorConfiguration(cameraID: "fake-camera", cameraName: "Fake",
        configurationID: "vision3-up-unmirrored", captureFramesPerSecond: 3)
    func requestPermission() async -> Bool {
        permissionRequests += 1; authorization = .authorized; return true
    }
    func start(onFrame: @escaping @MainActor (CameraAnchorFrame) -> Void,
               onPreview: @escaping @MainActor (CGImage) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) async throws -> CameraAnchorConfiguration {
        starts += 1; frameHandlers.append(onFrame); previewHandlers.append(onPreview); failureHandlers.append(onFailure)
        if holdStart { return try await withCheckedThrowingContinuation { continuation = $0 } }
        return configuration
    }
    func releaseStart() { continuation?.resume(returning: configuration); continuation = nil }
    func stop() { stops += 1 }
    func waitUntilStopped() async {
        stopWaits += 1
        if holdStop { await withCheckedContinuation { stopContinuations.append($0) } }
    }
    func releaseStop() {
        holdStop = false
        let waiting = stopContinuations; stopContinuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }
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
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let thumbnail = context.makeImage()!
        do {
            let newerContext = CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let newerThumbnail = newerContext.makeImage()!
            let mailbox = CameraPreviewMailbox()
            check(mailbox.offer(thumbnail), "First preview schedules one main-actor delivery")
            var extraNotifications = 0
            for _ in 0..<100 {
                if mailbox.offer(newerThumbnail) { extraNotifications += 1 }
            }
            check(extraNotifications == 0, "Blocked UI accumulates no extra preview delivery tasks")
            check(mailbox.take()?.width == 3, "Pending delivery consumes the newest thumbnail, not the first queued image")
            check(mailbox.take() == nil, "A thumbnail is consumed only once")
            check(mailbox.offer(thumbnail), "A drained mailbox permits the next delivery notification")
            mailbox.cancel()
            check(mailbox.take() == nil, "Stop discards a queued preview before its callback runs")
            check(!mailbox.offer(newerThumbnail), "A late producer cannot revive a cancelled capture run")
            let nextRun = CameraPreviewMailbox()
            check(nextRun.offer(newerThumbnail) && nextRun.take()?.width == 3,
                  "A new capture run owns independent preview delivery state")
            check(mailbox.take() == nil, "An obsolete callback cannot consume the new run's image")
        }
        do {
            let capture = FakeCameraCapture()
            var effectsOpened = 0
            let service = CameraAnchorService(capture: capture, showVideoEffects: { effectsOpened += 1 })
            service.openEdgeLightControls()
            check(!service.canOpenEdgeLightControls && effectsOpened == 0, "Camera-off state cannot open system effects")
            try await service.startBurst { _ in }
            service.openEdgeLightControls()
            check(!service.canOpenEdgeLightControls && effectsOpened == 0, "Unsupported camera format cannot open Edge Light controls")
            service.stop()
            capture.configuration.supportsEdgeLight = true
            try await service.startBurst { _ in }
            check(service.canOpenEdgeLightControls, "Supported active camera exposes Apple's Edge Light controls")
            service.openEdgeLightControls()
            check(effectsOpened == 1 && capture.starts == 2, "Explicit action opens system effects without starting another capture")
            service.stop()
            service.openEdgeLightControls()
            check(!service.canOpenEdgeLightControls && effectsOpened == 1, "Retained configuration cannot open effects after camera stop")
            capture.holdStart = true
            let starting = Task { try await service.startBurst { _ in } }
            await settle()
            service.openEdgeLightControls()
            check(service.isRunning && !service.canOpenEdgeLightControls && effectsOpened == 1,
                  "A previous supported format does not expose effects during pending startup")
            capture.releaseStart()
            try await starting.value
            check(service.canOpenEdgeLightControls, "Current startup must complete before its effects action becomes available")
            capture.failureHandlers.last?("interrupted")
            service.openEdgeLightControls()
            check(!service.canOpenEdgeLightControls && effectsOpened == 1, "Interrupted capture cannot open system effects")
        }
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
            capture.previewHandlers[0](thumbnail)
            check(tested.previewImage != nil, "Active capture provides its ephemeral preview through the same session")
            capture.frameHandlers[0](frame)
            check(received == [-35], "Vision turned angle is forwarded without recentering or sign guessing")
            tested.stop()
            check(tested.previewImage == nil, "Stop discards the preview immediately")
            capture.frameHandlers[0](frame)
            capture.previewHandlers[0](thumbnail)
            check(tested.previewImage == nil, "Late preview from a stopped capture cannot reappear")
            check(received.count == 1 && !tested.isRunning, "Stop rejects queued old frames")
            try await tested.startBurst { sample in received.append(sample.yawDegrees!) }
            capture.failureHandlers[0]("obsolete failure")
            capture.frameHandlers[0](frame)
            capture.previewHandlers[0](thumbnail)
            check(tested.isRunning && received.count == 1, "Old run cannot cancel or feed a new run")
            check(tested.previewImage == nil, "New run cannot display a queued preview from the old generation")
            capture.previewHandlers[1](thumbnail)
            check(tested.previewImage != nil && capture.starts == 2, "Current generation preview uses no additional camera start")
            capture.frameHandlers[1](frame)
            check(received.count == 2, "New run accepts its own frames")
            capture.failureHandlers[1]("unplugged")
            check(!tested.isRunning && tested.status.contains("unplugged"), "Runtime interruption stops current capture")
            check(tested.previewImage == nil, "Interruption clears the live preview")
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
            let capture = FakeCameraCapture()
            let service = CameraAnchorService(capture: capture)
            var frames = 0
            try await service.startBurst { _ in frames += 1 }
            capture.holdStop = true
            service.stop()
            var firstFinished = false, secondFinished = false
            let first = Task { await service.waitUntilStopped(); firstFinished = true }
            let second = Task { await service.waitUntilStopped(); secondFinished = true }
            await settle()
            check(!service.isRunning && capture.stopWaits == 2 && !firstFinished && !secondFinished,
                  "Camera-off publication does not bypass the capture implementation's physical-stop barrier")
            capture.frameHandlers[0](frame); capture.previewHandlers[0](thumbnail)
            check(frames == 0 && service.previewImage == nil,
                  "Old camera frames and previews stay cancelled while physical teardown is still pending")
            capture.releaseStop(); await first.value; await second.value
            check(firstFinished && secondFinished,
                  "All ownership-handoff waiters resume after the capture queue reports actual release")
            await service.waitUntilStopped()
            check(capture.stopWaits == 3, "An already released capture still fulfills the explicit handoff contract")
        }
        do {
            let capture = FakeCameraCapture(); capture.holdStart = true
            let service = CameraAnchorService(capture: capture)
            let startup = Task { try await service.startBurst { _ in fatalError("Cancelled start delivered a frame") } }
            await settle(); capture.holdStop = true; service.stop()
            var released = false
            let handoff = Task { await service.waitUntilStopped(); released = true }
            await settle(); capture.releaseStart()
            do { try await startup.value; fatalError("Cancelled startup became active") } catch CameraAnchorError.cancelled {}
            check(!released && !service.isRunning,
                  "Late startup cancellation does not falsely complete the independent camera-release barrier")
            capture.releaseStop(); await handoff.value
            check(released, "Startup-cancelled capture hands ownership over only after physical stop completion")
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
        for (pixelValue, expected) in [(UInt8(0), 0.0), (UInt8(128), 128.0 / 255), (UInt8(255), 1.0)] {
            var pixels: CVPixelBuffer?
            check(CVPixelBufferCreate(kCFAllocatorDefault, 32, 24, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                nil, &pixels) == kCVReturnSuccess, "Synthetic luma plane allocated")
            let buffer = pixels!
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!, Int32(pixelValue),
                CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * CVPixelBufferGetHeightOfPlane(buffer, 0))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            check(abs(CameraLuminance.mean(buffer)! - expected) < 0.001,
                  "Brightness is measured from pixel luma rather than inferred from missing faces")
        }
        print("PASS: \(checks) CameraAnchorService lifecycle checks with injected camera; no hardware or permission access")
    }
}
