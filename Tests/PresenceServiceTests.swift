import Foundation
import CoreGraphics

@MainActor private final class FakePresenceCapture: PresenceCapturing {
    var isAuthorized = true
    var starts = 0
    var stops = 0
    var holdStart = false
    var holdStop = false
    var startContinuation: CheckedContinuation<Void, Error>?
    var stopContinuation: CheckedContinuation<Void, Never>?
    var observations: [@MainActor (PresenceObservation) -> Void] = []
    var failures: [@MainActor (String) -> Void] = []
    func start(reference: PresenceSeatReference,
               onObservation: @escaping @MainActor (PresenceObservation) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) async throws {
        starts += 1; observations.append(onObservation); failures.append(onFailure)
        if holdStart { try await withCheckedThrowingContinuation { startContinuation = $0 } }
    }
    func stop() async {
        stops += 1
        if holdStop { await withCheckedContinuation { stopContinuation = $0 } }
    }
    func releaseStart() { startContinuation?.resume(); startContinuation = nil }
    func releaseStop() { holdStop = false; stopContinuation?.resume(); stopContinuation = nil }
}

@MainActor private final class PresenceFixture {
    var time = 100.0
    let capture = FakePresenceCapture()
    let reference = PresenceSeatReference(cameraID: "builtin", configurationID: "fixed-vga",
        faceBounds: CGRect(x: 0.4, y: 0.6, width: 0.2, height: 0.2), captureHostTime: 1)
    lazy var service = PresenceService(capture: capture, now: { [unowned self] in self.time })
    func frame(handler: Int? = nil, occupied: Bool = true) {
        let bodies = occupied ? [PresenceBody(bounds: CGRect(x: 0.25, y: 0.05, width: 0.5, height: 0.8), confidence: 0.95)] : []
        capture.observations[handler ?? capture.observations.count - 1](PresenceObservation(cameraID: "builtin",
            configurationID: "fixed-vga", captureHostTime: time - 0.02, receiptHostTime: time, bodies: bodies, faces: []))
        time += 0.34
    }
}

@main struct PresenceServiceTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1; if !condition() { fatalError(message) }
        }
        func settle() async { for _ in 0..<20 { await Task.yield() } }
        do {
            let f = PresenceFixture(); f.capture.isAuthorized = false
            do { try await f.service.start(reference: f.reference); fatalError("Denied camera must not start") } catch {}
            check(f.capture.starts == 0 && !f.service.isRunning && f.service.state == .unknown,
                  "No authorization means no capture and no fabricated presence")
            check(f.service.status.contains("permission"), "Permission failure remains reviewable without prompting")
        }
        do {
            let f = PresenceFixture(); try await f.service.start(reference: f.reference)
            check(f.service.isRunning && f.service.state == .unknown, "Capture starts without presuming the occupant")
            for _ in 0..<3 { f.frame() }
            check(f.service.state == .present, "Fresh foreground evidence reaches the service")
            f.time += 2; f.service.refresh()
            check(f.service.state == .unknown, "Service refresh removes stale presence")
            await f.service.stop()
            check(!f.service.isRunning && f.service.state == .unknown, "Stopping discards presence immediately")
        }
        do {
            let f = PresenceFixture(); try await f.service.start(reference: f.reference)
            for _ in 0..<3 { f.frame() }
            let old = f.capture.observations.count - 1
            f.capture.holdStop = true
            var stopCompleted = false
            let stop = Task { await f.service.stop(); stopCompleted = true }
            await settle()
            check(!f.service.isRunning && !stopCompleted, "Stop invalidates callbacks before waiting for capture queue release")
            let physicalStops = f.capture.stops
            var secondStopCompleted = false
            let secondStop = Task { await f.service.stop(); secondStopCompleted = true }
            await settle()
            check(!secondStopCompleted && f.capture.stops == physicalStops,
                  "Concurrent stops join the same teardown barrier and cannot return while the camera queue is still held")
            f.frame(handler: old)
            check(f.service.state == .unknown, "Queued old capture results cannot revive a stopped session")
            f.capture.releaseStop(); await stop.value; await secondStop.value
            check(stopCompleted && secondStopCompleted, "All awaited stops finish only when capture teardown actually completes")
            try await f.service.start(reference: f.reference)
            for _ in 0..<3 { f.frame(handler: old) }
            check(f.service.state == .unknown, "An older run cannot deliver evidence into a new run")
            for _ in 0..<3 { f.frame() }
            check(f.service.state == .present && f.capture.starts == 2, "The new run uses only its own observations")
            await f.service.stop()
        }
        do {
            let f = PresenceFixture(); f.capture.holdStart = true
            let start = Task { try await f.service.start(reference: f.reference) }
            await settle(); await f.service.stop(); f.capture.releaseStart()
            do { try await start.value; fatalError("Late start must cancel") } catch {}
            check(!f.service.isRunning && f.service.state == .unknown, "Late camera startup cannot resurrect a stopped service")
        }
        do {
            let f = PresenceFixture(); try await f.service.start(reference: f.reference)
            for _ in 0..<3 { f.frame() }
            f.capture.failures[0]("Camera interrupted")
            await settle()
            check(!f.service.isRunning && f.service.state == .unknown && f.service.status == "Camera interrupted",
                  "Capture failure stops the session and exposes uncertainty rather than absence")
        }
        print("PASS: \(checks) presence capture lifecycle checks; injected capture only")
    }
}
