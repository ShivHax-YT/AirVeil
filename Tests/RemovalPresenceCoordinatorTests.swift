import Foundation
import CoreGraphics

@MainActor private final class RemovalTestGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    var waiters: Int { continuations.count }
    func wait() async { await withCheckedContinuation { continuations.append($0) } }
    func release() {
        let pending = continuations; continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

@MainActor private final class FakeRemovalPresence: RemovalPresenceMonitoring {
    var state = PresenceState.unknown
    var status = "Presence uncertain"
    var starts = 0
    var stops = 0
    var running = false
    var failStart = false
    var startGate: RemovalTestGate?
    var stopGate: RemovalTestGate?
    private var generation = 0
    func start(reference: PresenceSeatReference) async throws {
        generation += 1
        let ticket = generation
        starts += 1; state = .unknown
        if let startGate { await startGate.wait() }
        guard generation == ticket else { throw CancellationError() }
        if failStart { throw NSError(domain: "FakeCamera", code: 1) }
        running = true
    }
    func stop() async {
        generation += 1; stops += 1; state = .unknown; running = false
        if let stopGate { await stopGate.wait() }
    }
    func refresh() {}
}

@MainActor private final class FakeRemovalDimmer: RemovalPresenceDimming {
    var isDimmed = false
    var isBusy = false
    var hasPendingRestore = false
    var status = "Fake brightness"
    var targets: [Double] = []
    var restores = 0
    var recoveries = 0
    var suspends = 0
    var restoreSucceeds = true
    var dimGate: RemovalTestGate?
    var restoreGate: RemovalTestGate?
    private var revision = 0
    func setDimmed(_ dimmed: Bool, targetBrightness: Double, keepDisplayAwake: Bool) async -> Bool {
        revision += 1
        let ticket = revision
        targets.append(targetBrightness); isBusy = true; hasPendingRestore = true
        if let dimGate { await dimGate.wait() }
        guard revision == ticket else { return false }
        isDimmed = dimmed; isBusy = false
        return true
    }
    func restore() async -> Bool {
        revision += 1
        let ticket = revision
        restores += 1; isBusy = true
        if let restoreGate { await restoreGate.wait() }
        guard revision == ticket else { return false }
        isBusy = false
        if restoreSucceeds { isDimmed = false; hasPendingRestore = false }
        return restoreSucceeds
    }
    func recoverIfNeeded() async -> Bool { recoveries += 1; return await restore() }
    func suspendUntilActive() async -> Bool {
        revision += 1; suspends += 1; isBusy = false
        return true
    }
}

@MainActor private final class RemovalFixture {
    let presence = FakeRemovalPresence()
    let dimmer = FakeRemovalDimmer()
    let reference = PresenceSeatReference(cameraID: "camera", configurationID: "fixed",
        faceBounds: CGRect(x: 0.35, y: 0.45, width: 0.25, height: 0.25), captureHostTime: 90)
    var prepareGate: RemovalTestGate?
    var sleepGate: RemovalTestGate?
    var prepares = 0
    var sleeps = 0
    var sleepFails = false
    lazy var coordinator = RemovalPresenceCoordinator(presence: presence, dimmer: dimmer,
        prepareCamera: { [weak self] in
            guard let self else { return }
            prepares += 1
            if let prepareGate { await prepareGate.wait() }
        }, requestDisplaySleep: { [weak self] in
            guard let self else { return }
            sleeps += 1
            if let sleepGate { await sleepGate.wait() }
            if sleepFails { throw NSError(domain: "FakeSleep", code: 1) }
        })
    func begin(now: Double = 100, allowSleep: Bool = true) {
        coordinator.begin(reference: reference, now: now, allowSleepBeforePresence: allowSleep)
    }
}

/// Uses the production journal/worker beneath the production coordinator. Only
/// the physical drivers, persistence, camera, and sleep action are simulated.
@MainActor private final class RemovalBrightnessDriver: DisplayBrightnessControlling {
    var value = 0.8124999403953552
    var writes: [Double] = []
    var readFailure: DisplayDimmingError?
    var writeGate: RemovalTestGate?
    func read(displayID: String?) async throws -> DisplayBrightnessReading {
        if let readFailure { throw readFailure }
        return .init(displayID: "built-in-test", brightness: value)
    }
    func write(_ brightness: Double, displayID: String) async throws -> DisplayBrightnessReading {
        writes.append(brightness)
        if let writeGate { await writeGate.wait() }
        value = brightness
        return .init(displayID: "built-in-test", brightness: value)
    }
}

@MainActor private final class RemovalBrightnessJournal: DisplayBrightnessRestoreStoring {
    var record: DisplayBrightnessRestoreRecord?
    var saved: [DisplayBrightnessRestoreRecord] = []
    func load() throws -> DisplayBrightnessRestoreRecord? { record }
    func save(_ record: DisplayBrightnessRestoreRecord) throws { self.record = record; saved.append(record) }
    func clear() throws { record = nil }
}

@MainActor private final class RemovalIdleAssertion: DisplayIdleAssertionControlling {
    var held = false
    func acquire() throws -> UInt32 { held = true; return 1 }
    func release(_ assertion: UInt32) { held = false }
}

@MainActor private final class RealDimmingRemovalFixture {
    let presence = FakeRemovalPresence()
    let driver = RemovalBrightnessDriver()
    let journal = RemovalBrightnessJournal()
    let assertion = RemovalIdleAssertion()
    var sleeps = 0
    lazy var dimmer = DisplayDimmingService(brightness: driver, store: journal, assertions: assertion,
        timeout: 2, now: { 1234 })
    lazy var coordinator = RemovalPresenceCoordinator(presence: presence, dimmer: dimmer,
        prepareCamera: {}, requestDisplaySleep: { [weak self] in self?.sleeps += 1 })
    func begin(now: Double, allowSleep: Bool = true) {
        let reference = PresenceSeatReference(cameraID: "camera", configurationID: "fixed",
            faceBounds: CGRect(x: 0.35, y: 0.45, width: 0.25, height: 0.25), captureHostTime: now - 1)
        coordinator.begin(reference: reference, targetBrightness: 0.02, now: now,
            allowSleepBeforePresence: allowSleep, allowUncertainSleep: false)
    }
}

@main struct RemovalPresenceCoordinatorTests {
    @MainActor static func main() async {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !value() { fatalError(message) }
        }
        func settle() async { for _ in 0..<100 { await Task.yield() } }
        do {
            let f = RemovalFixture()
            check(f.coordinator.canResumeHeading && !f.coordinator.isActive, "Construction performs no episode")
            check(f.prepares == 0 && f.presence.starts == 0 && f.dimmer.restores == 0, "Construction performs no provider or preference work")
            f.coordinator.cancel()
            check(f.coordinator.canResumeHeading && !f.coordinator.isBusy && f.dimmer.restores == 0,
                  "Cancelling an idle controller keeps immediate Pause/Enable available without provider work")
            f.begin(); await settle()
            check(f.prepares == 1 && f.presence.starts == 1 && f.presence.running, "One removal prepares exclusive camera access and starts presence")
            check(!f.coordinator.canResumeHeading, "Presence capture excludes head calibration")
            f.presence.state = .present
            f.coordinator.update(now: 101); await settle()
            for time in [101.1, 101.2, 101.3] { f.coordinator.update(now: time) }
            await settle()
            check(f.dimmer.targets == [0] && f.dimmer.isDimmed, "Repeated present ticks request one zero-brightness blackout")
            f.coordinator.updateTarget(0.1); f.coordinator.updateTarget(0.1); await settle()
            check(f.dimmer.targets == [0, 0.1], "Repeated target values do not overwrite the dim baseline")
            f.presence.state = .unknown
            f.coordinator.update(now: 102); f.coordinator.update(now: 109); await settle()
            check(f.sleeps == 0 && f.dimmer.isDimmed, "Brief uncertain presence keeps the existing dim without sleeping")
            f.presence.state = .present; f.coordinator.update(now: 109.5)
            f.presence.state = .unknown; f.coordinator.update(now: 110); f.coordinator.update(now: 117.9)
            check(f.sleeps == 0, "Fresh presence resets the bounded uncertainty interval")
            f.coordinator.update(now: 118); await settle()
            check(f.sleeps == 1 && f.coordinator.phase == .sleeping, "Sustained unknown invokes the explicit bounded fallback")
            f.coordinator.update(now: 130); await settle()
            check(f.sleeps == 1 && !f.presence.running, "An episode sleeps once and stops its camera")
        }
        do {
            let f = RemovalFixture(); f.begin(); await settle()
            f.presence.state = .present; f.coordinator.update(now: 101); await settle()
            let restores = f.dimmer.restores
            check(f.dimmer.targets == [0] && f.sleeps == 0,
                  "Zero brightness for an occupied seat never invokes display sleep")
            f.presence.state = .absent; f.coordinator.update(now: 102); await settle()
            check(f.sleeps == 1 && f.dimmer.suspends == 1 && f.dimmer.restores == restores && f.dimmer.hasPendingRestore,
                  "Leaving the blacked-out seat releases idle protection without flashing original brightness before sleep")
            let restored = await f.coordinator.recoverAfterActivation()
            check(restored && f.dimmer.restores == restores + 1 && !f.dimmer.hasPendingRestore,
                  "Only a verified active session restores the retained blackout baseline after departure")
        }
        do {
            let f = RemovalFixture(); f.sleepFails = true; f.begin(); await settle()
            f.presence.state = .present; f.coordinator.update(now: 101); await settle()
            let restores = f.dimmer.restores
            f.presence.state = .absent; f.coordinator.update(now: 102); await settle()
            check(f.sleeps == 1 && f.coordinator.phase == .failed && f.dimmer.restores == restores + 1 && !f.dimmer.isDimmed,
                  "Failed display sleep restores an active user's brightness instead of stranding the panel at zero")
        }
        do {
            let f = RemovalFixture(); f.prepareGate = RemovalTestGate()
            f.begin(); await settle()
            check(f.prepares == 1 && f.presence.starts == 0, "Presence waits for heading-camera cleanup")
            let finished = await f.coordinator.finishForRewear()
            f.prepareGate?.release(); await settle()
            check(finished && f.coordinator.canResumeHeading, "Rewear can cancel a pending camera handoff")
            check(f.presence.starts == 0 && f.sleeps == 0, "Late handoff completion cannot restart presence or sleep")
        }
        do {
            let f = RemovalFixture(); f.presence.startGate = RemovalTestGate()
            f.begin(); await settle()
            check(f.presence.starts == 1, "Suspended camera startup reached its provider")
            let finished = await f.coordinator.finishForRewear()
            f.presence.startGate?.release(); await settle()
            check(finished && !f.presence.running && f.coordinator.phase == .idle, "Late startup cannot revive a cancelled episode")
        }
        do {
            let f = RemovalFixture(); f.presence.failStart = true
            f.begin(); await settle()
            f.coordinator.update(now: 107.9); await settle()
            check(f.sleeps == 0 && f.coordinator.phase == .uncertain && f.dimmer.targets.isEmpty,
                  "Camera failure remains honest uncertainty and never invents seated presence")
            f.coordinator.update(now: 108); await settle()
            check(f.sleeps == 1 && f.coordinator.phase == .sleeping,
                  "Failed camera startup receives the same bounded fallback grace")
        }
        do {
            let f = RemovalFixture(); f.begin(); await settle()
            let gate = RemovalTestGate(); f.dimmer.dimGate = gate
            f.presence.state = .present; f.coordinator.update(now: 101); await settle()
            f.coordinator.updateTarget(0.09); await settle()
            f.coordinator.updateTarget(0.09)
            check(f.dimmer.targets == [0, 0.09] && gate.waiters == 2,
                  "An in-flight dim accepts the latest target once")
            gate.release(); f.dimmer.dimGate = nil; await settle()
            check(f.dimmer.isDimmed && !f.coordinator.isBusy && f.coordinator.phase == .present,
                  "Superseded dim completion cannot replace the latest target state")
            let finished = await f.coordinator.finishForRewear()
            check(finished && !f.dimmer.hasPendingRestore,
                  "Multiple dim targets still restore the episode's owned baseline")
        }
        do {
            let f = RemovalFixture(); f.begin(); await settle()
            f.presence.state = .present; f.coordinator.update(now: 101); await settle()
            let gate = RemovalTestGate(); f.presence.stopGate = gate
            let oldStops = f.presence.stops
            f.coordinator.cancel(); await settle()
            let rewear = Task { await f.coordinator.finishForRewear() }; await settle()
            check(!f.coordinator.canResumeHeading && f.coordinator.isBusy, "Heading waits for physical camera release")
            check(f.presence.stops == oldStops + 1 && gate.waiters == 1, "Concurrent cancellation joins one physical stop barrier")
            gate.release(); f.presence.stopGate = nil
            let finished = await rewear.value
            check(finished && !f.dimmer.hasPendingRestore, "Rewear waits for stopped camera and restored brightness")
        }
        do {
            let f = RemovalFixture(); f.begin(); await settle()
            f.presence.state = .present; f.coordinator.update(now: 101); await settle()
            let gate = RemovalTestGate(); f.presence.stopGate = gate
            f.presence.state = .absent; f.coordinator.update(now: 102); await settle()
            check(f.sleeps == 0, "Security sleep waits for presence capture cleanup")
            let rewear = Task { await f.coordinator.finishForRewear() }; await settle()
            gate.release(); f.presence.stopGate = nil
            _ = await rewear.value; await settle()
            check(f.sleeps == 0 && f.coordinator.phase == .idle, "Rewear cancels a queued absence sleep before invocation")
        }
        do {
            let f = RemovalFixture(); f.begin(); await settle()
            f.presence.state = .present; f.coordinator.update(now: 101); await settle()
            f.dimmer.restoreSucceeds = false
            f.presence.state = .absent; f.coordinator.update(now: 102); await settle()
            check(f.sleeps == 1, "Restore failure must not disable the existing security sleep action")
            let finished = await f.coordinator.finishForRewear()
            check(!finished && !f.coordinator.canResumeHeading, "Restore failure prevents dependent heading resumption")
            f.dimmer.restoreSucceeds = true
            let recovered = await f.coordinator.recoverAfterActivation()
            check(recovered, "Explicit active-session retry can recover owned brightness")
        }
        do {
            let f = RemovalFixture(); f.begin(allowSleep: false); await settle()
            f.coordinator.update(now: 108); await settle()
            check(f.sleeps == 0 && !f.coordinator.isActive && !f.presence.running, "Manual wake with unresolved presence cannot immediately sleep again")
            f.begin(now: 110, allowSleep: false); await settle()
            f.presence.state = .present; f.coordinator.update(now: 111); await settle()
            f.presence.state = .absent; f.coordinator.update(now: 113); await settle()
            check(f.sleeps == 1, "A fresh seated observation rearms departure after manual wake")
        }
        do {
            let f = RemovalFixture()
            f.coordinator.begin(reference: nil, now: 100); await settle()
            check(f.sleeps == 1 && f.prepares == 0 && f.presence.starts == 0, "Missing seat reference uses honest existing-sleep fallback")
            f.coordinator.begin(reference: nil, now: 110, allowSleepBeforePresence: false); await settle()
            check(f.sleeps == 1 && !f.coordinator.isActive, "Missing reference after manual wake cannot resleep")
        }
        do {
            let f = RemovalFixture(); f.begin(); await settle()
            f.dimmer.dimGate = RemovalTestGate()
            f.presence.state = .present; f.coordinator.update(now: 101); await settle()
            let oldRestores = f.dimmer.restores
            f.coordinator.suspend(); await settle()
            check(f.dimmer.suspends == 1 && f.dimmer.restores == oldRestores, "Inactive cleanup releases assertion without a brightness restore write")
            check(!f.coordinator.canResumeHeading && f.coordinator.phase == .suspended, "Suspension blocks camera resumption")
            f.dimmer.dimGate?.release(); await settle()
            check(f.coordinator.phase == .suspended, "Late dim completion cannot escape suspension")
            let inactiveFinish = await f.coordinator.finishForRewear()
            check(!inactiveFinish && f.dimmer.restores == oldRestores, "Rewear alone does not authorize writes in an inactive session")
            let recovered = await f.coordinator.recoverAfterActivation()
            check(recovered && f.dimmer.restores == oldRestores + 1, "Explicit awake/unlocked recovery restores pending brightness")
        }
        do {
            let f = RemovalFixture(); f.begin(); await settle()
            let gate = RemovalTestGate(); f.dimmer.restoreGate = gate
            let finished = Task { await f.coordinator.finishForRewear() }; await settle()
            check(!f.coordinator.canResumeHeading && f.coordinator.isBusy, "Camera stop alone cannot bypass brightness restoration")
            gate.release(); f.dimmer.restoreGate = nil
            let recovered = await finished.value
            check(recovered, "Rewear completes after delayed restore")
        }
        do {
            let f = RemovalFixture(); f.sleepGate = RemovalTestGate(); f.begin(); await settle()
            f.presence.state = .absent; f.coordinator.update(now: 102); await settle()
            check(f.sleeps == 1, "Absence dispatches one async sleep request")
            _ = await f.coordinator.finishForRewear()
            f.sleepGate?.release(); await settle()
            check(f.coordinator.phase == .idle && f.sleeps == 1, "Late sleep completion cannot overwrite a newer rewear state")
        }
        do {
            let f = RemovalFixture()
            f.coordinator.begin(reference: nil, now: 100, allowDimming: false, allowUncertainSleep: false)
            await settle()
            check(f.sleeps == 0 && f.presence.starts == 0 && !f.coordinator.isActive,
                  "A connection-only check without valid seat geometry never falls back to sleep")
        }
        do {
            let f = RemovalFixture()
            f.dimmer.restoreSucceeds = false; f.dimmer.hasPendingRestore = true
            f.begin(); await settle()
            check(f.presence.starts == 0 && f.prepares == 0 && f.coordinator.phase == .failed && !f.coordinator.isActive,
                  "A failed previous brightness cleanup blocks the next camera/removal episode")
            f.dimmer.restoreSucceeds = true
            let recovered = await f.coordinator.recoverAfterActivation()
            check(recovered && f.dimmer.recoveries == 1,
                  "Confirmed activation uses the dimmer's explicit recovery entry point")
        }
        for rewearBeforeUnlock in [true, false] {
            let f = RealDimmingRemovalFixture()
            for (index, original) in [0.8124999403953552, 0.625, 0.4375].enumerated() {
                let now = Double(200 + index * 20)
                // Each completed cycle may start from a new manual awake choice.
                f.driver.value = original
                let firstSaved = f.journal.saved.count
                f.begin(now: now); await settle()
                f.presence.state = .present; f.coordinator.update(now: now + 1); await settle()
                check(f.driver.value == 0.02 && f.journal.record?.baseline == original && f.assertion.held,
                      "Every repeated seated-removal cycle retains its actual pre-dim brightness")
                f.presence.state = .absent; f.coordinator.update(now: now + 2); await settle()
                f.coordinator.suspend(); await settle()
                let writesAtLock = f.driver.writes.count
                check(f.sleeps == index + 1 && !f.assertion.held && f.dimmer.hasPendingRestore,
                      "Departure sleeps once and keeps restoration ownership without an awake assertion")
                if rewearBeforeUnlock {
                    let inactiveRewear = await f.coordinator.finishForRewear()
                    check(!inactiveRewear && f.driver.writes.count == writesAtLock && f.journal.record?.baseline == original,
                          "AirPods returned before unlock cannot write brightness or discard the original")
                }
                let recovered = await f.coordinator.recoverAfterActivation()
                check(recovered && f.driver.value == original && f.journal.record == nil,
                      "Unlock restores the original independently of whether AirPods already returned")
                if !rewearBeforeUnlock {
                    // AppModel resumes a still-removed episode after unlock. A
                    // fresh seated check can dim again before the later rewear.
                    f.begin(now: now + 3, allowSleep: false); await settle()
                    f.presence.state = .present; f.coordinator.update(now: now + 4); await settle()
                    check(f.driver.value == 0.02 && f.journal.record?.baseline == original,
                          "A resumed removal episode captures restored brightness, never its previous dim")
                    let finished = await f.coordinator.finishForRewear()
                    check(finished && f.driver.value == original && f.journal.record == nil,
                          "AirPods returned after unlock restore the same original a second time")
                }
                check(f.coordinator.canResumeHeading && !f.dimmer.isBusy && !f.assertion.held &&
                      f.journal.saved.dropFirst(firstSaved).allSatisfy { $0.baseline == original },
                      "Both return orders complete each cycle without a dimmed baseline or stale ownership")
            }
        }
        for failure in [DisplayDimmingError.displayAsleep, .readFailed(-1)] {
            let f = RealDimmingRemovalFixture(), original = 0.8124999403953552
            f.begin(now: 300); await settle()
            f.presence.state = .present; f.coordinator.update(now: 301); await settle()
            f.presence.state = .absent; f.coordinator.update(now: 302); await settle()
            f.coordinator.suspend(); await settle()
            _ = await f.coordinator.finishForRewear()
            f.driver.readFailure = failure
            let failedRecovery = await f.coordinator.recoverAfterActivation()
            check(!failedRecovery && f.coordinator.phase == .failed && !f.coordinator.canResumeHeading &&
                  f.journal.record?.baseline == original,
                  "An early wake read failure retains ownership and exposes retryable failure")
            let starts = f.presence.starts
            f.begin(now: 303); await settle()
            check(f.presence.starts == starts && f.coordinator.phase == .failed && f.driver.value == 0.02,
                  "A failed wake read cannot restart camera capture or record the dim as a new baseline")
            f.driver.readFailure = nil
            let recovered = await f.coordinator.recoverAfterActivation()
            check(recovered && f.driver.value == original && !f.dimmer.hasPendingRestore,
                  "A later awake retry completes the original restore after either failure")
        }
        do {
            let f = RealDimmingRemovalFixture(), original = 0.8124999403953552
            f.begin(now: 400); await settle()
            f.presence.state = .present; f.coordinator.update(now: 401); await settle()
            let gate = RemovalTestGate(); f.driver.writeGate = gate
            let rewear = Task { await f.coordinator.finishForRewear() }; await settle()
            check(gate.waiters == 1 && f.journal.record?.pendingTarget == original,
                  "A delayed restore journals the original before entering the driver")
            f.coordinator.suspend(); await settle()
            f.driver.writeGate = nil; gate.release()
            _ = await rewear.value; await settle()
            check(f.coordinator.phase == .suspended && f.journal.record?.baseline == original && !f.assertion.held,
                  "A restore acknowledged after lock cannot clear its durable journal")
            f.driver.value = 0.02
            let recovered = await f.coordinator.recoverAfterActivation()
            check(recovered && f.driver.value == original && f.journal.record == nil,
                  "Wake verifies the final panel state and restores after a superseded driver acknowledgement")
        }
        print("PASS: \(checks) RemovalPresenceCoordinator checks with fake providers; no camera, brightness, assertion, or sleep access")
    }
}
