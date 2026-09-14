import Foundation

@main struct HeadingFusionTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { fatalError("FAIL: \(message)") }
        }
        func rad(_ degrees: Double) -> Double { degrees * .pi/180 }
        func near(_ actual: Double?, _ degrees: Double) -> Bool {
            guard let actual else { return false }
            return abs(HeadingFusionEngine.wrap(actual-rad(degrees))) < 1e-8
        }
        func pose(_ t: Double, yaw: Double, generation: UInt64 = 1,
                  faces: Int = 1, pitch: Double = 0, roll: Double = 0,
                  lag: Double = 0.05, id: String = "fixed") -> HeadingCameraSample {
            HeadingCameraSample(generation: generation, cameraID: id,
                captureHostTime: t, receiptHostTime: t+lag, yawRadians: rad(yaw),
                pitchRadians: rad(pitch), rollRadians: rad(roll), confidence: 0.95, faceCount: faces)
        }
        func motion(_ t: Double, yaw: Double, epoch: UInt64 = 1,
                    speed: Double = 0) -> HeadingMotionSample {
            HeadingMotionSample(epoch: epoch, sourceTimestamp: t-5,
                receiptHostTime: t, yawRadians: rad(yaw), angularSpeed: rad(speed))
        }
        func configure(_ cameraSign: Double = 1, neutral: Double = 4,
                       sensorSign: Double = 1) -> HeadingFusionEngine {
            var engine = HeadingFusionEngine()
            engine.configure(center: HeadingCameraCenter(cameraID: "fixed",
                neutralYawRadians: rad(neutral), cameraSign: cameraSign,
                sensorSign: sensorSign, revision: 7))
            return engine
        }
        // Real engine receives separate acquisition and camera events. Camera
        // delivery stops before post-capture motion proves the overlap window.
        func burst(_ engine: inout HeadingFusionEngine, start: Double,
                   sensor: Double, camera: Double, epoch: UInt64 = 1,
                   generation: UInt64 = 1, speed: Double = 0,
                   faces: Int = 1, cameraID: String = "fixed") {
            for i in 0...30 {
                let t = start+Double(i)*0.05
                engine.addMotion(motion(t, yaw: sensor, epoch: epoch, speed: speed))
                if i >= 6 && i <= 18 && i % 2 == 0 {
                    engine.addCamera(pose(t-0.05, yaw: camera, generation: generation,
                        faces: faces, id: cameraID), now: t)
                }
            }
        }
        var engine = configure()
        check(engine.heading(now: 10) == nil, "Stored center cannot initialize current sensor alignment")
        burst(&engine, start: 10, sensor: 0, camera: 4)
        check(near(engine.heading(now: 11.5), 0), "Initial stationary camera burst aligns to saved center")
        check(engine.alignmentRevision == 1, "One admitted burst commits one alignment")
        check(engine.heading(now: 12.2) == nil, "Freshness checked when consuming heading")
        engine.addMotion(motion(11.6, yaw: 35))
        check(near(engine.heading(now: 11.6), 35), "Fast inertial turn preserves fixed offset between bursts")

        engine.invalidate()
        burst(&engine, start: 20, sensor: -8, camera: 39, epoch: 2, generation: 2)
        check(near(engine.heading(now: 21.5), 35), "Rewear at35 degrees restores35, never chooses newzero")
        engine.addMotion(motion(21.6, yaw: -43, epoch: 2))
        check(near(engine.heading(now: 21.6), 0), "Return to original screen direction restores originalzero")
        check(engine.alignmentRevision == 2, "Reanchor revision is distinct from persisted center revision")
        engine.addMotion(motion(21.7, yaw: -8, epoch: 2))
        for i in 1...100 { engine.addMotion(motion(21.7+Double(i)*0.1, yaw: -8, epoch: 2)) }
        check(near(engine.heading(now: 31.7), 35), "Ten-second held turn never decays towardzero")
        let beforeEpoch = engine.alignmentRevision
        engine.addMotion(motion(31.8, yaw: 0, epoch: 3))
        check(engine.heading(now: 31.8) == nil && engine.alignmentRevision == beforeEpoch,
              "Source epoch change immediately removes old offset")

        var mirrored = configure(-1, neutral: -4)
        burst(&mirrored, start: 40, sensor: 0, camera: -31)
        check(near(mirrored.heading(now: 41.5), 35), "Camera sign and signed neutral applied consistently")
        var sensorInverted = configure(1, neutral: 4, sensorSign: -1)
        burst(&sensorInverted, start: 50, sensor: 8, camera: 39)
        sensorInverted.addMotion(motion(51.6, yaw: 43))
        check(near(sensorInverted.heading(now: 51.6), 0), "Sensor sign is independent from camera mirroring")
        check(HeadingFusionEngine.learnedCameraSign(cameraDelta: rad(-20), sensorDelta: rad(20)) == -1,
              "Observed same-epoch physical turn learns camera sign")
        check(HeadingFusionEngine.learnedCameraSign(cameraDelta: rad(2), sensorDelta: rad(2)) == nil,
              "Stillness cannot learn a sign")
        check(HeadingFusionEngine.learnedCameraSign(cameraDelta: .nan, sensorDelta: 1) == nil,
              "Invalid sign calibration rejected")
        check(HeadingFusionEngine.learnedCameraSign(cameraDelta: rad(80), sensorDelta: rad(15)) == nil,
              "Inconsistent sensor/camera changes reject sign calibration")

        var wrapping = configure(1, neutral: 0)
        burst(&wrapping, start: 60, sensor: 179, camera: 20)
        wrapping.addMotion(motion(61.6, yaw: -179))
        check(near(wrapping.heading(now: 61.6), 22), "Yaw wrap uses short arc across179 to minus179")
        var moving = configure()
        burst(&moving, start: 70, sensor: 10, camera: 14, speed: 30)
        check(moving.heading(now: 71.5) == nil, "Motion prevents approximate receipt-window anchoring")
        var multiple = configure()
        burst(&multiple, start: 80, sensor: 10, camera: 14, faces: 2)
        check(multiple.heading(now: 81.5) == nil, "Multiple faces never choose arbitrary wearer")
        burst(&multiple, start: 90, sensor: 10, camera: 14, cameraID: "different")
        check(multiple.heading(now: 91.5) == nil, "Different camera cannot reuse geometric center")
        check(!HeadingFusionEngine.isCameraSampleUsable(pose(100, yaw: 20, lag: 1), now: 101),
              "Callback receipt cannot conceal an old capture timestamp")
        check(!HeadingFusionEngine.isCameraSampleUsable(pose(100, yaw: 20), now: 99),
              "Future frame timestamps rejected")
        check(!HeadingFusionEngine.isCameraSampleUsable(pose(100, yaw: 20, pitch: 30), now: 100.1),
              "Large pitch outside planar validation rejected")
        check(!HeadingFusionEngine.isCameraSampleUsable(pose(100, yaw: 20, roll: 30), now: 100.1),
              "Large roll outside planar validation rejected")
        check(!HeadingFusionEngine.isCameraSampleUsable(pose(100, yaw: .nan), now: 100.1),
              "Missing or invalid numerical yaw never meanszero")

        var setup = HeadingFusionEngine()
        for i in 0...20 { setup.addMotion(motion(110+Double(i)*0.05, yaw: 27)) }
        check(setup.stableMotionYaw(atCameraCaptureTime: 110.9, now: 111) == nil,
              "Setup requires post-capture evidence, not only past stillness")
        check(near(setup.stableMotionYaw(atCameraCaptureTime: 110.7, now: 111), 27),
              "Setup helper returns off-axis rawpose after full overlap")
        setup.addMotion(motion(111.5, yaw: 27))
        check(setup.stableMotionYaw(atCameraCaptureTime: 111.3, now: 111.5) == nil,
              "Main delivery gap cannot count as continuous stillness")

        var invalidation = configure()
        burst(&invalidation, start: 120, sensor: 0, camera: 4)
        invalidation.invalidate()
        check(invalidation.heading(now: 121.5) == nil, "Explicit cancellation clears output immediately")
        invalidation.addMotion(motion(121.6, yaw: 0))
        check(invalidation.heading(now: 121.6) == nil, "A lone new sensor pose cannot revive canceled alignment")
        burst(&invalidation, start: 130, sensor: 0, camera: 4)
        invalidation.addMotion(HeadingMotionSample(epoch: 1, sourceTimestamp: 1,
            receiptHostTime: 131.6, yawRadians: 0, angularSpeed: 0))
        check(invalidation.heading(now: 131.6) == nil, "Source clock reversal invalidates the old alignment")
        burst(&invalidation, start: 140, sensor: 0, camera: 4, epoch: 2)
        invalidation.configure(center: nil)
        check(invalidation.heading(now: 141.5) == nil, "Removing configuration disables fused output")
        var sparse = configure()
        for i in 0...90 {
            let t = 150+Double(i)/60
            sparse.addMotion(motion(t, yaw: -8, epoch: 5))
            if [20, 40, 60].contains(i) {
                // Exactly3fps, capture120ms before processing, callback30ms
                // after capture. Processing completion never becomes frame time.
                let frame = HeadingCameraSample(generation: 5, cameraID: "fixed",
                    captureHostTime: t-0.12, receiptHostTime: t-0.09,
                    yawRadians: rad(39), pitchRadians: 0, rollRadians: 0,
                    confidence: 0.95, faceCount: 1)
                sparse.addCamera(frame, now: t)
            }
        }
        check(near(sparse.heading(now: 151.5), 35) && sparse.alignmentRevision == 1,
              "Exactly3fps with delayed analysis still produces one valid off-axis anchor")
        sparse.addCamera(pose(151.45, yaw: 4, generation: 4), now: 151.5)
        check(near(sparse.heading(now: 151.5), 35), "Retired camera generation cannot replace alignment")
        for i in 1...30 {
            let t = 151.5+Double(i)*0.05
            sparse.addMotion(motion(t, yaw: -8, epoch: 5))
            if [6, 13, 20].contains(i) {
                sparse.addCamera(pose(t-0.05, yaw: 4, generation: 6), now: t)
            }
        }
        check(sparse.heading(now: 153) == nil,
              "Large same-epoch offset disagreement pauses instead of smoothing a falsezero")
        var discontinuous = configure()
        burst(&discontinuous, start: 160, sensor: 0, camera: 4)
        discontinuous.addMotion(motion(162, yaw: 0))
        check(discontinuous.heading(now: 162) == nil,
              "More than300ms motion receipt gap invalidates fusion despite fresh lastsample")
        var coalesced = configure()
        burst(&coalesced, start: 160, sensor: 7, camera: 4)
        let coalescedRevision = coalesced.alignmentRevision
        coalesced.addMotion(HeadingMotionSample(epoch: 1, sourceTimestamp: 157, receiptHostTime: 162,
            yawRadians: rad(27), angularSpeed: 0, acquisitionContinuityVerified: true))
        check(near(coalesced.heading(now: 162), 20) && coalesced.alignmentRevision == coalescedRevision,
              "Verified continuous acquisition survives a UI delivery gap without recentering the current twenty-degree turn")
        check(coalesced.stableMotionYaw(atCameraCaptureTime: 161.8, now: 162) == nil,
              "Coalesced delivery still cannot fabricate a camera stationary interval")
        coalesced.addMotion(HeadingMotionSample(epoch: 2, sourceTimestamp: 157.02, receiptHostTime: 162.02,
            yawRadians: rad(27), angularSpeed: 0, acquisitionContinuityVerified: true))
        check(coalesced.heading(now: 162.02) == nil, "Verified delivery in a new physical epoch cannot retain the prior offset")
        for reversal in ["source", "receipt"] {
            var tested = configure()
            burst(&tested, start: 160, sensor: 7, camera: 4)
            tested.addMotion(HeadingMotionSample(epoch: 1, sourceTimestamp: reversal == "source" ? 1 : 157,
                receiptHostTime: reversal == "receipt" ? 160 : 162, yawRadians: rad(27), angularSpeed: 0,
                acquisitionContinuityVerified: true))
            check(tested.heading(now: 162) == nil, "A verified flag cannot bypass a \(reversal) clock reversal")
        }
        let facingReference = HeadingCameraCenter(cameraID: "fixed", neutralYawRadians: 0,
            cameraSign: 0, sensorSign: 1, revision: 8, mode: .facingCamera)
        var noLegacyBypass = HeadingFusionEngine()
        noLegacyBypass.configure(center: facingReference)
        burst(&noLegacyBypass, start: 170, sensor: 25, camera: 15)
        check(noLegacyBypass.heading(now: 171.5) == nil && noLegacyBypass.alignmentRevision == 0,
              "The legacy off-axis entry point cannot align a facing-camera reference")
        func facingBurst(_ engine: inout HeadingFusionEngine, start: Double,
                         sensor: Double, cameraYaw: Double, speed: Double = 0) -> Int {
            var commits = 0
            for i in 0...80 {
                let t = start + Double(i) * 0.02
                engine.addMotion(motion(t, yaw: sensor, speed: speed))
                // Each camera frame is submitted only after the actual later
                // motion sample covers the 200ms pairing guard.
                if [45, 62, 79].contains(i) {
                    if engine.addCenteredCamera(pose(t - 0.21, yaw: cameraYaw), reference: facingReference, now: t) { commits += 1 }
                }
            }
            return commits
        }
        for yaw in [-15.0, -13.0, -5.1, 5.1, 13.0, 15.0] {
            var facing = HeadingFusionEngine()
            check(facingBurst(&facing, start: 180, sensor: 25, cameraYaw: yaw) == 0 && facing.heading(now: 181.6) == nil,
                  "Centered route rejects every camera sample outside five degrees without adopting its neutral")
        }
        for yaw in [-5.0, 0.0, 5.0] {
            var facing = HeadingFusionEngine()
            check(facingBurst(&facing, start: 190, sensor: 25, cameraYaw: yaw) == 1,
                  "One centered stationary batch atomically installs the reference and alignment without a restart")
            check(near(facing.heading(now: 191.6), 0), "Only a verified facing-center pose sets the sensor zero")
            facing.addMotion(motion(191.7, yaw: 40))
            check(near(facing.heading(now: 191.7), 15), "Following AirPods motion keeps the real turn instead of rebasing it")
        }
        var facingMoving = HeadingFusionEngine()
        check(facingBurst(&facingMoving, start: 200, sensor: 25, cameraYaw: 0, speed: 30) == 0,
              "Camera-centered pose alone cannot satisfy moving AirPods")
        var explicitReplacement = configure(1, neutral: 15)
        check(facingBurst(&explicitReplacement, start: 210, sensor: 25, cameraYaw: 0) == 1 && near(explicitReplacement.heading(now: 211.6), 0),
              "A facing-center batch replaces a legacy reference only by the explicit new route")
        let encoded = try! JSONEncoder().encode(facingReference)
        let decoded = try! JSONDecoder().decode(HeadingCameraCenter.self, from: encoded)
        check(decoded.mode == .facingCamera && decoded.cameraSign == 0, "Stored mode distinguishes a facing check from a learned camera sign")
        print("PASS: \(checks) heading fusion assertions; synthetic inputs only, no camera or sensor access")
    }
}
