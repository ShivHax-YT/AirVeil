import Foundation

@MainActor private final class FakeBrightness: DisplayBrightnessControlling {
    var value = 0.8124999403953552
    var id = "builtin-fixture"
    var reads = 0
    var writes: [(Double, String)] = []
    var readFailure: Error?
    var nextWriteFailure: Error?
    var failAfterApplying = false
    var holdReads = false
    var holdWrites = false
    var pendingReads: [CheckedContinuation<DisplayBrightnessReading, Error>] = []
    var pendingWrites: [(Double, String, CheckedContinuation<DisplayBrightnessReading, Error>)] = []
    var beforeWrite: ((Double) -> Void)?
    var reading: DisplayBrightnessReading { .init(displayID: id, brightness: value) }
    func read(displayID: String?) async throws -> DisplayBrightnessReading {
        reads += 1
        if let readFailure { throw readFailure }
        if let displayID, displayID != id { throw DisplayDimmingError.unsupported }
        if holdReads { return try await withCheckedThrowingContinuation { pendingReads.append($0) } }
        return reading
    }
    func write(_ brightness: Double, displayID: String) async throws -> DisplayBrightnessReading {
        writes.append((brightness, displayID)); beforeWrite?(brightness)
        if holdWrites {
            return try await withCheckedThrowingContinuation { pendingWrites.append((brightness, displayID, $0)) }
        }
        if let error = nextWriteFailure {
            nextWriteFailure = nil
            if failAfterApplying { value = brightness }
            throw error
        }
        value = brightness
        return reading
    }
    func completeRead() { pendingReads.removeFirst().resume(returning: reading) }
    func completeWrite() {
        let pending = pendingWrites.removeFirst()
        value = pending.0
        pending.2.resume(returning: reading)
    }
}

@MainActor private final class FakeRestoreStore: DisplayBrightnessRestoreStoring {
    var record: DisplayBrightnessRestoreRecord?
    var saved: [DisplayBrightnessRestoreRecord] = []
    var clears = 0
    var failSave = false
    var failClear = false
    func load() throws -> DisplayBrightnessRestoreRecord? { record }
    func save(_ record: DisplayBrightnessRestoreRecord) throws {
        if failSave { throw DisplayDimmingError.ledgerFailed }
        self.record = record; saved.append(record)
    }
    func clear() throws {
        if failClear { throw DisplayDimmingError.ledgerFailed }
        record = nil; clears += 1
    }
}

@MainActor private final class FakeIdleAssertions: DisplayIdleAssertionControlling {
    var active = Set<UInt32>()
    var created: UInt32 = 0
    var released: [UInt32] = []
    var fail = false
    func acquire() throws -> UInt32 {
        if fail { throw DisplayDimmingError.assertionFailed(-1) }
        created += 1; active.insert(created); return created
    }
    func release(_ assertion: UInt32) { active.remove(assertion); released.append(assertion) }
}

@MainActor private final class Fixture {
    let backend = FakeBrightness()
    let store = FakeRestoreStore()
    let assertions = FakeIdleAssertions()
    let service: DisplayDimmingService
    init(timeout: TimeInterval = 1) {
        service = DisplayDimmingService(brightness: backend, store: store, assertions: assertions,
            timeout: timeout, now: { 1234 })
    }
}

@main struct DisplayDimmingServiceTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func settle(_ ready: @escaping @MainActor () -> Bool) async {
            for _ in 0..<300 where !ready() { await Task.yield() }
            precondition(ready(), "The injected operation did not reach its expected state")
        }
        func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.00000001 }
        do {
            let f = Fixture(), original = 0.8124999403953552
            check(f.backend.reads == 0 && f.backend.writes.isEmpty && f.assertions.created == 0,
                  "Construction changes no hardware, reads no display, and acquires no assertion")
            f.backend.beforeWrite = { target in
                precondition(f.store.record?.pendingTarget == target && f.store.record?.baseline == original,
                             "The durable baseline and next target must precede every write")
            }
            check(await f.service.setDimmed(true), "A valid built-in display can be dimmed")
            check(f.backend.writes.count == 1 && close(f.backend.value, 0.08), "Default brightness target is eight percent")
            check(f.service.isDimmed && f.service.keepsDisplayAwake && f.assertions.active.count == 1,
                  "Verified dim owns one idle-display assertion")
            check(await f.service.setDimmed(true), "A repeated request remains valid")
            check(f.backend.writes.count == 1 && f.assertions.created == 1, "Repeated request does not rewrite brightness or duplicate assertions")
            check(f.store.saved.count == 2, "Repeated presence updates do not repeatedly flush an unchanged restore journal")
            check(await f.service.setDimmed(true, targetBrightness: 0.1), "A changed slider target updates the same episode")
            check(f.store.saved.allSatisfy { $0.baseline == original }, "Repeated updates never overwrite the exact pre-dim baseline")
            check(await f.service.restore(), "Fresh rewear or feature off restores the original brightness")
            check(f.backend.value == original && f.backend.writes.last?.0 == original,
                  "Restoration writes the original unrounded floating-point brightness")
            check(!f.service.isDimmed && !f.service.hasPendingRestore && f.assertions.active.isEmpty,
                  "Successful restoration clears ownership and idle assertion")
            let count = f.backend.writes.count
            check(await f.service.restore(), "Repeated restore is harmless")
            check(f.backend.writes.count == count, "Repeated restore does not touch brightness")
        }
        do {
            let f = Fixture(); f.backend.value = 0.03
            check(await f.service.setDimmed(true, targetBrightness: 0.08), "An already-dark screen can enter the managed dim state")
            check(f.backend.value == 0.03 && f.backend.writes.isEmpty, "Dimming never brightens an already darker panel")
            check(await f.service.restore(), "An unchanged low baseline restores without raising brightness")
            check(f.backend.writes.isEmpty, "No write is needed when original brightness was already below target")
        }
        for (target, expected) in [(-1.0, 0.05), (2.0, 0.5)] {
            let f = Fixture()
            check(await f.service.setDimmed(true, targetBrightness: target), "Finite slider targets clamp to the supported range")
            check(close(f.backend.value, expected), "Brightness range is five to fifty percent")
            check(await f.service.restore(), "Clamped target still restores the baseline")
        }
        do {
            let f = Fixture()
            check(!(await f.service.setDimmed(true, targetBrightness: .nan)), "A nonfinite target is rejected")
            check(f.backend.reads == 0 && f.backend.writes.isEmpty && f.assertions.created == 0,
                  "An invalid target causes no display or assertion operation")
            f.backend.readFailure = DisplayDimmingError.unsupported
            check(!(await f.service.setDimmed(true)), "Unsupported brightness fails explicitly")
            check(f.service.lastError != nil && f.backend.writes.isEmpty && f.store.record == nil,
                  "Unsupported hardware is never represented by a fake dark overlay or saved ownership")
        }
        do {
            let f = Fixture(); f.assertions.fail = true
            check(!(await f.service.setDimmed(true)), "Failure to prevent idle display sleep prevents dimming")
            check(f.backend.writes.isEmpty && f.store.record == nil, "An assertion failure leaves actual brightness unchanged")
            f.assertions.fail = false
            check(await f.service.setDimmed(true, keepDisplayAwake: false), "Caller may explicitly dim without holding awake")
            check(f.assertions.active.isEmpty && !f.service.keepsDisplayAwake, "No assertion is held without a valid presence request")
            check(await f.service.restore(), "Assertion-free dim still restores normally")
        }
        do {
            let f = Fixture(); f.store.failSave = true
            check(!(await f.service.setDimmed(true)), "Journal failure blocks the physical change")
            check(f.backend.writes.isEmpty && f.assertions.active.isEmpty, "No unjournaled write or leaked assertion follows store failure")
        }
        do {
            let f = Fixture(), original = f.backend.value
            f.backend.nextWriteFailure = DisplayDimmingError.writeFailed(-1)
            f.backend.failAfterApplying = true
            check(!(await f.service.setDimmed(true)), "A setter failure cannot claim dim success")
            await settle { !f.service.isBusy }
            check(f.backend.value == original && f.backend.writes.count == 2,
                  "A setter that changed hardware before failing is rolled back from the prewrite journal")
            check(f.store.record == nil && f.assertions.active.isEmpty, "Rollback removes the journal only after verified restoration")
        }
        do {
            let f = Fixture()
            check(await f.service.setDimmed(true), "Manual override fixture begins dimmed")
            f.backend.value = 0.4
            let writes = f.backend.writes.count
            check(!(await f.service.setDimmed(true, targetBrightness: 0.1)), "A manual brightness change cancels ownership instead of fighting the user")
            check(f.backend.writes.count == writes && f.backend.value == 0.4 && f.store.record == nil && f.assertions.active.count == 1,
                  "Manual override preserves brightness while valid seated presence retains idle protection")
            check(!(await f.service.setDimmed(true)), "Repeated presence updates do not undo the manual override")
            check(f.assertions.created == 1 && f.backend.writes.count == writes,
                  "Repeated seated updates neither duplicate idle assertions nor fight manual brightness")
            check(!(await f.service.setDimmed(true, keepDisplayAwake: false)),
                  "Removing idle protection does not undo the manual brightness choice")
            check(f.assertions.active.isEmpty, "The caller can release idle protection without owning brightness")
            check(!(await f.service.setDimmed(true)), "A renewed seated request still respects manual brightness")
            check(f.assertions.active.count == 1 && f.backend.writes.count == writes,
                  "Renewed seated presence reacquires idle protection without a brightness write")
            check(await f.service.restore(), "Ending the episode clears manual suppression")
            check(f.assertions.active.isEmpty && f.backend.value == 0.4,
                  "Ending the episode releases idle protection and retains manually chosen brightness")
            check(await f.service.setDimmed(true), "A later removal episode may establish a new baseline")
            check(f.store.record?.baseline == 0.4, "A new episode uses the user's newer brightness")
            check(await f.service.restore(), "The new episode restores the newer baseline")
            check(f.backend.value == 0.4, "Old pre-override brightness is never restored over the manual choice")
        }
        for crashPoint in ["applied", "pending", "not-applied", "manual"] {
            let f = Fixture(), original = f.backend.value
            f.store.record = DisplayBrightnessRestoreRecord(displayID: f.backend.id, baseline: original,
                lastApplied: crashPoint == "pending" || crashPoint == "not-applied" ? original : 0.08,
                pendingTarget: crashPoint == "pending" || crashPoint == "not-applied" ? 0.08 : nil, createdAt: 1234)
            f.backend.value = crashPoint == "manual" ? 0.4 : (crashPoint == "not-applied" ? original : 0.08)
            check(await f.service.recoverIfNeeded(), "Next launch recovers an interrupted brightness transaction")
            check(f.backend.value == (crashPoint == "manual" ? 0.4 : original), "Crash recovery restores only brightness still owned by AirVeil")
            check(f.store.record == nil && f.assertions.created == 0, "Startup recovery clears its ledger and never asserts idle prevention")
        }
        do {
            let f = Fixture()
            check(await f.service.setDimmed(true), "Restore failure fixture begins dimmed")
            f.backend.readFailure = DisplayDimmingError.unsupported
            check(!(await f.service.restore()), "An unavailable display cannot claim successful restoration")
            check(f.service.hasPendingRestore && f.assertions.active.isEmpty, "Failed restoration retains the exact journal but releases idle prevention")
            f.backend.readFailure = nil
            check(await f.service.restore(), "A later explicit retry restores once the display becomes available")
        }
        do {
            let f = Fixture()
            f.backend.holdReads = true
            let dim = Task { await f.service.setDimmed(true) }
            await settle { f.backend.pendingReads.count == 1 }
            let restore = Task { await f.service.restore() }
            await Task.yield(); f.backend.holdReads = false; f.backend.completeRead()
            let dimResult = await dim.value, restoreResult = await restore.value
            check(!dimResult && restoreResult, "Restore supersedes a dim whose baseline read was delayed")
            check(f.backend.writes.isEmpty && f.store.record == nil, "A stale initial read cannot cause a later dim write")
        }
        do {
            let f = Fixture(), original = f.backend.value
            f.backend.holdWrites = true
            let dim = Task { await f.service.setDimmed(true) }
            await settle { f.backend.pendingWrites.count == 1 }
            let restore = Task { await f.service.restore() }
            await Task.yield()
            check(f.assertions.active.isEmpty, "Rewear releases idle assertion immediately while an old write is in flight")
            f.backend.holdWrites = false; f.backend.completeWrite()
            let dimResult = await dim.value, restoreResult = await restore.value
            check(!dimResult && restoreResult, "A completed old dim cannot overtake the newer restore request")
            check(f.backend.value == original && f.backend.writes.count == 2 && f.store.record == nil,
                  "Late dim is physically restored before the restore caller succeeds")
        }
        do {
            let f = Fixture(), original = f.backend.value
            check(await f.service.setDimmed(true), "Restore-to-dim race starts with owned brightness")
            f.backend.holdWrites = true
            let restore = Task { await f.service.restore() }
            await settle { f.backend.pendingWrites.count == 1 }
            let dimAgain = Task { await f.service.setDimmed(true, targetBrightness: 0.1) }
            await Task.yield(); f.backend.holdWrites = false; f.backend.completeWrite()
            let restored = await restore.value, dimmed = await dimAgain.value
            check(!restored && dimmed && f.service.isDimmed && close(f.backend.value, 0.1),
                  "A late old restore cannot clear a newer dim request or its physical target")
            check(f.store.record?.baseline == original && f.assertions.active.count == 1,
                  "The new dim after an in-flight restore still retains the actual original baseline")
            check(await f.service.restore(), "Final restore resolves the new dim episode")
            check(f.backend.value == original, "Reentrant restoration never captures the dim target as baseline")
        }
        do {
            let f = Fixture(), original = f.backend.value
            check(await f.service.setDimmed(true), "Suspension fixture begins dimmed")
            let before = f.backend.writes.count
            check(await f.service.suspendUntilActive(), "Display sleep or manual lock suspends control")
            check(f.service.isSuspended && f.service.hasPendingRestore && f.assertions.active.isEmpty,
                  "Suspension releases idle assertion and retains brightness restoration ownership")
            check(f.backend.writes.count == before, "Suspension never issues a brightness write that could wake the display")
            check(!(await f.service.setDimmed(true, targetBrightness: 0.1)), "A presence update cannot undo manual lock or sleeping suspension")
            check(await f.service.recoverIfNeeded(), "Explicit active-session recovery clears suspension and restores")
            check(f.backend.value == original && !f.service.isSuspended && f.store.record == nil,
                  "The exact pre-dim brightness returns after confirmed wake and unlock")
        }
        do {
            let f = Fixture(), original = f.backend.value
            f.backend.holdWrites = true
            let dim = Task { await f.service.setDimmed(true) }
            await settle { f.backend.pendingWrites.count == 1 }
            let suspend = Task { await f.service.suspendUntilActive() }
            await Task.yield(); f.backend.holdWrites = false; f.backend.completeWrite()
            let dimResult = await dim.value, suspendResult = await suspend.value
            check(!dimResult && suspendResult, "Suspension supersedes an already-issued dim")
            check(f.backend.writes.count == 1 && f.backend.value == 0.08 && f.service.hasPendingRestore && f.assertions.active.isEmpty,
                  "An in-flight dim is journaled but no restoration write occurs while suspended")
            check(await f.service.recoverIfNeeded(), "Wake recovery reconciles the previously in-flight write")
            check(f.backend.value == original && f.store.record == nil, "Late dim never loses the original baseline")
        }
        do {
            let f = Fixture(timeout: 0.03), original = f.backend.value
            f.backend.holdWrites = true
            let dim = Task { await f.service.setDimmed(true) }
            await settle { f.backend.pendingWrites.count == 1 }
            check(!(await dim.value), "A nonresponsive driver returns a bounded failure")
            check(f.service.isBusy && f.service.hasPendingRestore && f.assertions.active.isEmpty,
                  "Timeout does not pretend an in-flight brightness write was cancelled or restored")
            f.backend.holdWrites = false; f.backend.completeWrite()
            await settle { !f.service.isBusy }
            check(f.backend.value == original && f.store.record == nil,
                  "A late post-timeout write is automatically restored before the worker retires")
        }
        do {
            let suite = "AirVeil.DisplayDimmingTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = UserDefaultsBrightnessRestoreStore(defaults: defaults)
            let record = DisplayBrightnessRestoreRecord(displayID: "fixture", baseline: 0.8124999403953552,
                lastApplied: 0.08, pendingTarget: 0.1, createdAt: 1234)
            try store.save(record)
            check(try store.load() == record, "The injected isolated defaults ledger round-trips every exact restore field")
            try store.clear()
            check(try store.load() == nil, "Successful recovery can remove the durable ledger")
        }
        print("PASS: \(checks) brightness, restoration, suspension, assertion, and async ownership checks; injected hardware only")
    }
}
