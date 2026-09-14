import Foundation

@main struct NotchMotionFeedbackTests {
    static func main() {
        var checks = 0
        func check(_ result: Bool, _ message: String) {
            checks += 1
            if !result { fatalError(message) }
        }
        func sample(_ time: Double, _ degrees: Double, epoch: UInt64 = 1) -> HeadingMotionSample {
            .init(epoch: epoch, sourceTimestamp: time - 90, receiptHostTime: time,
                  yawRadians: degrees * .pi / 180, angularSpeed: 0.8)
        }
        func frame(_ time: Double, _ yaw: Double?, faces: Int = 1, confidence: Float = 0.95,
                   id: String = "camera", bounds: CGRect = CGRect(x: 0.35, y: 0.3, width: 0.3, height: 0.4)) -> CameraAnchorFrame {
            .init(cameraID: id, configurationID: "fixed", faceCount: faces,
                  yawDegrees: yaw, pitchDegrees: 0, rollDegrees: 0, detectionConfidence: confidence,
                  faceBounds: bounds, captureHostTime: time, receiptHostTime: time + 0.02,
                  processedHostTime: time + 0.03)
        }
        let reference = HeadingCameraCenter(cameraID: "camera", neutralYawRadians: 0,
            cameraSign: 1, sensorSign: 1, revision: 1)
        var tracker = NotchPoseEstimator()
        tracker.begin(reference: reference, sample: sample(100, 0), now: 100)
        check(tracker.snapshot.yawDegrees == 0 && !tracker.snapshot.isScreenRelative,
              "Before a camera observation zero means relative movement, not screen center")
        // Same face rectangle throughout: rotation must move the rail without
        // waiting for Vision to produce a differently positioned face box.
        for i in 1...10 {
            let time = 100 + Double(i) * 0.02
            tracker.updateMotion(sample(time, Double(i)), now: time)
        }
        check(tracker.snapshot.yawDegrees == 10 && tracker.snapshot.normalizedYaw! < -0.2,
              "Head rotation moves the indicator at AirPods cadence with no camera/frame translation")
        tracker.updateCamera(frame(100.18, 19), now: 100.21)
        check(tracker.snapshot.yawDegrees == 20 && tracker.snapshot.source == .cameraAndAirPods,
              "Camera yaw at capture time anchors the current sensor delta")
        check(tracker.snapshot.isScreenRelative, "A matched saved camera reference enables screen-relative labeling")
        for i in 11...20 {
            let time = 100 + Double(i) * 0.02
            tracker.updateMotion(sample(time, Double(i)), now: time)
            check(abs(tracker.snapshot.yawDegrees! - Double(i + 10)) < 0.01,
                  "Every fresh 50 Hz motion sample advances between 3 Hz camera checks")
        }
        let beforeLost = tracker.snapshot.yawDegrees
        tracker.updateCamera(frame(100.38, nil, faces: 0), now: 100.41)
        check(tracker.snapshot.yawDegrees == beforeLost && tracker.snapshot.source == .airPods,
              "Missing face cannot snap the moving/turned rail to center")
        tracker.updateMotion(sample(100.42, 22), now: 100.42)
        check(tracker.snapshot.yawDegrees == 32, "Headphone feedback keeps moving while camera waits for a face")
        tracker.updateCamera(frame(100.40, -15, faces: 2), now: 100.43)
        check(tracker.snapshot.yawDegrees == 32, "Multiple faces cannot re-anchor the display")
        tracker.updateCamera(frame(100.40, -15, id: "different-camera"), now: 100.43)
        check(tracker.snapshot.yawDegrees == 32 && tracker.snapshot.source == .airPods,
              "A different camera cannot overwrite the visual reference or claim a paired camera source")
        tracker.updateMotion(nil, now: 100.44)
        check(tracker.snapshot.yawDegrees == nil && tracker.snapshot.normalizedYaw == nil,
              "Missing AirPods show no marker rather than a false centered marker")
        tracker.updateMotion(sample(100.46, 30), now: 100.46)
        check(tracker.snapshot.yawDegrees == nil, "Lost stream needs an explicit new burst before feedback resumes")

        tracker.begin(reference: nil, sample: sample(110, 179), now: 110)
        tracker.updateMotion(sample(110.02, -179), now: 110.02)
        check(tracker.snapshot.yawDegrees == 2, "Rotation crosses the quaternion yaw wrap without a full rail jump")
        tracker.updateCamera(frame(110.01, -30), now: 110.04)
        check(tracker.snapshot.yawDegrees == 2 && !tracker.snapshot.isScreenRelative,
              "Unlearned camera sign cannot introduce an arbitrary direction mapping")
        tracker.updateMotion(sample(110.04, -177, epoch: 2), now: 110.04)
        check(tracker.snapshot.yawDegrees == nil, "A sensor epoch change discards visual anchoring")

        tracker.begin(reference: reference, sample: nil, now: 120)
        tracker.updateMotion(sample(120.02, 10), now: 120.02)
        check(tracker.snapshot.yawDegrees == 0, "A new burst can wait for its first motion sample")
        // Camera capture slightly precedes the next independently delivered
        // motion sample: retain it until the actual bracketing sample arrives.
        tracker.updateCamera(frame(120.03, 25), now: 120.06)
        check(!tracker.snapshot.isScreenRelative, "An unpaired camera timestamp is not assumed matched")
        tracker.updateMotion(sample(120.06, 14), now: 120.06)
        check(tracker.snapshot.isScreenRelative && tracker.snapshot.yawDegrees == 28,
              "Delayed after-sample completes capture-time interpolation without dropping camera evidence")
        tracker.updateMotion(sample(120.40, 25), now: 120.40)
        check(tracker.snapshot.yawDegrees == 15 && !tracker.snapshot.isScreenRelative,
              "A UI delivery gap drops the visual anchor but does not permanently freeze same-epoch movement")
        tracker.updateMotion(sample(120.42, 26), now: 120.42)
        check(tracker.snapshot.yawDegrees == 16, "Subsequent fresh movement still updates after a gap")
        tracker.updateMotion(sample(120.44, 27), now: 121.2)
        check(tracker.snapshot.yawDegrees == nil, "Stale sensor receipts cannot animate live feedback")
        tracker.stop()
        tracker.updateCamera(frame(120.79, 30), now: 120.82)
        check(tracker.snapshot.yawDegrees == nil, "Late camera results cannot revive a stopped preview")
        print("Passed \(checks) camera-anchored live notch motion checks")
    }
}
