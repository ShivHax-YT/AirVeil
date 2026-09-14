import Foundation

@main struct NotchMotionFeedbackTests {
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { fatalError(message) }
        }
        func sample(_ t: Double, _ yaw: Double, epoch: UInt64 = 1) -> HeadingMotionSample {
            .init(epoch: epoch, sourceTimestamp: t - 90, receiptHostTime: t,
                  yawRadians: yaw * .pi / 180, angularSpeed: 0.8)
        }
        func frame(_ t: Double, _ yaw: Double?, faces: Int = 1, id: String = "camera", config: String = "fixed") -> CameraAnchorFrame {
            .init(cameraID: id, configurationID: config, faceCount: faces,
                  yawDegrees: yaw, pitchDegrees: 0, rollDegrees: 0, detectionConfidence: 0.95,
                  faceBounds: CGRect(x: 0.35, y: 0.3, width: 0.3, height: 0.4),
                  captureHostTime: t, receiptHostTime: t + 0.02, processedHostTime: t + 0.03)
        }
        // The old chosen neutral must not redefine camera-forward feedback.
        let legacy = HeadingCameraCenter(cameraID: "camera", neutralYawRadians: 15 * .pi / 180,
            cameraSign: 1, sensorSign: 1, revision: 1)
        var tracker = NotchPoseEstimator()
        tracker.begin(reference: legacy, sample: sample(100, 30), now: 100)
        check(tracker.snapshot.yawDegrees == nil, "Starting a check at an arbitrary angle cannot display a false zero")
        tracker.updateMotion(sample(100.02, 31), now: 100.02)
        tracker.updateCamera(frame(100.02, 13), now: 100.05)
        check(tracker.snapshot.yawDegrees == 13 && tracker.snapshot.directionKnown,
              "A measured13degree turn stays13degrees off center despite a legacy15degree savedneutral")
        check(tracker.snapshot.source == .cameraAndAirPods, "Matched known visual sign combines camera and AirPods")
        for i in 1...10 {
            let t = 100.02 + Double(i) * 0.02
            tracker.updateMotion(sample(t, 31 + Double(i)), now: t)
            check(tracker.snapshot.yawDegrees == 13 + Double(i),
                  "Every50Hz head sample moves the indicator between fixed-bounds camera scans")
        }
        tracker.updateCamera(frame(100.20, nil, faces: 0), now: 100.23)
        check(tracker.snapshot.yawDegrees == 23 && tracker.snapshot.source == .airPods,
              "Lost face keeps headphone movement without pretending centered or freshly camera verified")
        tracker.updateMotion(sample(100.24, 42), now: 100.24)
        check(tracker.snapshot.yawDegrees == 24, "The indicator continues moving through face loss")
        tracker.updateMotion(nil, now: 100.26)
        check(tracker.snapshot.yawDegrees == nil, "Missing motion hides the marker")
        tracker.updateMotion(sample(100.28, 43), now: 100.28)
        check(tracker.snapshot.yawDegrees == nil, "A stopped stream cannot revive without a new check")

        tracker.begin(reference: nil, sample: sample(110, 179), now: 110)
        tracker.updateCamera(frame(110, -15), now: 110.03)
        check(tracker.snapshot.yawDegrees == 15 && !tracker.snapshot.directionKnown && tracker.snapshot.source == .camera,
              "Unknown Vision sign shows unsigned15degree deviation instead of inventing physical left/right")
        tracker.updateCamera(frame(110.04, -4), now: 110.07)
        check(tracker.snapshot.yawDegrees == 4, "Unsigned feedback visibly approaches the five-degree center region")
        tracker.updateCamera(frame(110.06, nil, faces: 2), now: 110.09)
        check(tracker.snapshot.yawDegrees == nil, "Unknown-sign face loss does not leave a false camera center marker")
        tracker.updateMotion(sample(110.10, -179), now: 110.10)
        tracker.updateCamera(frame(110.10, -3), visualCameraSign: -1, now: 110.13)
        check(tracker.snapshot.yawDegrees == 3 && tracker.snapshot.directionKnown,
              "An explicitly matched observed sign enables camera plus AirPods direction")
        tracker.updateMotion(sample(110.12, -177), now: 110.12)
        check(tracker.snapshot.yawDegrees == 5, "The sensor yaw wrap follows its short arc")
        tracker.updateMotion(sample(110.14, -175, epoch: 2), now: 110.14)
        check(tracker.snapshot.yawDegrees == nil, "A sensor epoch change invalidates visual pairing")

        tracker.begin(reference: nil, sample: nil, now: 120)
        tracker.updateMotion(sample(120.02, 10), now: 120.02)
        tracker.updateCamera(frame(120.03, 25), visualCameraSign: 1, now: 120.06)
        check(tracker.snapshot.yawDegrees == 25 && tracker.snapshot.source == .camera,
              "Before actual future motion arrives, show the absolute camera angle without claiming sensor pairing")
        tracker.updateMotion(sample(120.06, 14), now: 120.06)
        check(tracker.snapshot.yawDegrees == 28 && tracker.snapshot.source == .cameraAndAirPods,
              "Pending capture-time interpolation completes when the actual future motion arrives")
        tracker.updateMotion(sample(120.40, 25), now: 120.40)
        check(tracker.snapshot.yawDegrees == 25 && tracker.snapshot.source == .camera,
              "A delivery gap drops the sensor offset and falls back to the recent camera angle")
        tracker.updateCamera(frame(120.40, 10), visualCameraSign: 1, now: 120.43)
        tracker.updateMotion(sample(120.42, 26), now: 120.42)
        check(tracker.snapshot.yawDegrees == 11, "Fresh pairing resumes reactive motion after a delivery gap")
        tracker.updateMotion(sample(120.44, 27), now: 121.2)
        check(tracker.snapshot.yawDegrees == nil, "Stale motion cannot animate a live center indicator")

        for changed in ["camera", "configuration"] {
            tracker.begin(reference: legacy, sample: sample(130, 0), now: 130)
            tracker.updateCamera(frame(130, 4), now: 130.03)
            tracker.updateCamera(frame(130.04, 0, id: changed == "camera" ? "new" : "camera",
                                       config: changed == "configuration" ? "new" : "fixed"), now: 130.07)
            check(tracker.snapshot.yawDegrees == nil, "A changed\(changed) cannot reuse a visual reference")
        }
        tracker.stop(); tracker.updateCamera(frame(130.10, 0), now: 130.13)
        check(tracker.snapshot.yawDegrees == nil, "Late camera callbacks cannot revive stopped feedback")
        print("PASS: \(checks) absolute-center notch feedback checks")
    }
}
