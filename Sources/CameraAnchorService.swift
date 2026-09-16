import Foundation
import Combine
import AVFoundation
import Vision
import ImageIO
import CoreImage

enum CameraAuthorization: String, Sendable { case notDetermined, authorized, denied, restricted }

struct CameraAnchorConfiguration: Sendable, Equatable {
    let cameraID: String
    let cameraName: String
    let configurationID: String
    let captureFramesPerSecond: Double
    var supportsEdgeLight = false
}

/// Angles retain Vision's image-space sign. Physical-left conversion belongs
/// to the explicitly observed sign calibration, never to a guessed convention.
struct CameraAnchorFrame: Sendable {
    let cameraID: String
    let configurationID: String
    let faceCount: Int
    let yawDegrees: Double?
    let pitchDegrees: Double?
    let rollDegrees: Double?
    let detectionConfidence: Float
    let faceBounds: CGRect?
    let captureHostTime: TimeInterval?
    let receiptHostTime: TimeInterval
    let processedHostTime: TimeInterval
    /// Mean luminance inside the detected face, excluding surrounding background.
    var luminance: Double? = nil
    /// Image brightness in the central search area; never evidence of presence.
    var centerLuminance: Double? = nil
}

enum CameraAnchorError: LocalizedError {
    case permissionRequired, noBuiltInCamera, unsupportedConfiguration, cancelled, failed(String)
    var errorDescription: String? {
        switch self {
        case .permissionRequired: return "Allow camera access using the camera setup button first."
        case .noBuiltInCamera: return "No built-in Mac camera is available."
        case .unsupportedConfiguration: return "The built-in camera cannot provide the required capture configuration."
        case .cancelled: return "Camera check cancelled."
        case .failed(let detail): return "Camera check failed: \(detail)"
        }
    }
}

@MainActor protocol CameraAnchorCapturing: AnyObject {
    var authorization: CameraAuthorization { get }
    func requestPermission() async -> Bool
    func start(onFrame: @escaping @MainActor (CameraAnchorFrame) -> Void,
               onPreview: @escaping @MainActor (CGImage) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) async throws -> CameraAnchorConfiguration
    func stop()
    func waitUntilStopped() async
}

extension CameraAnchorCapturing {
    func waitUntilStopped() async {}
}

/// Camera acquisition only: no center changes, reference persistence, images
/// on disk, microphone, network, or automatic permission requests.
@MainActor final class CameraAnchorService: ObservableObject {
    @Published private(set) var status = "Camera is off."
    @Published private(set) var isRunning = false
    @Published private(set) var authorization: CameraAuthorization
    @Published private(set) var configuration: CameraAnchorConfiguration?
    /// Unmirrored ephemeral thumbnail; the notch mirrors it for the wearer.
    @Published private(set) var previewImage: CGImage?
    var deviceID: String? { configuration?.cameraID }
    var canOpenEdgeLightControls: Bool {
        isRunning && captureReady && configuration?.supportsEdgeLight == true
    }
    private let capture: any CameraAnchorCapturing
    @Published private(set) var isAssistLightOn = false
    private let faceLight: any FaceLighting
    private let showVideoEffects: () -> Void
    private var captureReady = false
    private var generation: UInt64 = 0
    private var timeout: Task<Void, Never>?

    convenience init() { self.init(capture: SystemCameraAnchorCapture()) }
    init(capture: any CameraAnchorCapturing,
         faceLight: (any FaceLighting)? = nil,
         showVideoEffects: @escaping () -> Void = { AVCaptureDevice.showSystemUserInterface(.videoEffects) }) {
        self.capture = capture
        self.faceLight = faceLight ?? FaceLightService()
        self.showVideoEffects = showVideoEffects
        authorization = capture.authorization
    }

    func refreshAuthorization() { authorization = capture.authorization }

    /// Opens Apple's controls for the active capture. Edge Light has no public
    /// setter; the wearer chooses it in the system's Video Effects interface.
    func openEdgeLightControls() {
        guard canOpenEdgeLightControls else { return }
        showVideoEffects()
    }

    /// This controls AirVeil's own face light, not Apple's Edge Light setting.
    /// Only an explicit action during an active capture may turn it on.
    @discardableResult func setAssistLightEnabled(_ enabled: Bool) -> Bool {
        if enabled && (!isRunning || !captureReady) { return false }
        let changed = faceLight.setEnabled(enabled)
        isAssistLightOn = faceLight.isOn
        return changed
    }

    /// Call only from an explicit permission/setup action. This never starts capture.
    func requestPermission() async -> Bool {
        let granted = await capture.requestPermission()
        refreshAuthorization()
        return granted
    }

    /// Timeout includes startup and never renews itself. The consumer calls
    /// stop as soon as an accepted anchor or cancellation ends the attempt.
    func startBurst(maxDuration: TimeInterval = 12,
                    onFrame: @escaping @MainActor (CameraAnchorFrame) -> Void) async throws {
        stop()
        refreshAuthorization()
        guard authorization == .authorized else { throw CameraAnchorError.permissionRequired }
        guard maxDuration.isFinite, maxDuration > 0 else { throw CameraAnchorError.unsupportedConfiguration }
        generation &+= 1
        let run = generation
        isRunning = true
        status = "Starting a brief camera check…"
        let duration = min(maxDuration, 20)
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000)) }
            catch { return }
            guard let self, self.generation == run else { return }
            self.stop()
            self.status = "Camera check ended. Camera is off; no direction was assumed."
        }
        do {
            let result = try await capture.start(onFrame: { [weak self] frame in
                guard let self, self.generation == run, self.isRunning else { return }
                onFrame(frame)
            }, onPreview: { [weak self] image in
                guard let self, self.generation == run, self.isRunning else { return }
                self.previewImage = image
            }, onFailure: { [weak self] detail in
                guard let self, self.generation == run else { return }
                self.stop()
                self.status = "Camera stopped: \(detail)"
            })
            guard generation == run, isRunning, !Task.isCancelled else { throw CameraAnchorError.cancelled }
            configuration = result
            captureReady = true
            status = "Brief camera check active. Images are processed locally and discarded."
        } catch {
            if generation == run { stop(); status = error.localizedDescription }
            throw error
        }
    }

    func stop() {
        setAssistLightEnabled(false)
        generation &+= 1
        timeout?.cancel(); timeout = nil
        isRunning = false
        captureReady = false
        previewImage = nil
        capture.stop()
        status = "Camera is off."
    }

    /// Camera ownership can pass to presence detection only after capture has
    /// actually stopped on its acquisition queue.
    func waitUntilStopped() async { await capture.waitUntilStopped() }
}

@MainActor private final class SystemCameraAnchorCapture: CameraAnchorCapturing {
    private var worker: CameraAnchorWorker?
    private var previewMailbox: CameraPreviewMailbox?
    private var pendingStop: Task<Void, Never>?
    private var captureGeneration: UInt64 = 0
    var authorization: CameraAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
    }
    func requestPermission() async -> Bool {
        if authorization != .notDetermined { return authorization == .authorized }
        return await AVCaptureDevice.requestAccess(for: .video)
    }
    func start(onFrame: @escaping @MainActor (CameraAnchorFrame) -> Void,
               onPreview: @escaping @MainActor (CGImage) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) async throws -> CameraAnchorConfiguration {
        stop()
        let ticket = captureGeneration
        await waitUntilStopped()
        guard ticket == captureGeneration else { throw CameraAnchorError.cancelled }
        let previewMailbox = CameraPreviewMailbox()
        self.previewMailbox = previewMailbox
        let worker = CameraAnchorWorker(onFrame: { frame in
            Task { @MainActor in onFrame(frame) }
        }, onPreview: { image in
            guard previewMailbox.offer(image) else { return }
            Task { @MainActor in
                guard let newest = previewMailbox.take() else { return }
                onPreview(newest)
            }
        }, onFailure: { detail in
            Task { @MainActor in onFailure(detail) }
        })
        self.worker = worker
        return try await worker.start()
    }
    func stop() {
        // Stop and publication share the main actor, so a drained image cannot
        // be delivered after this cancellation or into the next capture run.
        captureGeneration &+= 1
        previewMailbox?.cancel(); previewMailbox = nil
        if let worker {
            worker.stop()
            let earlierStop = pendingStop
            pendingStop = Task {
                await earlierStop?.value
                await worker.waitUntilStopped()
            }
        }
        worker = nil
    }
    func waitUntilStopped() async { await pendingStop?.value }
}

/// A capture run owns one mailbox. The producer replaces a superseded image
/// while exactly one main-actor notification is pending; UI congestion cannot
/// create a backlog of thumbnails. All state crosses queues under this lock.
final class CameraPreviewMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var notificationPending = false
    private var newest: CGImage?

    /// True means the caller must schedule the only outstanding notification.
    func offer(_ image: CGImage) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active else { return false }
        newest = image
        guard !notificationPending else { return false }
        notificationPending = true
        return true
    }

    func take() -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        notificationPending = false
        guard active else { return nil }
        let image = newest
        newest = nil
        return image
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        active = false
        notificationPending = false
        newest = nil
    }
}

/// All session/device/Vision state belongs to this one serial queue. The lock
/// only communicates immediate cancellation to queued or blocking startup.
private final class CameraAnchorWorker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "AirVeil.CameraAnchor", qos: .utility)
    private let lock = NSLock()
    private var cancelled = false
    private var session: AVCaptureSession?
    private var device: AVCaptureDevice?
    private var configuration: CameraAnchorConfiguration?
    private var lastAnalysis: TimeInterval = -.infinity
    private var lastPreview: TimeInterval = -.infinity
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var observers: [NSObjectProtocol] = []
    private let onFrame: @Sendable (CameraAnchorFrame) -> Void
    private let onPreview: @Sendable (CGImage) -> Void
    private let onFailure: @Sendable (String) -> Void
    init(onFrame: @escaping @Sendable (CameraAnchorFrame) -> Void,
         onPreview: @escaping @Sendable (CGImage) -> Void,
         onFailure: @escaping @Sendable (String) -> Void) {
        self.onFrame = onFrame; self.onPreview = onPreview; self.onFailure = onFailure
    }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private static func hostTime() -> TimeInterval { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    func start() async throws -> CameraAnchorConfiguration {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.configureAndStart()) }
                catch { self.cleanup(); continuation.resume(throwing: error) }
            }
        }
    }
    private func configureAndStart() throws -> CameraAnchorConfiguration {
        guard !isCancelled else { throw CameraAnchorError.cancelled }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
        guard let device = discovery.devices.first(where: { !$0.isContinuityCamera && $0.deviceType == .builtInWideAngleCamera }) else {
            throw CameraAnchorError.noBuiltInCamera
        }
        self.device = device
        let session = AVCaptureSession()
        self.session = session
        session.beginConfiguration()
        do {
            guard session.canSetSessionPreset(.vga640x480) else { throw CameraAnchorError.unsupportedConfiguration }
            session.sessionPreset = .vga640x480
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CameraAnchorError.unsupportedConfiguration }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            let pixelFormat = output.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { throw CameraAnchorError.unsupportedConfiguration }
            session.addOutput(output)
            guard let connection = output.connection(with: .video) else { throw CameraAnchorError.unsupportedConfiguration }
            connection.automaticallyAdjustsVideoMirroring = false
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
            session.commitConfiguration()
        } catch { session.commitConfiguration(); throw error }
        try device.lockForConfiguration()
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        let usableRanges = ranges.filter { $0.minFrameRate.isFinite && $0.maxFrameRate.isFinite && $0.minFrameRate > 0 }
        func requestedRate(_ range: AVFrameRateRange) -> Double { min(range.maxFrameRate, max(range.minFrameRate, 15)) }
        guard let range = usableRanges.min(by: { abs(requestedRate($0) - 15) < abs(requestedRate($1) - 15) }) else {
            device.unlockForConfiguration(); throw CameraAnchorError.unsupportedConfiguration
        }
        let fps = requestedRate(range)
        // Use the device's exact endpoint durations. Rounding 1/30 upward or
        // downward can otherwise accidentally request an unsupported endpoint.
        let duration = fps == range.minFrameRate ? range.maxFrameDuration :
            (fps == range.maxFrameRate ? range.minFrameDuration : CMTime(value: 1, timescale: 15))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
        var result = CameraAnchorConfiguration(cameraID: device.uniqueID, cameraName: device.localizedName,
            configurationID: "vision3-up-unmirrored-vga-centerStage:\(device.isCenterStageActive)", captureFramesPerSecond: fps)
        if #available(macOS 26.2, *) { result.supportsEdgeLight = device.activeFormat.isEdgeLightSupported }
        configuration = result
        for notification in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: notification, object: session, queue: nil) { [weak self] _ in
                guard let self, !self.isCancelled else { return }
                self.onFailure("Camera capture was interrupted or unavailable.")
                self.stop()
            })
        }
        guard !isCancelled else { throw CameraAnchorError.cancelled }
        session.startRunning()
        guard !isCancelled else { throw CameraAnchorError.cancelled }
        guard session.isRunning else { throw CameraAnchorError.failed("The camera did not start.") }
        return result
    }
    func stop() {
        lock.lock(); cancelled = true; lock.unlock()
        queue.async { self.cleanup() }
    }
    func waitUntilStopped() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
    private func cleanup() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        for output in session?.outputs ?? [] { (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil) }
        session?.stopRunning()
        session = nil; device = nil; configuration = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !isCancelled, let session, let device, let configuration else { return }
        let receipt = Self.hostTime()
        let configNow = "vision3-up-unmirrored-vga-centerStage:\(device.isCenterStageActive)"
        guard configNow == configuration.configurationID, !connection.isVideoMirrored else {
            onFailure("Camera framing changed. Set up its reference again."); stop(); return
        }
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // When analysis is due, publish its evidence before doing optional
        // thumbnail conversion. A preview must not delay the same frame's pose.
        defer { publishPreviewIfDue(pixels, receipt: receipt) }
        // Preview and Vision share this one bounded capture session. More
        // preview frames never create additional heading evidence.
        guard receipt - lastAnalysis >= 1 / 3.0 else { return }
        lastAnalysis = receipt
        var captureTime: Double?
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if let clock = session.synchronizationClock, pts.isNumeric {
            let converted = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock()).seconds
            if converted.isFinite, converted >= 0, converted <= receipt + 0.05 { captureTime = converted }
        }
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up, options: [:]).perform([request])
            guard !isCancelled else { return }
            let faces = request.results ?? []
            let face = faces.count == 1 ? faces.first : nil
            let luminance = face.flatMap { CameraLuminance.mean(pixels, normalizedRegion: $0.boundingBox.insetBy(dx: $0.boundingBox.width * 0.15, dy: $0.boundingBox.height * 0.15)) }
            func degrees(_ value: NSNumber?) -> Double? {
                guard let radians = value?.doubleValue, radians.isFinite else { return nil }
                return radians * 180 / .pi
            }
            onFrame(CameraAnchorFrame(cameraID: configuration.cameraID, configurationID: configuration.configurationID,
                faceCount: faces.count, yawDegrees: degrees(face?.yaw), pitchDegrees: degrees(face?.pitch),
                rollDegrees: degrees(face?.roll), detectionConfidence: face?.confidence ?? 0,
                faceBounds: face?.boundingBox, captureHostTime: captureTime,
                receiptHostTime: receipt, processedHostTime: Self.hostTime(), luminance: luminance,
                centerLuminance: CameraLuminance.mean(pixels, normalizedRegion: CameraLuminance.searchRegion)))
        } catch {
            onFailure("Face analysis could not complete."); stop()
        }
    }

    private func publishPreviewIfDue(_ pixels: CVPixelBuffer, receipt: Double) {
        guard !isCancelled, receipt - lastPreview >= 1 / 15.0 - 0.005 else { return }
        lastPreview = receipt
        let source = CIImage(cvPixelBuffer: pixels)
        let scale = min(1, 320 / source.extent.width)
        let thumbnail = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if let image = imageContext.createCGImage(thumbnail, from: thumbnail.extent), !isCancelled {
            onPreview(image)
        }
    }
}

/// Sparse brightness measurement from the existing analysis frame. It is used
/// for face-local pose failures and a central no-face lighting offer, never
/// as a replacement for confidence. Vision regions have a lower-left normalized origin; luma
/// planes are addressed from the top left.
enum CameraLuminance {
    static let searchRegion = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
    static func mean(_ pixels: CVPixelBuffer, normalizedRegion: CGRect? = nil) -> Double? {
        guard CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(pixels)
        let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard fullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(pixels) > 0,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixels, 0), height = CVPixelBufferGetHeightOfPlane(pixels, 0)
        guard width > 0, height > 0 else { return nil }
        let region = normalizedRegion ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        guard [region.minX, region.minY, region.width, region.height].allSatisfy({ $0.isFinite }),
              region.width > 0, region.height > 0 else { return nil }
        let clipped = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        let minX = max(0, min(width - 1, Int((clipped.minX * Double(width)).rounded(.down))))
        let maxX = max(minX + 1, min(width, Int((clipped.maxX * Double(width)).rounded(.up))))
        let minY = max(0, min(height - 1, Int(((1 - clipped.maxY) * Double(height)).rounded(.down))))
        let maxY = max(minY + 1, min(height, Int(((1 - clipped.minY) * Double(height)).rounded(.up))))
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var total = 0.0, count = 0.0
        for y in Swift.stride(from: minY, to: maxY, by: max(1, (maxY - minY) / 12)) {
            for x in Swift.stride(from: minX, to: maxX, by: max(1, (maxX - minX) / 16)) {
                let value = Double(bytes[y * stride + x])
                total += min(1, max(0, fullRange ? value / 255 : (value - 16) / 219))
                count += 1
            }
        }
        return count > 0 ? total / count : nil
    }
}
