import Foundation
import Combine
import CoreMedia

enum NotchPoseSource: String, Equatable, Sendable { case waiting, airPods, cameraAndAirPods }

struct NotchPoseSnapshot: Equatable, Sendable {
    /// Positive is physical left, matching the existing AirVeil motion convention.
    var yawDegrees: Double?
    var source: NotchPoseSource = .waiting
    var isScreenRelative = false
    var normalizedYaw: Double? { yawDegrees.map { min(1, max(-1, -$0 / 45)) } }
}

/// Display feedback only. This never accepts calibration, changes a saved
/// center, or supplies a heading to the desktop effect. Camera estimates set
/// the visual reference; fresh same-epoch AirPods deltas move it between scans.
struct NotchPoseEstimator {
    private var active = false
    private var reference: HeadingCameraCenter?
    private var epoch: UInt64?
    private var origin: Double?
    private var history: [HeadingMotionSample] = []
    private var pendingCamera: CameraAnchorFrame?
    private var offset: Double?
    private var lastCameraTime: Double?
    private var cameraVisible = false
    private(set) var snapshot = NotchPoseSnapshot()

    mutating func begin(reference: HeadingCameraCenter?, sample: HeadingMotionSample?, now: Double) {
        self = Self()
        active = true
        self.reference = reference
        if let sample { updateMotion(sample, now: now) }
    }
    mutating func stop() { self = Self() }

    mutating func updateMotion(_ sample: HeadingMotionSample?, now: Double) {
        guard active else { return }
        guard let sample, now.isFinite, sample.receiptHostTime.isFinite,
              sample.sourceTimestamp.isFinite, sample.sourceTimestamp >= 0,
              sample.yawRadians.isFinite, sample.angularSpeed.isFinite,
              sample.angularSpeed >= 0, sample.receiptHostTime >= 0,
              now >= sample.receiptHostTime, now - sample.receiptHostTime <= 0.65 else {
            // A missing pose is not a centered pose.
            stop(); return
        }
        if let epoch, epoch != sample.epoch { stop(); return }
        if let last = history.last {
            if sample == last { publish(now: now); return }
            guard sample.sourceTimestamp > last.sourceTimestamp,
                  sample.receiptHostTime > last.receiptHostTime else {
                stop(); return
            }
            if sample.receiptHostTime - last.receiptHostTime > 0.3 {
                // A UI delivery gap must not freeze the rail for the rest of
                // a live check. Drop its camera anchor and re-pair; preserve
                // the relative movement origin within this same sensor epoch.
                history.removeAll(); pendingCamera = nil; offset = nil
                lastCameraTime = nil; cameraVisible = false
            }
        }
        epoch = sample.epoch
        if origin == nil { origin = sample.yawRadians }
        history.append(sample)
        history.removeAll { sample.receiptHostTime - $0.receiptHostTime > 1.5 }
        if history.count > 160 { history.removeFirst(history.count - 160) }
        pairCamera(now: now)
        publish(now: now)
    }

    mutating func updateCamera(_ frame: CameraAnchorFrame, now: Double) {
        guard active else { return }
        guard frame.faceCount == 1, frame.detectionConfidence >= 0.7,
              frame.detectionConfidence <= 1, let yaw = frame.yawDegrees, yaw.isFinite,
              abs(yaw) <= 45, let pitch = frame.pitchDegrees, pitch.isFinite, abs(pitch) <= 20,
              let roll = frame.rollDegrees, roll.isFinite, abs(roll) <= 15,
              let bounds = frame.faceBounds, bounds.width >= 0.12, bounds.height >= 0.12,
              bounds.width <= 1, bounds.height <= 1,
              let capture = frame.captureHostTime, capture.isFinite,
              capture >= 0, now >= frame.receiptHostTime,
              frame.receiptHostTime >= capture, now - capture <= 0.8,
              frame.receiptHostTime - capture <= 0.5 else {
            pendingCamera = nil; cameraVisible = false
            publish(now: now); return
        }
        // Until the camera sign is learned, show relative headphone movement
        // explicitly. Face-box translation is never substituted for head yaw.
        guard let reference, frame.cameraID == reference.cameraID,
              reference.neutralYawRadians.isFinite,
              abs(reference.cameraSign) == 1, abs(reference.sensorSign) == 1 else {
            pendingCamera = nil; cameraVisible = false
            publish(now: now); return
        }
        cameraVisible = true
        if let lastCameraTime, capture <= lastCameraTime { return }
        pendingCamera = frame
        pairCamera(now: now)
        publish(now: now)
    }

    private mutating func pairCamera(now: Double) {
        guard let frame = pendingCamera, let capture = frame.captureHostTime,
              let cameraYaw = frame.yawDegrees, let reference else { return }
        guard now - capture <= 0.8 else { pendingCamera = nil; return }
        // Pair at capture time, not the later Vision/UI receipt. This remains
        // visual interpolation; the fusion engine retains its stationary gates.
        guard let before = history.last(where: { $0.receiptHostTime <= capture }),
              let after = history.first(where: { $0.receiptHostTime >= capture }),
              capture - before.receiptHostTime <= 0.15,
              after.receiptHostTime - capture <= 0.15 else { return }
        let duration = after.receiptHostTime - before.receiptHostTime
        let fraction = duration > 0 ? (capture - before.receiptHostTime) / duration : 0
        let sensorYaw = before.yawRadians + Self.wrap(after.yawRadians - before.yawRadians) * fraction
        let candidate = Self.wrap(reference.cameraSign * cameraYaw * .pi / 180 - reference.neutralYawRadians - reference.sensorSign * sensorYaw)
        if let previous = offset {
            // Correct slow visual drift without snapping at the 3 Hz scan cadence.
            offset = Self.wrap(previous + 0.25 * Self.wrap(candidate - previous))
        } else { offset = candidate }
        lastCameraTime = capture
        pendingCamera = nil
    }

    private mutating func publish(now: Double) {
        guard active, let latest = history.last, let origin,
              now >= latest.receiptHostTime, now - latest.receiptHostTime <= 0.65 else {
            snapshot = NotchPoseSnapshot(); return
        }
        let radians: Double
        if let offset, let reference { radians = Self.wrap(reference.sensorSign * latest.yawRadians + offset) }
        else { radians = Self.wrap(latest.yawRadians - origin) }
        let recentCamera = cameraVisible && lastCameraTime.map { now >= $0 && now - $0 <= 0.8 } == true
        snapshot = NotchPoseSnapshot(yawDegrees: (radians * 180 / .pi * 4).rounded() / 4,
            source: recentCamera ? .cameraAndAirPods : .airPods, isScreenRelative: offset != nil)
    }
    private static func wrap(_ x: Double) -> Double { atan2(sin(x), cos(x)) }
}

/// Observed only by the small rail view. 50 Hz motion never republishes the
/// entire coordinator/settings hierarchy or restarts a shell transition.
@MainActor final class NotchMotionFeedback: ObservableObject {
    @Published private(set) var snapshot = NotchPoseSnapshot()
    private var estimator = NotchPoseEstimator()
    private let now: () -> Double
    init(now: @escaping () -> Double = { CMClockGetTime(CMClockGetHostTimeClock()).seconds }) { self.now = now }
    func begin(reference: HeadingCameraCenter?, sample: HeadingMotionSample?) {
        estimator.begin(reference: reference, sample: sample, now: now()); publish()
    }
    func updateMotion(_ sample: HeadingMotionSample?) { estimator.updateMotion(sample, now: now()); publish() }
    func updateCamera(_ frame: CameraAnchorFrame) { estimator.updateCamera(frame, now: now()); publish() }
    func stop() { estimator.stop(); publish() }
    private func publish() { if snapshot != estimator.snapshot { snapshot = estimator.snapshot } }
}
