import Foundation
import Combine
import AVFoundation
import Vision
import ImageIO

enum PresenceCaptureError: LocalizedError {
    case permissionRequired, unavailable, configurationChanged, cancelled, failed(String)
    var errorDescription: String? {
        switch self {
        case .permissionRequired: return "Camera permission is required for presence checks."
        case .unavailable: return "The calibrated built-in camera is unavailable."
        case .configurationChanged: return "Camera framing changed. Set center again before checking presence."
        case .cancelled: return "Presence check cancelled."
        case .failed(let reason): return "Presence camera failed: \(reason)"
        }
    }
}

@MainActor protocol PresenceCapturing: AnyObject {
    var isAuthorized: Bool { get }
    func start(reference: PresenceSeatReference,
               onObservation: @escaping @MainActor (PresenceObservation) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) async throws
    /// Returns only after the capture queue has stopped and released its session.
    func stop() async
}

/// The caller starts this only during an explicit headphones-removed session
/// and owns exclusion with calibration. Await stop before restarting calibration.
/// No camera permission prompts, previews, recorded images, audio, or identity.
@MainActor final class PresenceService: ObservableObject {
    @Published private(set) var state: PresenceState = .unknown
    @Published private(set) var status = "Presence camera is off."
    @Published private(set) var isRunning = false
    private let capture: any PresenceCapturing
    private let now: () -> Double
    private var tracker: PresenceTracker?
    private var generation: UInt64 = 0
    private var watchdog: Task<Void, Never>?
    private var receivedFrame = false
    private var stopRevision: UInt64 = 0
    private var stopBarrier: (id: UInt64, task: Task<Void, Never>)?

    convenience init() {
        self.init(capture: SystemPresenceCapture())
    }
    init(capture: any PresenceCapturing,
         now: @escaping () -> Double = { CMClockGetHostTimeClock().time.seconds }) {
        self.capture = capture; self.now = now
    }

    func start(reference: PresenceSeatReference) async throws {
        generation &+= 1
        let ticket = generation
        watchdog?.cancel(); watchdog = nil
        isRunning = false; tracker = nil
        publish(PresenceSnapshot(status: "Starting the presence check."))
        await stopCapture()
        guard generation == ticket, !Task.isCancelled else { throw PresenceCaptureError.cancelled }
        guard capture.isAuthorized else {
            publish(PresenceSnapshot(status: PresenceCaptureError.permissionRequired.localizedDescription))
            throw PresenceCaptureError.permissionRequired
        }
        guard PresenceTracker.isReferenceUsable(reference, now: now()) else {
            publish(PresenceSnapshot(status: PresenceCaptureError.configurationChanged.localizedDescription))
            throw PresenceCaptureError.configurationChanged
        }
        tracker = PresenceTracker(reference: reference)
        receivedFrame = false; isRunning = true
        publish(PresenceSnapshot())
        let started = now()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
                guard let self, self.generation == ticket, self.isRunning else { return }
                if !self.receivedFrame, self.now() - started > 5 {
                    await self.failed("The presence camera did not deliver a frame.", ticket: ticket)
                    return
                }
                self.refresh()
            }
        }
        do {
            try await capture.start(reference: reference, onObservation: { [weak self] observation in
                guard let self, self.generation == ticket, self.isRunning else { return }
                self.receivedFrame = true
                guard let snapshot = self.tracker?.observe(observation, now: self.now()) else { return }
                self.publish(snapshot)
            }, onFailure: { [weak self] reason in
                Task { @MainActor [weak self] in await self?.failed(reason, ticket: ticket) }
            })
            guard generation == ticket, isRunning, !Task.isCancelled else { throw PresenceCaptureError.cancelled }
        } catch {
            if generation == ticket { await failed(error.localizedDescription, ticket: ticket) }
            throw error
        }
    }

    func stop() async {
        generation &+= 1
        watchdog?.cancel(); watchdog = nil
        isRunning = false; tracker = nil; receivedFrame = false
        publish(PresenceSnapshot(status: "Presence camera is off."))
        await stopCapture()
    }

    /// Internal failures and external lifecycle transitions may stop together.
    /// All waiters join the same physical teardown instead of mistaking an
    /// already-cleared worker pointer for a released camera device.
    private func stopCapture() async {
        let operation: (id: UInt64, task: Task<Void, Never>)
        if let stopBarrier { operation = stopBarrier }
        else {
            stopRevision &+= 1
            let capture = capture
            operation = (stopRevision, Task { @MainActor in await capture.stop() })
            stopBarrier = operation
        }
        await operation.task.value
        if stopBarrier?.id == operation.id { stopBarrier = nil }
    }

    /// Also callable by the application's ordinary lifecycle tick. Elapsed time
    /// can invalidate stale evidence but can never prove that someone left.
    func refresh() {
        guard isRunning, let snapshot = tracker?.tick(now: now()) else { return }
        publish(snapshot)
    }

    private func failed(_ reason: String, ticket: UInt64) async {
        guard generation == ticket else { return }
        await stop()
        guard generation == ticket &+ 1 else { return }
        publish(PresenceSnapshot(status: reason))
    }
    private func publish(_ snapshot: PresenceSnapshot) {
        if state != snapshot.state { state = snapshot.state }
        if status != snapshot.status { status = snapshot.status }
    }
}

@MainActor private final class SystemPresenceCapture: PresenceCapturing {
    private var worker: PresenceCaptureWorker?
    var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }
    func start(reference: PresenceSeatReference,
               onObservation: @escaping @MainActor (PresenceObservation) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) async throws {
        let worker = PresenceCaptureWorker(reference: reference, onObservation: { observation in
            Task { @MainActor in onObservation(observation) }
        }, onFailure: { reason in Task { @MainActor in onFailure(reason) } })
        self.worker = worker
        try await worker.start()
    }
    func stop() async {
        let previous = worker; worker = nil
        await previous?.stop()
    }
}

private final class PresenceCaptureWorker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "AirVeil.Presence", qos: .utility)
    private let lock = NSLock()
    private var cancelled = false
    private var session: AVCaptureSession?
    private var device: AVCaptureDevice?
    private var observers: [NSObjectProtocol] = []
    private var lastAnalysis = -Double.infinity
    private let reference: PresenceSeatReference
    private let onObservation: @Sendable (PresenceObservation) -> Void
    private let onFailure: @Sendable (String) -> Void

    init(reference: PresenceSeatReference,
         onObservation: @escaping @Sendable (PresenceObservation) -> Void,
         onFailure: @escaping @Sendable (String) -> Void) {
        self.reference = reference; self.onObservation = onObservation; self.onFailure = onFailure
    }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private func cancelImmediately() { lock.lock(); cancelled = true; lock.unlock() }
    private static func hostTime() -> Double { CMClockGetHostTimeClock().time.seconds }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try self.configureAndStart(); continuation.resume() }
                catch { self.cleanup(); continuation.resume(throwing: error) }
            }
        }
    }
    func stop() async {
        cancelImmediately()
        await withCheckedContinuation { continuation in
            queue.async { self.cleanup(); continuation.resume() }
        }
    }
    private func configureAndStart() throws {
        guard !isCancelled else { throw PresenceCaptureError.cancelled }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { throw PresenceCaptureError.permissionRequired }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
        guard let device = discovery.devices.first(where: { $0.uniqueID == reference.cameraID && !$0.isContinuityCamera }) else {
            throw PresenceCaptureError.unavailable
        }
        self.device = device
        let session = AVCaptureSession(); self.session = session
        session.beginConfiguration()
        do {
            guard session.canSetSessionPreset(.vga640x480) else { throw PresenceCaptureError.unavailable }
            session.sessionPreset = .vga640x480
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw PresenceCaptureError.unavailable }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            let format = output.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { throw PresenceCaptureError.unavailable }
            session.addOutput(output)
            guard let connection = output.connection(with: .video) else { throw PresenceCaptureError.unavailable }
            connection.automaticallyAdjustsVideoMirroring = false
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
            session.commitConfiguration()
        } catch { session.commitConfiguration(); throw error }
        try device.lockForConfiguration()
        let ranges = device.activeFormat.videoSupportedFrameRateRanges.filter { $0.minFrameRate > 0 && $0.maxFrameRate.isFinite }
        func requestedRate(_ range: AVFrameRateRange) -> Double { min(range.maxFrameRate, max(range.minFrameRate, 15)) }
        guard let range = ranges.min(by: { abs(requestedRate($0) - 15) < abs(requestedRate($1) - 15) }) else {
            device.unlockForConfiguration(); throw PresenceCaptureError.unavailable
        }
        let fps = requestedRate(range)
        let duration = fps == range.minFrameRate ? range.maxFrameDuration :
            (fps == range.maxFrameRate ? range.minFrameDuration : CMTime(value: 1, timescale: 15))
        device.activeVideoMinFrameDuration = duration; device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
        guard configurationID == reference.configurationID else { throw PresenceCaptureError.configurationChanged }
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                guard let self, !self.isCancelled else { return }
                self.fail("The presence camera was interrupted.")
            })
        }
        guard !isCancelled else { throw PresenceCaptureError.cancelled }
        session.startRunning()
        guard !isCancelled else { throw PresenceCaptureError.cancelled }
        guard session.isRunning else { throw PresenceCaptureError.unavailable }
    }
    private var configurationID: String {
        "vision3-up-unmirrored-vga-centerStage:\(device?.isCenterStageActive ?? false)"
    }
    private func cleanup() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        for output in session?.outputs ?? [] { (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil) }
        session?.stopRunning(); session = nil; device = nil
    }
    private func fail(_ reason: String) {
        cancelImmediately()
        queue.async { self.cleanup() }
        onFailure(reason)
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !isCancelled, let session else { return }
        let receipt = Self.hostTime()
        guard receipt - lastAnalysis >= 1 / 3.0 else { return }
        lastAnalysis = receipt
        guard configurationID == reference.configurationID, !connection.isVideoMirrored else {
            fail("Camera framing changed during the presence check."); return
        }
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer), let clock = session.synchronizationClock else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isNumeric else { return }
        let captured = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock()).seconds
        guard captured.isFinite, captured >= 0, captured <= receipt else { return }
        let bodies = VNDetectHumanRectanglesRequest()
        bodies.revision = VNDetectHumanRectanglesRequestRevision2
        bodies.upperBodyOnly = true
        let faces = VNDetectFaceRectanglesRequest()
        faces.revision = VNDetectFaceRectanglesRequestRevision3
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up, options: [:]).perform([bodies, faces])
            guard !isCancelled else { return }
            onObservation(PresenceObservation(cameraID: reference.cameraID, configurationID: configurationID,
                captureHostTime: captured, receiptHostTime: receipt,
                bodies: (bodies.results ?? []).map { PresenceBody(bounds: $0.boundingBox, confidence: Double($0.confidence)) },
                faces: (faces.results ?? []).filter { $0.confidence >= 0.6 }.map(\.boundingBox),
                analysisUsable: !Self.isVeryDark(pixels)))
        } catch {
            fail("Human-body analysis could not complete.")
        }
    }
    private static func isVeryDark(_ pixels: CVPixelBuffer) -> Bool {
        guard CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return true }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pixels) > 0, let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return true }
        let width = CVPixelBufferGetWidthOfPlane(pixels, 0), height = CVPixelBufferGetHeightOfPlane(pixels, 0)
        guard width > 0, height > 0 else { return true }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let fullRange = CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        var total = 0.0, count = 0.0
        for y in Swift.stride(from: 0, to: height, by: max(1, height / 12)) {
            for x in Swift.stride(from: 0, to: width, by: max(1, width / 16)) {
                total += max(0, fullRange ? Double(bytes[y * stride + x]) / 255 : (Double(bytes[y * stride + x]) - 16) / 219)
                count += 1
            }
        }
        return count == 0 || total / count < 0.04
    }
}
