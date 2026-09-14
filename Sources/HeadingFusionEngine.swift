import Foundation

struct HeadingMotionSample: Equatable, Sendable {
    let epoch: UInt64
    let sourceTimestamp: Double
    let receiptHostTime: Double
    let yawRadians: Double
    let angularSpeed: Double
}

struct HeadingCameraSample: Equatable, Sendable {
    let generation: UInt64
    let cameraID: String
    let captureHostTime: Double
    let receiptHostTime: Double
    let yawRadians: Double
    let pitchRadians: Double
    let rollRadians: Double
    let confidence: Double
    let faceCount: Int
}

/// The geometric center is changed only by explicit setup. Sensor alignments
/// below are disposable and must never be persisted as this center.
enum HeadingCameraCenterMode: String, Codable, Sendable { case facingCamera }

struct HeadingCameraCenter: Equatable, Codable, Sendable {
    let cameraID: String
    let neutralYawRadians: Double
    let cameraSign: Double
    let sensorSign: Double
    let revision: Int
    /// Missing means the older arbitrary camera-neutral model. In facingCamera
    /// mode neutral is always zero and cameraSign is zero (unused, not learned).
    var mode: HeadingCameraCenterMode? = nil
}

/// Local, planar-yaw prototype. Camera times are actual capture PTS converted
/// to Core Media host time; motion receipts are acquisition host times.
/// AirPods source-to-host clock identity is unverified. The extended stationary
/// overlap is an explicit bounded-latency approximation, NOT clock sync. Its
/// 200 ms guard requires a consented device latency test before reliability is
/// claimed. The production facing-camera route admits zero only after an
/// absolute camera-center gate. The legacy off-axis route remains separate.
struct HeadingFusionEngine {
    static let centerYawToleranceDegrees = 5.0
    static let holdDurationSeconds = 0.6
    private(set) var alignmentRevision = 0
    private(set) var status = "Set your screen center"
    private var center: HeadingCameraCenter?
    private var motion: [HeadingMotionSample] = []
    private var camera: [HeadingCameraSample] = []
    private var centeredCamera: [HeadingCameraSample] = []
    private var centeredReference: HeadingCameraCenter?
    private var offset: Double?
    private var epoch: UInt64?
    private var cameraGeneration: UInt64?
    private let guardTime = 0.2
    private let motionFreshness = 0.65

    mutating func configure(center: HeadingCameraCenter?) {
        self.center = center
        invalidate()
        if let center, !Self.isReferenceUsable(center) {
            self.center = nil
        }
        status = self.center == nil ? "Set your screen center" : "Checking your head direction"
    }

    mutating func invalidate() {
        motion.removeAll(keepingCapacity: true)
        camera.removeAll(keepingCapacity: true)
        centeredCamera.removeAll(keepingCapacity: true)
        centeredReference = nil
        offset = nil
        epoch = nil
        cameraGeneration = nil
        status = center == nil ? "Set your screen center" : "Checking your head direction"
    }

    mutating func discardCameraEvidence() {
        camera.removeAll(keepingCapacity: true)
        cameraGeneration = nil
        centeredCamera.removeAll(keepingCapacity: true)
        centeredReference = nil
    }

    private static func isReferenceUsable(_ center: HeadingCameraCenter) -> Bool {
        guard !center.cameraID.isEmpty, center.neutralYawRadians.isFinite,
              abs(center.sensorSign) == 1 else { return false }
        if center.mode == .facingCamera {
            return center.neutralYawRadians == 0 && center.cameraSign == 0
        }
        return abs(center.cameraSign) == 1
    }

    static func isCenteredCameraSampleUsable(_ sample: HeadingCameraSample, now: Double) -> Bool {
        isCameraSampleUsable(sample, now: now) &&
            abs(sample.yawRadians) <= centerYawToleranceDegrees * .pi / 180
    }

    /// One camera stream verifies actual front-facing pose and a stationary
    /// AirPods interval. The accepted sensor mean becomes zero in this same
    /// operation; no camera handedness or off-axis neutral is inferred.
    mutating func addCenteredCamera(_ sample: HeadingCameraSample,
                                    reference: HeadingCameraCenter, now: Double) -> Bool {
        guard reference.mode == .facingCamera, Self.isReferenceUsable(reference),
              sample.cameraID == reference.cameraID,
              Self.isCenteredCameraSampleUsable(sample, now: now) else {
            discardCameraEvidence()
            return false
        }
        if centeredReference != reference || centeredCamera.last?.generation != sample.generation {
            centeredCamera.removeAll(keepingCapacity: true)
            centeredReference = reference
        }
        if let last = centeredCamera.last, sample.captureHostTime <= last.captureHostTime { return false }
        centeredCamera.append(sample)
        centeredCamera.removeAll { sample.captureHostTime - $0.captureHostTime > 1.1 }
        guard centeredCamera.count >= 3, let first = centeredCamera.first, let last = centeredCamera.last,
              last.captureHostTime - first.captureHostTime >= Self.holdDurationSeconds,
              let latest = motion.last, now >= latest.receiptHostTime,
              now - latest.receiptHostTime <= 0.2,
              let before = motion.last(where: { $0.receiptHostTime <= first.captureHostTime - 0.6 }),
              let after = motion.first(where: { $0.receiptHostTime >= last.captureHostTime + guardTime }),
              first.captureHostTime - 0.6 - before.receiptHostTime <= 0.15,
              after.receiptHostTime - last.captureHostTime - guardTime <= 0.15 else { return false }
        let overlap = motion.filter { $0.receiptHostTime >= before.receiptHostTime &&
            $0.receiptHostTime <= after.receiptHostTime }
        guard overlap.count >= 8,
              overlap.allSatisfy({ $0.epoch == epoch && $0.angularSpeed <= .pi/36 }),
              let sensorMean = Self.mean(overlap.map { reference.sensorSign * $0.yawRadians }),
              let cameraMean = Self.mean(centeredCamera.map(\.yawRadians)),
              overlap.allSatisfy({ abs(Self.wrap(reference.sensorSign * $0.yawRadians - sensorMean)) <= .pi/90 }),
              centeredCamera.allSatisfy({ abs(Self.wrap($0.yawRadians - cameraMean)) <= .pi/90 }) else {
            status = "Face the camera and hold still briefly"
            return false
        }
        center = reference
        offset = Self.wrap(-sensorMean)
        alignmentRevision += 1
        discardCameraEvidence()
        status = "Ready"
        return true
    }

    mutating func addMotion(_ sample: HeadingMotionSample) {
        guard sample.sourceTimestamp.isFinite, sample.receiptHostTime.isFinite,
              sample.sourceTimestamp >= 0, sample.receiptHostTime >= 0,
              sample.yawRadians.isFinite, sample.angularSpeed.isFinite,
              sample.angularSpeed >= 0 else {
            invalidate()
            status = "Waiting for fresh AirPods motion"
            return
        }
        if epoch != sample.epoch { invalidate(); epoch = sample.epoch }
        if let previous = motion.last {
            // Ignore an identical publication; repeated UI polling does not
            // create more evidence of stillness or a new sensor epoch.
            if previous == sample { return }
            if sample.sourceTimestamp <= previous.sourceTimestamp ||
                sample.receiptHostTime <= previous.receiptHostTime ||
                sample.receiptHostTime - previous.receiptHostTime > 0.3 {
                invalidate()
                epoch = sample.epoch
            }
        }
        motion.append(sample)
        motion.removeAll { sample.receiptHostTime - $0.receiptHostTime > 2.5 }
        if motion.count > 300 { motion.removeFirst(motion.count - 300) }
        attemptAnchor(now: sample.receiptHostTime)
    }

    mutating func addCamera(_ sample: HeadingCameraSample, now: Double) {
        guard let center else { status = "Set your screen center"; return }
        guard center.mode == nil else {
            status = "Use the facing-center camera check"
            return
        }
        guard Self.isCameraSampleUsable(sample, now: now),
              sample.cameraID == center.cameraID else {
            camera.removeAll(keepingCapacity: true)
            status = sample.faceCount > 1 ? "More than one face is visible" : "Keep your face visible briefly"
            return
        }
        if let cameraGeneration, sample.generation < cameraGeneration { return }
        if cameraGeneration != sample.generation {
            camera.removeAll(keepingCapacity: true)
            cameraGeneration = sample.generation
        }
        if let previous = camera.last, sample.captureHostTime <= previous.captureHostTime { return }
        camera.append(sample)
        camera.removeAll { sample.captureHostTime - $0.captureHostTime > 1.1 }
        if camera.count > 30 { camera.removeFirst(camera.count - 30) }
        attemptAnchor(now: now)
    }

    static func isCameraSampleUsable(_ sample: HeadingCameraSample, now: Double) -> Bool {
        now.isFinite && sample.captureHostTime.isFinite &&
            sample.receiptHostTime.isFinite && sample.captureHostTime >= 0 &&
            sample.receiptHostTime >= sample.captureHostTime &&
            now >= sample.receiptHostTime && now - sample.captureHostTime <= 0.8 &&
            sample.receiptHostTime - sample.captureHostTime <= 0.5 &&
            !sample.cameraID.isEmpty && sample.yawRadians.isFinite &&
            sample.pitchRadians.isFinite && sample.rollRadians.isFinite &&
            sample.confidence.isFinite && sample.confidence >= 0.7 && sample.confidence <= 1 &&
            abs(sample.yawRadians) <= .pi/4 && abs(sample.pitchRadians) <= .pi/9 &&
            abs(sample.rollRadians) <= .pi/12 && sample.faceCount == 1
    }

    /// Shared setup gate. Returns raw sensor yaw; callers apply their explicitly
    /// verified sign. Receipt overlap is the documented prototype approximation.
    func stableMotionYaw(atCameraCaptureTime capture: Double, now: Double) -> Double? {
        guard capture.isFinite, now.isFinite, now >= capture,
              now - capture <= 0.8, let latest = motion.last,
              now >= latest.receiptHostTime, now-latest.receiptHostTime <= 0.2,
              let before = motion.last(where: { $0.receiptHostTime <= capture-0.6 }),
              let after = motion.first(where: { $0.receiptHostTime >= capture+guardTime }),
              capture-0.6-before.receiptHostTime <= 0.15,
              after.receiptHostTime-capture-guardTime <= 0.15 else { return nil }
        let overlap = motion.filter { $0.receiptHostTime >= before.receiptHostTime &&
            $0.receiptHostTime <= after.receiptHostTime }
        guard overlap.count >= 8,
              overlap.allSatisfy({ $0.epoch == epoch && $0.angularSpeed <= .pi/36 }),
              let value = Self.mean(overlap.map(\.yawRadians)),
              overlap.allSatisfy({ abs(Self.wrap($0.yawRadians-value)) <= .pi/90 }) else { return nil }
        return value
    }

    func heading(now: Double) -> Double? {
        guard let center, let offset, let sample = motion.last,
              now.isFinite, now >= sample.receiptHostTime,
              now - sample.receiptHostTime <= motionFreshness else { return nil }
        return Self.wrap(center.sensorSign * sample.yawRadians + offset)
    }

    /// Both changes must be real, moderate turns in the same sensor epoch.
    /// sensorDelta must already use the wearer's verified physical-left sign.
    static func learnedCameraSign(cameraDelta: Double, sensorDelta: Double) -> Double? {
        guard cameraDelta.isFinite, sensorDelta.isFinite else { return nil }
        let c = wrap(cameraDelta), s = wrap(sensorDelta), threshold = .pi / 15.0
        guard abs(c) >= threshold, abs(s) >= threshold,
              abs(c) <= .pi/2, abs(s) <= .pi/2,
              abs(c/s) >= 0.5, abs(c/s) <= 2 else { return nil }
        return c * s > 0 ? 1 : -1
    }

    static func wrap(_ radians: Double) -> Double { atan2(sin(radians), cos(radians)) }

    private static func mean(_ angles: [Double]) -> Double? {
        guard !angles.isEmpty else { return nil }
        let x = angles.reduce(0) { $0 + cos($1) }, y = angles.reduce(0) { $0 + sin($1) }
        guard hypot(x, y) / Double(angles.count) > 0.95 else { return nil }
        return atan2(y, x)
    }

    private mutating func attemptAnchor(now: Double) {
        guard let center, center.mode == nil, camera.count >= 3,
              let first = camera.first, let last = camera.last,
              last.captureHostTime - first.captureHostTime >= 0.5,
              now - last.captureHostTime <= 0.8 else { return }
        let start = first.captureHostTime - guardTime
        let end = last.captureHostTime + guardTime
        guard end - start >= 0.8,
              let before = motion.last(where: { $0.receiptHostTime <= start }),
              let after = motion.first(where: { $0.receiptHostTime >= end }),
              start - before.receiptHostTime <= 0.15,
              after.receiptHostTime - end <= 0.15 else { return }
        let overlap = motion.filter { $0.receiptHostTime >= before.receiptHostTime &&
            $0.receiptHostTime <= after.receiptHostTime }
        guard overlap.count >= 8,
              overlap.allSatisfy({ $0.epoch == epoch && $0.angularSpeed <= .pi/36 }),
              let sensorMean = Self.mean(overlap.map { center.sensorSign * $0.yawRadians }),
              let cameraMean = Self.mean(camera.map { center.cameraSign * $0.yawRadians }),
              overlap.allSatisfy({ abs(Self.wrap(center.sensorSign * $0.yawRadians - sensorMean)) <= .pi/90 }),
              camera.allSatisfy({ abs(Self.wrap(center.cameraSign * $0.yawRadians - cameraMean)) <= .pi/90 }) else {
            status = "Hold your head still briefly"
            return
        }
        let candidate = Self.wrap(cameraMean - center.neutralYawRadians - sensorMean)
        if let offset, abs(Self.wrap(candidate - offset)) > .pi/36 {
            // A large correction may be an unnoticed sensor reset. Stop output
            // and demand a new independent burst; don't smooth across the jump.
            self.offset = nil
            camera.removeAll(keepingCapacity: true)
            status = "Checking your head direction again"
            return
        }
        offset = candidate
        alignmentRevision += 1
        camera.removeAll(keepingCapacity: true)
        status = "Ready"
    }
}
