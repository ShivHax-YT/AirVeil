import Foundation
import Combine
import AVFoundation
import Vision
import ImageIO

enum CameraAuthorization: String, Sendable { case notDetermined, authorized, denied, restricted }

struct CameraAnchorConfiguration: Sendable, Equatable {
    let cameraID: String
    let cameraName: String
    let configurationID: String
    let captureFramesPerSecond: Double
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
               onFailure: @escaping @MainActor (String) -> Void) async throws -> CameraAnchorConfiguration
    func stop()
}

/// Camera acquisition only: no center changes, reference persistence, images
/// on disk, microphone, network, or automatic permission requests.
@MainActor final class CameraAnchorService: ObservableObject {
    @Published private(set) var status = "Camera is off."
    @Published private(set) var isRunning = false
    @Published private(set) var authorization: CameraAuthorization
    @Published private(set) var configuration: CameraAnchorConfiguration?
    var deviceID: String? { configuration?.cameraID }
    private let capture: any CameraAnchorCapturing
    private var generation: UInt64 = 0
    private var timeout: Task<Void, Never>?

    convenience init() { self.init(capture: SystemCameraAnchorCapture()) }
    init(capture: any CameraAnchorCapturing) {
        self.capture = capture
        authorization = capture.authorization
    }

    func refreshAuthorization() { authorization = capture.authorization }

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
            }, onFailure: { [weak self] detail in
                guard let self, self.generation == run else { return }
                self.stop()
                self.status = "Camera stopped: \(detail)"
            })
            guard generation == run, isRunning, !Task.isCancelled else { throw CameraAnchorError.cancelled }
            configuration = result
            status = "Brief camera check active. Images are processed locally and discarded."
        } catch {
            if generation == run { stop(); status = error.localizedDescription }
            throw error
        }
    }

    func stop() {
        generation &+= 1
        timeout?.cancel(); timeout = nil
        isRunning = false
        capture.stop()
        status = "Camera is off."
    }
}

@MainActor private final class SystemCameraAnchorCapture: CameraAnchorCapturing {
    private var worker: CameraAnchorWorker?
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
               onFailure: @escaping @MainActor (String) -> Void) async throws -> CameraAnchorConfiguration {
        stop()
        let worker = CameraAnchorWorker(onFrame: { frame in
            Task { @MainActor in onFrame(frame) }
        }, onFailure: { detail in
            Task { @MainActor in onFailure(detail) }
        })
        self.worker = worker
        return try await worker.start()
    }
    func stop() { worker?.stop(); worker = nil }
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
    private var observers: [NSObjectProtocol] = []
    private let onFrame: @Sendable (CameraAnchorFrame) -> Void
    private let onFailure: @Sendable (String) -> Void
    init(onFrame: @escaping @Sendable (CameraAnchorFrame) -> Void,
         onFailure: @escaping @Sendable (String) -> Void) {
        self.onFrame = onFrame; self.onFailure = onFailure
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
        func requestedRate(_ range: AVFrameRateRange) -> Double { min(range.maxFrameRate, max(range.minFrameRate, 3)) }
        guard let range = usableRanges.min(by: { abs(requestedRate($0) - 3) < abs(requestedRate($1) - 3) }) else {
            device.unlockForConfiguration(); throw CameraAnchorError.unsupportedConfiguration
        }
        let fps = requestedRate(range)
        // Use the device's exact endpoint durations. Rounding 1/30 upward or
        // downward can otherwise accidentally request an unsupported endpoint.
        let duration = fps == range.minFrameRate ? range.maxFrameDuration :
            (fps == range.maxFrameRate ? range.minFrameDuration : CMTime(value: 1, timescale: 3))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
        let result = CameraAnchorConfiguration(cameraID: device.uniqueID, cameraName: device.localizedName,
            configurationID: "vision3-up-unmirrored-vga-centerStage:\(device.isCenterStageActive)", captureFramesPerSecond: fps)
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
        guard receipt - lastAnalysis >= 1 / 3.0 else { return }
        lastAnalysis = receipt
        let configNow = "vision3-up-unmirrored-vga-centerStage:\(device.isCenterStageActive)"
        guard configNow == configuration.configurationID, !connection.isVideoMirrored else {
            onFailure("Camera framing changed. Set up its reference again."); stop(); return
        }
        var captureTime: Double?
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if let clock = session.synchronizationClock, pts.isNumeric {
            let converted = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock()).seconds
            if converted.isFinite, converted >= 0, converted <= receipt + 0.05 { captureTime = converted }
        }
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up, options: [:]).perform([request])
            guard !isCancelled else { return }
            let faces = request.results ?? []
            let face = faces.count == 1 ? faces.first : nil
            func degrees(_ value: NSNumber?) -> Double? {
                guard let radians = value?.doubleValue, radians.isFinite else { return nil }
                return radians * 180 / .pi
            }
            onFrame(CameraAnchorFrame(cameraID: configuration.cameraID, configurationID: configuration.configurationID,
                faceCount: faces.count, yawDegrees: degrees(face?.yaw), pitchDegrees: degrees(face?.pitch),
                rollDegrees: degrees(face?.roll), detectionConfidence: face?.confidence ?? 0,
                faceBounds: face?.boundingBox, captureHostTime: captureTime,
                receiptHostTime: receipt, processedHostTime: Self.hostTime()))
        } catch {
            onFailure("Face analysis could not complete."); stop()
        }
    }
}
