import Foundation
import Combine
import CoreMedia

enum NotchPoseSource: String, Equatable, Sendable { case waiting, airPods, camera, cameraAndAirPods }

struct NotchPoseSnapshot: Equatable, Sendable {
    /// Physical-left yaw when direction is known; unsigned camera deviation otherwise.
    var yawDegrees: Double?
    var source: NotchPoseSource = .waiting
    var isScreenRelative = false
    var directionKnown = false
    var normalizedYaw: Double? { yawDegrees.map { min(1, max(-1, -$0 / 45)) } }
}

/// Display only. Vision's absolute forward-facing pose anchors this feedback,
/// never the arbitrary angle at which a check began. A previously observed
/// camera sign permits fresh AirPods deltas between scans. Without that sign,
/// show unsigned camera deviation; a centered hold cannot learn handedness.
struct NotchPoseEstimator {
    private var active = false
    private var fallbackReference: HeadingCameraCenter?
    private var epoch: UInt64?
    private var history: [HeadingMotionSample] = []
    private var pendingCamera: CameraAnchorFrame?
    private var cameraSign: Double?
    private var cameraID: String?
    private var configurationID: String?
    private var offset: Double?
    private var lastCameraTime: Double?
    private var cameraYaw: Double?
    private var cameraVisible = false
    private(set) var snapshot = NotchPoseSnapshot()

    mutating func begin(reference: HeadingCameraCenter?, sample: HeadingMotionSample?, now: Double) {
        self = Self(); active = true
        fallbackReference = reference
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
            stop(); return
        }
        if let epoch, epoch != sample.epoch { stop(); return }
        if let last = history.last {
            if sample == last { publish(now: now); return }
            guard sample.sourceTimestamp > last.sourceTimestamp,
                  sample.receiptHostTime > last.receiptHostTime else { stop(); return }
            if sample.receiptHostTime - last.receiptHostTime > 0.3 {
                history.removeAll(); pendingCamera = nil; offset = nil
            }
        }
        epoch = sample.epoch
        history.append(sample)
        history.removeAll { sample.receiptHostTime - $0.receiptHostTime > 1.5 }
        if history.count > 160 { history.removeFirst(history.count - 160) }
        pairCamera(now: now); publish(now: now)
    }

    mutating func updateCamera(_ frame: CameraAnchorFrame, visualCameraSign: Double? = nil, now: Double) {
        guard active else { return }
        guard frame.faceCount == 1, frame.detectionConfidence >= 0.7,
              frame.detectionConfidence <= 1, let yaw = frame.yawDegrees, yaw.isFinite,
              abs(yaw) <= 90, let pitch = frame.pitchDegrees, pitch.isFinite, abs(pitch) <= 20,
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
        if let cameraID, cameraID != frame.cameraID { stop(); return }
        if let configurationID, configurationID != frame.configurationID { stop(); return }
        if let lastCameraTime, capture <= lastCameraTime { publish(now: now); return }
        cameraID = frame.cameraID; configurationID = frame.configurationID
        let inherited = fallbackReference.flatMap { $0.cameraID == frame.cameraID && abs($0.cameraSign) == 1 ? $0.cameraSign : nil }
        let sign = visualCameraSign.flatMap { abs($0) == 1 ? $0 : nil } ?? inherited
        if sign != cameraSign { offset = nil }
        cameraSign = sign
        cameraVisible = true; lastCameraTime = capture
        cameraYaw = sign.map { $0 * yaw } ?? abs(yaw)
        pendingCamera = sign != nil ? frame : nil
        pairCamera(now: now); publish(now: now)
    }

    private mutating func pairCamera(now: Double) {
        guard let frame = pendingCamera, let capture = frame.captureHostTime,
              let yaw = frame.yawDegrees, let cameraSign else { return }
        guard now - capture <= 0.8 else { pendingCamera = nil; return }
        guard let before = history.last(where: { $0.receiptHostTime <= capture }),
              let after = history.first(where: { $0.receiptHostTime >= capture }),
              capture - before.receiptHostTime <= 0.15,
              after.receiptHostTime - capture <= 0.15 else { return }
        let duration = after.receiptHostTime - before.receiptHostTime
        let fraction = duration > 0 ? (capture - before.receiptHostTime) / duration : 0
        let sensorYaw = before.yawRadians + Self.wrap(after.yawRadians - before.yawRadians) * fraction
        // No learned arbitrary neutral subtraction: 13° remains 13° off center.
        offset = Self.wrap(cameraSign * yaw * .pi / 180 - sensorYaw)
        pendingCamera = nil
    }

    private mutating func publish(now: Double) {
        guard active, let latest = history.last,
              now >= latest.receiptHostTime, now - latest.receiptHostTime <= 0.65 else {
            snapshot = NotchPoseSnapshot(); return
        }
        let recentCamera = cameraVisible && lastCameraTime.map { now >= $0 && now - $0 <= 0.8 } == true
        if let offset {
            let yaw = Self.wrap(latest.yawRadians + offset) * 180 / .pi
            snapshot = .init(yawDegrees: (yaw * 4).rounded() / 4,
                source: recentCamera ? .cameraAndAirPods : .airPods,
                isScreenRelative: true, directionKnown: true)
        } else if recentCamera, let cameraYaw {
            snapshot = .init(yawDegrees: (cameraYaw * 4).rounded() / 4, source: .camera,
                isScreenRelative: true, directionKnown: cameraSign != nil)
        } else {
            // AirPods movement before the first camera frame cannot establish
            // whether the wearer started this check facing straight ahead.
            snapshot = NotchPoseSnapshot()
        }
    }
    private static func wrap(_ x: Double) -> Double { atan2(sin(x), cos(x)) }
}

/// Only the small rail observes high-frequency motion updates.
@MainActor final class NotchMotionFeedback: ObservableObject {
    @Published private(set) var snapshot = NotchPoseSnapshot()
    private var estimator = NotchPoseEstimator()
    private let now: () -> Double
    init(now: @escaping () -> Double = { CMClockGetTime(CMClockGetHostTimeClock()).seconds }) { self.now = now }
    func begin(reference: HeadingCameraCenter?, sample: HeadingMotionSample?) {
        estimator.begin(reference: reference, sample: sample, now: now()); publish()
    }
    func updateMotion(_ sample: HeadingMotionSample?) { estimator.updateMotion(sample, now: now()); publish() }
    func updateCamera(_ frame: CameraAnchorFrame, visualCameraSign: Double? = nil) {
        estimator.updateCamera(frame, visualCameraSign: visualCameraSign, now: now()); publish()
    }
    func stop() { estimator.stop(); publish() }
    private func publish() { if snapshot != estimator.snapshot { snapshot = estimator.snapshot } }
}
