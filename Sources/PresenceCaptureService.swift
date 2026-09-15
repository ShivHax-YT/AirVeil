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
    @Published private(set) var isAssistLightOn = false
    @Published private(set) var isLowLight = false
    private(set) var qualityDiagnostics: [String: Any] = [:]
    private let capture: any PresenceCapturing
    private let faceLight: any FaceLighting
    private let now: () -> Double
    private var tracker: PresenceTracker?
    private var generation: UInt64 = 0
    private var watchdog: Task<Void, Never>?
    private var receivedFrame = false
    private var stopRevision: UInt64 = 0
    private var stopBarrier: (id: UInt64, task: Task<Void, Never>)?
    private var lowLightFrames = 0
    private var lastLightCapture: Double?
    private var lightAttempted = false
    private var lightDeadline: Double?
    private var illuminationCaptureCutoff: Double?
    private var diagnosticCaptureTime: Double?

    convenience init() {
        self.init(capture: SystemPresenceCapture())
    }
    init(capture: any PresenceCapturing,
         faceLight: (any FaceLighting)? = nil,
         now: @escaping () -> Double = { CMClockGetHostTimeClock().time.seconds }) {
        self.capture = capture; self.faceLight = faceLight ?? FaceLightService(); self.now = now
    }

    func start(reference: PresenceSeatReference) async throws {
        generation &+= 1
        let ticket = generation
        watchdog?.cancel(); watchdog = nil
        stopAssistLight(); lowLightFrames = 0; lastLightCapture = nil; lightAttempted = false
        illuminationCaptureCutoff = nil; diagnosticCaptureTime = nil; qualityDiagnostics = [:]
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
                if let cutoff = self.illuminationCaptureCutoff, observation.captureHostTime <= cutoff { return }
                self.receivedFrame = true
                self.updateQualityDiagnostics(observation, reference: reference)
                if observation.cameraID == reference.cameraID,
                   observation.configurationID == reference.configurationID {
                    self.considerAssistLight(observation)
                }
                guard let snapshot = self.tracker?.observe(observation, now: self.now()) else { return }
                if snapshot.state == .present || snapshot.state == .absent { self.stopAssistLight() }
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
        stopAssistLight()
        qualityDiagnostics["fresh"] = false; qualityDiagnostics["decision"] = "stopped"
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
        if let lightDeadline, now() >= lightDeadline { stopAssistLight() }
        guard isRunning, let snapshot = tracker?.tick(now: now()) else { return }
        if let captured = diagnosticCaptureTime, now() - captured > PresenceTracker.frameFreshness {
            qualityDiagnostics["fresh"] = false; qualityDiagnostics["decision"] = "stale"
        }
        publish(snapshot)
    }

    /// Called only after the brightness driver verifies restoration. Keep the
    /// same camera and seat track, but discard every queued pre-restore frame.
    func recheckAfterBrightnessRestore() {
        guard isRunning else { return }
        let cutoff = now()
        guard cutoff.isFinite, cutoff >= 0 else { return }
        illuminationCaptureCutoff = cutoff
        tracker?.recheckAfterBrightnessRestore(after: cutoff)
        stopAssistLight()
        qualityDiagnostics["fresh"] = false; qualityDiagnostics["decision"] = "awaiting-restored-light"
        if let snapshot = tracker?.snapshot { publish(snapshot) }
    }

    private func updateQualityDiagnostics(_ observation: PresenceObservation, reference: PresenceSeatReference) {
        let time = now()
        guard observation.cameraID == reference.cameraID, observation.configurationID == reference.configurationID,
              observation.captureHostTime.isFinite, observation.receiptHostTime.isFinite,
              observation.captureHostTime >= 0, observation.captureHostTime <= observation.receiptHostTime,
              observation.receiptHostTime <= time, time - observation.captureHostTime <= PresenceTracker.frameFreshness,
              diagnosticCaptureTime.map({ observation.captureHostTime > $0 }) ?? true else {
            qualityDiagnostics["fresh"] = false; qualityDiagnostics["decision"] = "stale-or-mismatched"
            return
        }
        diagnosticCaptureTime = observation.captureHostTime
        let quality = observation.frameQuality
        func number(_ value: Double?) -> Any {
            guard let value, value.isFinite else { return NSNull() }
            return value
        }
        qualityDiagnostics = ["fresh": true, "decision": quality?.decision ?? "unavailable",
            "globalMean": number(quality?.globalMean),
            "seatMean": number(quality?.seatMean),
            "seatDarkFraction": number(quality?.seatDarkFraction),
            "seatContrast": number(quality?.seatContrast),
            "seatClippedFraction": number(quality?.seatClippedFraction),
            "sampleCount": quality?.sampleCount as Any? ?? NSNull(),
            "bodyCount": observation.bodies.count, "faceCount": observation.faces.count,
            "uncertainFaceCount": observation.uncertainFaces.count,
            "maximumBodyConfidence": observation.bodies.map(\.confidence).filter(\.isFinite).max() as Any? ?? NSNull(),
            "maximumFaceConfidence": number(observation.maximumFaceConfidence)]
    }

    private func considerAssistLight(_ observation: PresenceObservation) {
        let time = now()
        guard observation.captureHostTime.isFinite, observation.receiptHostTime.isFinite,
              observation.captureHostTime >= 0, observation.captureHostTime <= observation.receiptHostTime,
              observation.receiptHostTime <= time, time - observation.captureHostTime <= PresenceTracker.frameFreshness,
              lastLightCapture.map({ observation.captureHostTime > $0 }) ?? true else { return }
        lastLightCapture = observation.captureHostTime
        lowLightFrames = observation.needsLightAssistance ? min(2, lowLightFrames + 1) : 0
        guard lowLightFrames >= 2, !lightAttempted, isRunning else { return }
        lightAttempted = true
        guard faceLight.setEnabled(true) else { return }
        isAssistLightOn = faceLight.isOn
        lightDeadline = time + 2.5
    }

    private func stopAssistLight() {
        lightDeadline = nil
        _ = faceLight.setEnabled(false)
        isAssistLightOn = faceLight.isOn
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
        if isLowLight != snapshot.isLowLight { isLowLight = snapshot.isLowLight }
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
            let quality = PresenceImageQuality.measure(pixels, faceBounds: reference.faceBounds)
            onObservation(PresenceObservation(cameraID: reference.cameraID, configurationID: configurationID,
                captureHostTime: captured, receiptHostTime: receipt,
                bodies: (bodies.results ?? []).map { PresenceBody(bounds: $0.boundingBox, confidence: Double($0.confidence)) },
                faces: (faces.results ?? []).filter { $0.confidence >= 0.6 }.map(\.boundingBox),
                analysisUsable: quality?.supportsAbsence == true, needsLightAssistance: quality?.needsLight == true,
                frameQuality: quality,
                uncertainFaces: (faces.results ?? []).filter { $0.confidence >= 0.3 && $0.confidence < 0.6 }.map(\.boundingBox),
                maximumFaceConfidence: (faces.results ?? []).map { Double($0.confidence) }.max()))
        } catch {
            fail("Human-body analysis could not complete.")
        }
    }
}

/// Sparse numeric measurements only; no frames or image crops are retained.
enum PresenceImageQuality {
    static func measure(_ pixels: CVPixelBuffer, faceBounds: CGRect) -> PresenceFrameQuality? {
        let format = CVPixelBufferGetPixelFormatType(pixels)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              [faceBounds.minX, faceBounds.minY, faceBounds.width, faceBounds.height].allSatisfy(\.isFinite),
              faceBounds.width > 0, faceBounds.height > 0,
              CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pixels) > 0, let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixels, 0), height = CVPixelBufferGetHeightOfPlane(pixels, 0)
        guard width > 0, height > 0 else { return nil }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        guard stride >= width else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        func samples(in bounds: CGRect) -> [Double] {
            let region = bounds.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !region.isNull, !region.isEmpty else { return [] }
            let x0 = max(0, Int(floor(region.minX * Double(width))))
            let x1 = min(width, Int(ceil(region.maxX * Double(width))))
            // Vision rectangles use a bottom-left origin; camera pixels are top-left.
            let y0 = max(0, Int(floor((1 - region.maxY) * Double(height))))
            let y1 = min(height, Int(ceil((1 - region.minY) * Double(height))))
            var values: [Double] = []
            for y in Swift.stride(from: y0, to: y1, by: max(1, (y1 - y0) / 12)) {
                for x in Swift.stride(from: x0, to: x1, by: max(1, (x1 - x0) / 16)) {
                    let raw = Double(bytes[y * stride + x])
                    values.append(min(1, max(0, fullRange ? raw / 255 : (raw - 16) / 219)))
                }
            }
            return values
        }
        let global = samples(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let region = CGRect(x: faceBounds.midX - faceBounds.width * 0.9,
                            y: faceBounds.minY - faceBounds.height * 1.4,
                            width: faceBounds.width * 1.8, height: faceBounds.height * 2.6)
        let seat = samples(in: region).sorted()
        guard !global.isEmpty, !seat.isEmpty else { return nil }
        return PresenceFrameQuality(globalMean: global.reduce(0, +) / Double(global.count),
            seatMean: seat.reduce(0, +) / Double(seat.count),
            seatDarkFraction: Double(seat.filter { $0 < 0.04 }.count) / Double(seat.count),
            seatContrast: seat[Int(Double(seat.count - 1) * 0.9)] - seat[Int(Double(seat.count - 1) * 0.1)],
            seatClippedFraction: Double(seat.filter { $0 > 0.98 }.count) / Double(seat.count), sampleCount: seat.count)
    }
}
