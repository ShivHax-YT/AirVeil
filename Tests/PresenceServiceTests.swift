import Foundation
import CoreGraphics
import CoreVideo

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
    let light = FakePresenceLight()
    let reference = PresenceSeatReference(cameraID: "builtin", configurationID: "fixed-vga",
        faceBounds: CGRect(x: 0.4, y: 0.6, width: 0.2, height: 0.2), captureHostTime: 1)
    lazy var service = PresenceService(capture: capture, faceLight: light, now: { [unowned self] in self.time })
    func frame(handler: Int? = nil, occupied: Bool = true, dark: Bool = false) {
        let bodies = occupied ? [PresenceBody(bounds: CGRect(x: 0.25, y: 0.05, width: 0.5, height: 0.8), confidence: 0.95)] : []
        capture.observations[handler ?? capture.observations.count - 1](PresenceObservation(cameraID: "builtin",
            configurationID: "fixed-vga", captureHostTime: time - 0.02, receiptHostTime: time, bodies: bodies, faces: [],
            analysisUsable: !dark, needsLightAssistance: dark,
            frameQuality: PresenceFrameQuality(globalMean: dark ? 0.01 : 0.4, seatMean: dark ? 0.01 : 0.35,
                seatDarkFraction: dark ? 1 : 0.05, seatContrast: 0.2, seatClippedFraction: 0, sampleCount: 192)))
        time += 0.34
    }
}

@MainActor private final class FakePresenceLight: FaceLighting {
    var isOn = false
    var enables = 0
    func setEnabled(_ enabled: Bool) -> Bool {
        if enabled { enables += 1 }
        isOn = enabled
        return true
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
        for ending in ["deadline", "stop", "failure", "presence"] {
            let f = PresenceFixture(); try await f.service.start(reference: f.reference)
            f.frame(occupied: false, dark: true)
            check(!f.light.isOn, "One dark frame cannot turn on the presence light")
            f.frame(occupied: false, dark: true)
            check(f.light.isOn && f.service.isAssistLightOn && f.light.enables == 1,
                  "Two fresh dark frames permit one brief local screen-light attempt")
            if ending == "deadline" { f.time += 3; f.service.refresh() }
            else if ending == "stop" { await f.service.stop() }
            else if ending == "failure" { f.capture.failures[0]("Camera stopped"); await settle() }
            else { for _ in 0..<3 { f.frame() } }
            check(!f.light.isOn && !f.service.isAssistLightOn, "\(ending) releases the presence light")
            if f.service.isRunning {
                for _ in 0..<4 { f.frame(occupied: false, dark: true) }
                check(f.light.enables == 1, "Darkness cannot restart the light repeatedly in the same removal session")
            }
            await f.service.stop()
        }
        do {
            let f = PresenceFixture(); try await f.service.start(reference: f.reference)
            f.frame(occupied: false, dark: true)
            check(f.service.isLowLight && f.service.state == .unknown,
                  "Fresh dark unusable camera evidence reaches the typed service state")
            f.time += 2; f.service.refresh()
            check(!f.service.isLowLight, "Refresh clears actionable low light when its frame is stale")
            f.frame(occupied: false, dark: true)
            check(f.service.isLowLight, "A new fresh measured dark frame can become actionable again")
            f.capture.holdStop = true
            let stopped = Task { await f.service.stop() }; await settle()
            check(!f.service.isLowLight && !f.service.isAssistLightOn && !f.service.isRunning,
                  "Stopping clears low light and screen illumination before awaiting physical camera teardown")
            f.frame(occupied: false, dark: true)
            check(!f.service.isLowLight && !f.service.isAssistLightOn,
                  "A late dark callback cannot revive illumination or trigger another brightness recovery")
            f.capture.releaseStop(); await stopped.value
        }
        do {
            let f = PresenceFixture(); try await f.service.start(reference: f.reference)
            f.frame(occupied: false, dark: true)
            f.capture.failures[0]("Camera interrupted"); await settle()
            check(!f.service.isLowLight && !f.service.isRunning,
                  "Capture failure clears low light instead of treating a failed provider as darkness")
        }
        do {
            let f = PresenceFixture(); try await f.service.start(reference: f.reference)
            for _ in 0..<7 { f.frame(occupied: false) }
            check(f.service.state == .absent, "Fresh reliable empty-seat frames establish an initial absence before rechecking")
            let starts = f.capture.starts, stops = f.capture.stops, cutoff = f.time
            f.service.recheckAfterBrightnessRestore()
            check(f.service.state == .unknown && f.service.isRunning && f.capture.starts == starts && f.capture.stops == stops,
                  "Brightness recheck clears absence without restarting or stopping the camera")
            f.time = cutoff - 0.1
            f.frame(occupied: false, dark: true)
            check(f.service.state == .unknown && !f.service.isLowLight,
                  "A queued dark frame captured before restoration cannot replace the fresh recheck state")
            f.time = cutoff + 0.04
            for _ in 0..<4 { f.frame(occupied: false) }
            check(f.service.state == .unknown, "New post-restore frames cannot skip the full absence hold")
            for _ in 0..<3 { f.frame(occupied: false) }
            check(f.service.state == .absent && f.service.qualityDiagnostics["decision"] as? String == "usable-seat",
                  "New reliable post-restore frames eventually confirm absence with numeric quality diagnostics")
            check(f.service.qualityDiagnostics["seatMean"] as? Double == 0.35 && f.service.qualityDiagnostics["bodyCount"] as? Int == 0,
                  "Opt-in diagnostics expose numeric quality and detection counts without images or coordinates")
            await f.service.stop()
        }
        do {
            let f = PresenceFixture(); try await f.service.start(reference: f.reference)
            f.capture.observations[0](PresenceObservation(cameraID: "builtin", configurationID: "fixed-vga",
                captureHostTime: f.time - 0.02, receiptHostTime: f.time, bodies: [], faces: [],
                frameQuality: PresenceFrameQuality(globalMean: .nan, seatMean: .infinity,
                    seatDarkFraction: .nan, seatContrast: -.infinity, seatClippedFraction: .nan, sampleCount: 192),
                maximumFaceConfidence: .nan))
            check(f.service.state == .unknown && !f.service.isLowLight,
                  "Malformed quality cannot establish absence or measured darkness")
            let diagnostics = f.service.qualityDiagnostics
            check(diagnostics["decision"] as? String == "unavailable" && diagnostics["seatMean"] is NSNull &&
                  diagnostics["maximumFaceConfidence"] is NSNull && JSONSerialization.isValidJSONObject(diagnostics),
                  "Nonfinite measurement diagnostics remain JSON-safe and explicitly unavailable")
            await f.service.stop()
        }
        do {
            func buffer(_ level: (Int, Int) -> UInt8) -> CVPixelBuffer {
                var output: CVPixelBuffer?
                let result = CVPixelBufferCreate(kCFAllocatorDefault, 320, 240,
                    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &output)
                precondition(result == kCVReturnSuccess && output != nil)
                let pixels = output!
                precondition(CVPixelBufferLockBaseAddress(pixels, []) == kCVReturnSuccess)
                let bytes = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
                for y in 0..<240 { for x in 0..<320 { bytes[y * stride + x] = level(x, y) } }
                CVPixelBufferUnlockBaseAddress(pixels, [])
                return pixels
            }
            let face = CGRect(x: 0.4, y: 0.6, width: 0.2, height: 0.2)
            // The seat rectangle extends from Vision y0.32 to0.84, which maps
            // to pixel rows38...164 because the camera origin is top-left.
            let darkSeat = buffer { x, y in (95...225).contains(x) && (30...172).contains(y) ? 3 : 220 }
            let dark = PresenceImageQuality.measure(darkSeat, faceBounds: face)!
            check(dark.globalMean > 0.4 && dark.seatMean < 0.04 && dark.needsLight && !dark.supportsAbsence,
                  "A bright background cannot hide a dark calibrated foreground region")
            let flat = PresenceImageQuality.measure(buffer { _, _ in 120 }, faceBounds: face)!
            check(!flat.needsLight && !flat.supportsAbsence && flat.decision == "low-detail-seat",
                  "A lit but featureless seat view stays uncertain instead of claiming reliable analysis")
            let detailed = PresenceImageQuality.measure(buffer { x, y in (x + y).isMultiple(of: 3) ? 70 : 170 }, faceBounds: face)!
            check(detailed.supportsAbsence && detailed.seatContrast > 0.3,
                  "Well-lit detailed seat pixels can support normal empty-seat evidence")
            let clipped = PresenceImageQuality.measure(buffer { _, _ in 255 }, faceBounds: face)!
            check(!clipped.supportsAbsence && clipped.decision == "clipped-seat",
                  "A washed-out foreground is not usable absence evidence")
            check(PresenceImageQuality.measure(darkSeat, faceBounds: .zero) == nil,
                  "Missing seat geometry produces unavailable quality rather than global-only inference")
        }
        print("PASS: \(checks) presence capture lifecycle checks; injected capture and light only")
    }
}
