import Foundation
import CoreMotion

/// Fake sensor boundary only. Production MotionService, delivery buffer,
/// freshness, reference retention, generations, and restart policy run unchanged.
private final class SyntheticAttitude: MotionAttitude {
    let radians: Double
    init(_ radians: Double) { self.radians = radians }
    func copyForReference() -> any MotionAttitude { SyntheticAttitude(radians) }
    func relativeYaw(to reference: any MotionAttitude) -> Double? {
        guard let reference = reference as? SyntheticAttitude else { return nil }
        return atan2(sin(radians-reference.radians), cos(radians-reference.radians))
    }
}

@MainActor private final class SensorClock {
    var time = 1100.0
}

@MainActor private final class FakeHeadphoneTransport: HeadphoneMotionTransport {
    var authorizationStatus = CMAuthorizationStatus.authorized
    var isMotionAvailable = true
    var streamStarts = 0
    var streamStops = 0
    var connectionStarts = 0
    var connectionStops = 0
    var connection: (@MainActor (Bool) -> Void)?
    var sample: (@Sendable (MotionReading?, String?) -> Void)?
    func startConnectionUpdates(_ handler: @escaping @MainActor (Bool) -> Void) {
        connectionStarts += 1; connection = handler
    }
    func stopConnectionUpdates() { connectionStops += 1; connection = nil }
    func startMotionUpdates(on queue: OperationQueue,
        handler: @escaping @Sendable (MotionReading?, String?) -> Void) {
        streamStarts += 1; sample = handler
    }
    func stopMotionUpdates() { streamStops += 1 }

}

@main @MainActor struct MotionReferenceLifecycleTests {
    static func main() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard value() else { fatalError("FAIL: \(message)") }
        }
        let clock = SensorClock(), transport = FakeHeadphoneTransport()
        var factories = 0
        let service = MotionService(transportFactory: { factories += 1; return transport },
            now: { clock.time }, usesAutomaticWatchdog: false)
        func emit(_ degrees: Double, dt: Double = 0.1,
                  source: CMDeviceMotion.SensorLocation = .headphoneLeft,
                  timestamp: Double? = nil, speed: Double = 0) {
            clock.time += dt
            let radians = degrees * .pi/180
            transport.sample?(MotionReading(attitude: SyntheticAttitude(radians),
                timestamp: timestamp ?? (clock.time-1000), receipt: clock.time,
                quaternion: VeilQuaternion(x: 0, y: 0, z: sin(radians/2), w: cos(radians/2)),
                speed: speed, source: source), nil)
            service.checkFreshness()
        }
        service.start()
        check(transport.streamStarts == 1 && factories == 1, "Initial start creates one sensor stream")
        service.start()
        check(transport.streamStarts == 1 && factories == 1, "Start is idempotent while running")
        for _ in 0..<7 { emit(17) }
        check(!service.hasSavedCenter && service.centerRevision == 0, "Fresh stationary input never chooses a new center")
        check(service.canCalibrate, "Fresh stable input supports explicit Set center")
        service.calibrate()
        check(service.referenceState == .established && service.referenceUsable && service.centerRevision == 1,
              "Explicit Set center establishes the original copied reference")

        let originalEpoch = service.fusionEpoch
        check(abs((service.fusionSample?.yawRadians ?? .infinity)-17 * .pi/180) < 1e-8,
              "Fusion receives raw17-degree sensor yaw independent of manualzero")
        transport.connection?(true)
        check(service.fusionEpoch == originalEpoch, "Duplicate startup connect does not create a fusion epoch")
        transport.connection?(false)
        check(service.fusionEpoch > originalEpoch && service.fusionSample == nil,
              "Removal advances fusion epoch and clears the old raw sample")
        check(service.connectionState == .disconnected && service.disconnectEventCount == 1,
              "Actual disconnect remains available as a transport diagnostic")
        check(service.removalEventCount == 0 && service.removalConnectionState == .unknown,
              "Idle audio or device handoff disconnect cannot fabricate ear removal")
        check(service.hasSavedCenter && !service.isCalibrated && service.referenceState == .invalid && !service.trackingValid,
              "Absence retains diagnostic zero but invalidates unverified reference")
        emit(80)
        check(service.connectionState == .disconnected && !service.isFresh,
              "Queued or in-flight poses cannot fabricate a reconnect")
        clock.time += 60
        service.checkFreshness()
        check(transport.streamStarts == 1 && transport.streamStops == 0 && factories == 1,
              "Long out-of-ear absence does not restart or replace the stream")
        transport.connection?(true)
        emit(62)
        check(abs(service.yawDegrees-45) < 1e-8 && service.centerRevision == 1,
              "Rewear while looking away uses original17-degree reference, not new62-degree zero")
        check(!service.trackingValid && service.referenceState == .invalid,
              "Same-source rewear cannot restore physically disproven reference confidence")
        check(abs((service.fusionSample?.yawRadians ?? .infinity)-62 * .pi/180) < 1e-8,
              "Uncalibrated returned sensor still supplies rawyaw for camera alignment")
        for degrees in stride(from: 57.0, through: 17, by: -5) { emit(degrees) }
        check(abs(service.yawDegrees) < 1e-8 && service.centerRevision == 1,
              "Return to original screen-facing pose remains zero without pressing a button")
        for _ in 0..<100 { emit(17) }
        check(service.centerRevision == 1, "Sustained stillness cannot overwrite original zero")

        clock.time += 10
        service.checkFreshness()
        check(!service.trackingValid && !service.referenceUsable && service.centerRevision == 1,
              "Unobserved timing stall preserves diagnostic copy but invalidates usability")
        check(transport.streamStarts == 1 && transport.streamStops == 0,
              "Calibrated silence does not force the destructive5-second retry")
        emit(42)
        check(abs(service.yawDegrees-25) < 1e-8 && !service.trackingValid,
              "Return after a timing gap never enables unverified legacy heading")

        emit(42, source: .headphoneRight)
        check(service.referenceState == .invalid && service.hasSavedCenter && !service.referenceUsable && !service.isCalibrated,
              "Changed source retains the saved object but invalidates its frame confidence")
        for _ in 0..<10 { emit(42, source: .headphoneRight) }
        check(service.centerRevision == 1 && !service.trackingValid,
              "Fresh stable source change cannot silently create a replacement zero")
        service.calibrate()
        check(service.centerRevision == 2 && service.referenceState == .established,
              "Only explicit Set center replaces an invalid saved center")
        emit(100, dt: 0.01, source: .headphoneRight)
        check(service.referenceState == .invalid && service.centerRevision == 2,
              "Measured reference jump invalidates without changing zero")
        for _ in 0..<7 { emit(100, source: .headphoneRight) }
        service.calibrate()
        var established = service.centerRevision
        emit(100, source: .headphoneRight, timestamp: 1)
        check(!service.referenceUsable && service.hasSavedCenter && service.centerRevision == established,
              "Clock reversal invalidates reference without overwriting it")

        for i in 1...10 { emit(100, source: .headphoneRight, timestamp: 1 + Double(i)*0.1) }
        check(service.isFresh && service.canCalibrate && !service.referenceUsable && service.centerRevision == established,
              "Sustained fresh new clock epoch recovers sampling without restoring the invalid old reference")
        service.calibrate()
        established += 1
        check(service.referenceUsable && service.centerRevision == established,
              "Explicit Set center works after clock epoch recovery; no old-epoch catch-up required")

        transport.connection?(false)
        clock.time += 10
        transport.connection?(true)
        emit(100, source: .headphoneRight, timestamp: 2.02)
        check(!service.isFresh && service.centerRevision == established,
              "One paused-clock return sample cannot silently rebase source timing")
        for i in 1...10 { emit(100, source: .headphoneRight, timestamp: 2.02 + Double(i)*0.1) }
        check(service.isFresh && service.canCalibrate && !service.referenceUsable && service.centerRevision == established,
              "Paced advancing samples after explicit absence recover paused source clock conservatively")
        service.calibrate()
        established += 1
        check(service.referenceUsable && service.centerRevision == established,
              "Paused-clock recovery still requires explicit replacement of the saved center")

        transport.sample?(nil, "Synthetic terminal stream error")
        service.checkFreshness()
        check(transport.streamStops == 1 && !service.referenceUsable && service.hasSavedCenter,
              "Actual terminal error stops transport and invalidates retained frame")
        clock.time += 3
        service.checkFreshness()
        check(transport.streamStarts == 2 && service.centerRevision == established,
              "Actual stream retry never pretends its origin matches the saved center")
        for _ in 0..<7 { emit(30) }
        check(!service.referenceUsable && service.centerRevision == established,
              "Fresh samples after terminal restart do not restore frame confidence")
        service.calibrate()
        check(service.centerRevision == established+1, "Explicit reference recovery remains available")

        let retiredConnection = transport.connection
        let retiredSample = transport.sample
        service.stop()
        check(service.hasSavedCenter && !service.referenceUsable && !service.isRunning,
              "Deliberate transport stop preserves diagnostic center but invalidates reuse")
        let disconnects = service.disconnectEventCount
        retiredConnection?(false)
        retiredSample?(nil, "Obsolete failure")
        service.checkFreshness()
        check(service.disconnectEventCount == disconnects && !service.isRunning,
              "Retired callbacks cannot emit removal events or restart the coordinator")
        service.start()
        check(factories == 2 && !service.referenceUsable,
              "New manager after deliberate stop requires explicit frame establishment")
        service.stop()
        do {
            let backlogClock = SensorClock(), backlogTransport = FakeHeadphoneTransport()
            let backlog = MotionService(transportFactory: { backlogTransport },
                now: { backlogClock.time }, usesAutomaticWatchdog: false)
            func acquire(dt: Double, drain: Bool, source: CMDeviceMotion.SensorLocation = .headphoneLeft) {
                backlogClock.time += dt
                backlogTransport.sample?(MotionReading(attitude: SyntheticAttitude(0),
                    timestamp: backlogClock.time - 1000, receipt: backlogClock.time,
                    quaternion: VeilQuaternion(x: 0, y: 0, z: 0, w: 1), speed: 0, source: source), nil)
                if drain { backlog.checkFreshness() }
            }
            backlog.start(); acquire(dt: 0.02, drain: true)
            let epoch = backlog.fusionEpoch, firstReceipt = backlog.fusionSample!.receiptHostTime
            for _ in 0..<50 { acquire(dt: 0.02, drain: false) }
            backlog.checkFreshness()
            check(backlog.isFresh && backlog.fusionEpoch == epoch &&
                  backlog.fusionSample!.receiptHostTime - firstReceipt > 0.9 &&
                  backlog.fusionSample!.acquisitionContinuityVerified,
                  "A busy app UI may coalesce one second of continuous acquisition without invalidating the sensor epoch")
            acquire(dt: 0.35, drain: true)
            check(backlog.fusionEpoch > epoch,
                  "An actual acquisition gap above300ms still invalidates even below the freshness timeout")
            let afterGap = backlog.fusionEpoch
            acquire(dt: 0.02, drain: true, source: .headphoneRight)
            check(backlog.fusionEpoch > afterGap,
                  "The verified continuity flag never allows an AirPod source change to reuse its old frame")
            check(backlog.removalEventCount == 0 && backlog.removalConnectionState == .connected,
                  "Physical acquisition gaps and source handoffs never fabricate ear removal")
            backlog.stop()
        }
        do {
            let wearClock = SensorClock(), wearTransport = FakeHeadphoneTransport()
            let wear = MotionService(transportFactory: { wearTransport }, now: { wearClock.time }, usesAutomaticWatchdog: false)
            func emitWear(_ count: Int, source: CMDeviceMotion.SensorLocation = .headphoneRight) {
                for _ in 0..<count {
                    wearClock.time += 0.02
                    wearTransport.sample?(MotionReading(attitude: SyntheticAttitude(0),
                        timestamp: wearClock.time - 1000, receipt: wearClock.time,
                        quaternion: VeilQuaternion(x: 0, y: 0, z: 0, w: 1), speed: 0, source: source), nil)
                    wear.checkFreshness()
                }
            }
            wear.start(); emitWear(60)
            wear.calibrate()
            let center = wear.centerRevision
            emitWear(60, source: .headphoneLeft)
            check(wear.removalEventCount == 0 && wear.removalConnectionState == .connected,
                  "Continuous motion from either single AirPod or a source handoff never triggers removal")
            wearTransport.connection?(false)
            wearClock.time += 0.2; wear.checkFreshness()
            check(wear.removalEventCount == 0, "A brief disconnect is not yet a removal session")
            wearTransport.connection?(true); emitWear(60, source: .headphoneLeft)
            wearTransport.connection?(false)
            wearClock.time += 0.4; wear.checkFreshness()
            check(wear.removalEventCount == 1 && wear.removalConnectionState == .disconnected,
                  "Sustained public disconnect after steady wearing emits one both-out proxy")
            for _ in 0..<60 { wearClock.time += 0.2; wear.checkFreshness() }
            check(wear.removalEventCount == 1 && wearTransport.streamStarts == 1,
                  "Long removal remains one episode and does not restart the requested motion stream")
            wearTransport.connection?(true); emitWear(60, source: .headphoneLeft)
            check(wear.removalConnectionState == .connected && wear.centerRevision == center && !wear.referenceUsable,
                  "Fresh headphone return restores availability without choosing a new screen center")
            wearClock.time += 0.7; wear.checkFreshness()
            wearClock.time += 0.4; wear.checkFreshness()
            check(wear.removalEventCount == 2 && wear.removalConnectionState == .disconnected,
                  "Sustained complete stream silence also works when no disconnect callback arrives")
            emitWear(60, source: .headphoneLeft)
            check(wear.removalConnectionState == .connected, "Actual samples restore availability after silent removal")
            wearTransport.sample?(nil, "Injected failure"); wear.checkFreshness()
            let events = wear.removalEventCount
            wearClock.time += 1; wear.checkFreshness()
            check(wear.removalConnectionState == .unknown && wear.removalEventCount == events,
                  "A known stream error disables removal evidence instead of treating failure as both-out")
            wearTransport.authorizationStatus = .denied
            wearClock.time += 10; wear.checkFreshness()
            check(wear.removalConnectionState == .unknown && wear.removalEventCount == events,
                  "Denied motion permission cannot create a removal episode")
            wear.stop()
        }
        print("PASS: \(checks) real MotionService reference lifecycle assertions; sensor transport/attitude/clock injected, no hardware access")
    }
}
