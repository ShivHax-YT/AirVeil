import Foundation
import CoreMotion

@main
struct MotionDeliveryTests {
    static func main() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !value() { fatalError("FAIL: \(message)") }
        }
        func reading(_ sourceTime: Double, _ receipt: Double, yaw: Double = 0,
                     source: CMDeviceMotion.SensorLocation = .headphoneLeft) -> MotionReading {
            // No Core Motion manager, hardware permission, or mutable attitude
            // is needed to test the actual timestamp/continuity delivery path.
            MotionReading(attitude: nil, timestamp: sourceTime, receipt: receipt,
                          quaternion: VeilQuaternion(x: 0, y: 0, z: sin(yaw/2), w: cos(yaw/2)),
                          speed: 0, source: source)
        }

        let uiStall = MotionDeliveryBuffer()
        check(uiStall.offer(reading(1, 10)), "First sample requests drain")
        _ = uiStall.take()
        var scheduled = 0
        // Simulate a blocked UI while the acquisition queue receives one second
        // of genuinely fresh samples. UI consumption must not add sensor lag.
        for i in 1...100 {
            let elapsed = Double(i)/100
            if uiStall.offer(reading(1+elapsed, 10+elapsed)) { scheduled += 1 }
        }
        let latest = uiStall.take()!
        check(scheduled == 1, "UI backlog schedules at most one drain")
        check(latest.reading?.timestamp == 2 && latest.reading?.receipt == 11, "UI receives latest acquisition timestamp")
        check(latest.continuityIssue == nil && latest.addedLag < 1e-9, "UI stall is not sensor lag or lost continuity")
        check(latest.stableSince == 10, "Stable samples remain stable across UI blockage")
        check(abs(latest.sampleRate-100) < 1e-8, "Cadence measures all acquired samples rather than UI drains")
        check(uiStall.take() == nil, "No replay of obsolete poses")
        check(uiStall.offer(reading(2.01, 11.01)), "Next sample schedules a fresh drain")

        let trackingMode = MotionDeliveryBuffer()
        check(trackingMode.offer(reading(1, 10)), "Tracking-mode first callback schedules main drain")
        for i in 1...20 {
            _ = trackingMode.take(releaseNotification: false)
            let elapsed = Double(i)/100
            check(!trackingMode.offer(reading(1+elapsed, 10+elapsed)),
                  "Watchdog consumption does not queue extra main tasks")
        }
        _ = trackingMode.take()
        check(trackingMode.offer(reading(1.21, 10.21)), "Actual main task releases scheduling token")

        let outage = MotionDeliveryBuffer()
        outage.offer(reading(1, 10))
        _ = outage.take()
        outage.offer(reading(2, 11))
        outage.offer(reading(2.01, 11.01))
        let recovered = outage.take()!
        check(recovered.reading?.timestamp == 2.01, "Newest post-gap sample retained")
        check(recovered.continuityIssue?.contains("sensor gap") == true, "Real acquisition gap remains sticky after recovery")
        check(recovered.stableSince == 11, "Real gap resets stability; it does not create a new reference pose")

        let lagged = MotionDeliveryBuffer()
        lagged.offer(reading(1, 10))
        _ = lagged.take()
        lagged.offer(reading(1.01, 11))
        check(lagged.take()?.reading == nil, "Fresh callback with buffered old sensor time rejected")
        lagged.offer(reading(1.02, 11.01))
        check(lagged.take()?.reading == nil, "Buffered stream does not redefine healthy latency")
        lagged.offer(reading(2.02, 11.02))
        let caughtUp = lagged.take()!
        check(caughtUp.reading?.timestamp == 2.02, "Genuinely caught-up source accepted")
        check(caughtUp.continuityIssue != nil, "Catch-up source discontinuity requires explicit calibration")

        let jumping = MotionDeliveryBuffer()
        jumping.offer(reading(1, 10))
        _ = jumping.take()
        jumping.offer(reading(1.01, 10.01, yaw: 1))
        jumping.offer(reading(1.02, 10.02, yaw: 0))
        check(jumping.take()?.continuityIssue?.contains("jumped") == true,
              "Reference jump cannot disappear when an intermediate pose is dropped")

        let switching = MotionDeliveryBuffer()
        switching.offer(reading(1, 10))
        _ = switching.take()
        switching.offer(reading(1.01, 10.01, source: .headphoneRight))
        switching.offer(reading(1.02, 10.02))
        check(switching.take()?.continuityIssue?.contains("AirPod changed") == true,
              "Source switch and return cannot disappear inside UI backlog")

        let invalid = MotionDeliveryBuffer()
        invalid.offer(reading(1, 10))
        _ = invalid.take()
        invalid.offer(reading(.nan, 10.01))
        invalid.offer(reading(1.02, 10.02))
        check(invalid.take()?.continuityIssue?.contains("Invalid motion") == true,
              "Invalid sample remains visible even after valid samples recover")

        let failing = MotionDeliveryBuffer()
        failing.offer(reading(1, 10))
        check(!failing.offerError("test terminal error"), "Terminal error uses the already scheduled drain")
        check(!failing.offer(reading(1.01, 10.01)), "Samples cannot overwrite pending terminal error")
        let failure = failing.take()!
        check(failure.error == "test terminal error" && failure.reading == nil, "Terminal error replaces visual pose")
        check(!failing.offer(reading(1.02, 10.02)), "Retired buffer cannot resume after error consumption")

        let idle = MotionDeliveryBuffer()
        idle.offer(reading(1, 10))
        let old = idle.take()!
        check(!VeilMath.isRecent(receipt: old.reading?.receipt, now: 11, timeout: 0.65),
              "Consumption checks acquisition age; reading the mailbox does not renew freshness")
        print("PASS: \(checks) motion-delivery lifecycle assertions (synthetic; no hardware claims)")
    }
}
