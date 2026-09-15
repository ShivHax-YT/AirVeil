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
    var quantizedZero: Double?
    var readingValues: [Double] = []
    var onRead: (() -> Void)?
    var reading: DisplayBrightnessReading { .init(displayID: id, brightness: value) }
    func read(displayID: String?) async throws -> DisplayBrightnessReading {
        reads += 1
        onRead?()
        if !readingValues.isEmpty { value = readingValues.removeFirst() }
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
        value = brightness == 0 ? (quantizedZero ?? 0) : brightness
        return reading
    }
    func completeRead() { pendingReads.removeFirst().resume(returning: reading) }
    func failRead(_ error: Error) { pendingReads.removeFirst().resume(throwing: error) }
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
    let wake = FakeWakeClock()
    let service: DisplayDimmingService
    init(timeout: TimeInterval = 1) {
        let clock = wake
        service = DisplayDimmingService(brightness: backend, store: store, assertions: assertions,
            timeout: timeout, now: { 1234 }, wakeClock: { clock.time },
            wakeDelay: { try await clock.wait($0) })
    }
}

@MainActor private final class FakeWakeClock {
    var time = 100.0
    var delays: [Double] = []
    var beforeDelay: ((Double) -> Void)?
    func wait(_ duration: Double) async throws {
        try Task.checkCancellation()
        beforeDelay?(duration)
        time += duration
        delays.append(duration)
        await Task.yield()
        try Task.checkCancellation()
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
            check(f.backend.writes.count == 1 && close(f.backend.value, 0), "Default brightness target is zero percent without display sleep")
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
            let f = Fixture(); f.backend.value = 0
            check(await f.service.setDimmed(true), "Already-zero brightness can still protect a confirmed occupied seat from idle sleep")
            check(f.backend.writes.isEmpty && f.assertions.active.count == 1 && f.store.record?.baseline == 0,
                  "An already-black screen retains its exact zero baseline without a physical write")
            check(await f.service.restore(), "An original zero restores safely")
            check(f.backend.value == 0 && f.backend.writes.isEmpty && f.assertions.active.isEmpty,
                  "Rewear never brightens a panel whose original brightness was zero")
        }
        do {
            let f = Fixture(), original = f.backend.value
            f.backend.quantizedZero = 0.01
            check(!(await f.service.setDimmed(true)), "A driver returning a visible one percent cannot claim a zero-percent blackout")
            await settle { !f.service.isBusy }
            check(f.backend.value == original && f.store.record == nil,
                  "Unconfirmed zero is restored from the durable original baseline")
        }
        do {
            let f = Fixture(); f.backend.value = 0.03
            check(await f.service.setDimmed(true, targetBrightness: 0.08), "An already-dark screen can enter the managed dim state")
            check(f.backend.value == 0.03 && f.backend.writes.isEmpty, "Dimming never brightens an already darker panel")
            check(await f.service.restore(), "An unchanged low baseline restores without raising brightness")
            check(f.backend.writes.isEmpty, "No write is needed when original brightness was already below target")
        }
        for (target, expected) in [(-1.0, 0.0), (0.0, 0.0), (2.0, 0.5)] {
            let f = Fixture()
            check(await f.service.setDimmed(true, targetBrightness: target), "Finite slider targets clamp to the supported range")
            check(close(f.backend.value, expected), "Brightness range is zero to fifty percent")
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
            let f = Fixture(), original = f.backend.value
            f.store.record = DisplayBrightnessRestoreRecord(displayID: f.backend.id, baseline: original,
                lastApplied: 0, pendingTarget: nil, createdAt: 1234)
            f.backend.value = 0
            check(await f.service.recoverIfNeeded(), "A crash during a zero-percent episode recovers on active relaunch")
            check(f.backend.value == original && f.store.record == nil && f.assertions.active.isEmpty,
                  "Blackout recovery restores the exact pre-blackout brightness without waking an idle assertion")
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
            check(f.store.record?.requiresWakeRestore == true,
                  "Explicit suspension durably distinguishes wake restoration from ordinary awake ownership")
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
            await settle { f.service.isSuspended }
            check(f.store.record?.requiresWakeRestore == true,
                  "Suspension saves wake ownership before the outstanding dim setter returns")
            f.backend.holdWrites = false; f.backend.completeWrite()
            let dimResult = await dim.value, suspendResult = await suspend.value
            check(!dimResult && suspendResult, "Suspension supersedes an already-issued dim")
            check(f.backend.writes.count == 1 && f.backend.value == 0 && f.service.hasPendingRestore && f.assertions.active.isEmpty,
                  "An in-flight dim is journaled but no restoration write occurs while suspended")
            check(f.store.record?.requiresWakeRestore == true,
                  "A late dim acknowledgement preserves the durable suspension flag")
            f.backend.value = 0.14
            check(await f.service.recoverIfNeeded(), "Wake recovery reconciles the previously in-flight write")
            check(f.backend.value == original && f.store.record == nil, "Late dim never loses the original baseline")
        }
        do {
            let f = Fixture(), original = f.backend.value
            check(await f.service.setDimmed(true, targetBrightness: 0.02), "Interrupted restore starts with the user's seated dim target")
            f.backend.holdWrites = true
            let restore = Task { await f.service.restore() }
            await settle { f.backend.pendingWrites.count == 1 }
            let suspend = Task { await f.service.suspendUntilActive() }
            await settle { f.service.isSuspended }
            f.backend.holdWrites = false; f.backend.completeWrite()
            let restored = await restore.value, suspended = await suspend.value
            check(!restored && suspended && f.service.isSuspended,
                  "Lock supersedes a driver restore that completes after suspension")
            check(f.store.record?.baseline == original && f.store.record?.pendingTarget == original,
                  "A late restore acknowledgement retains the exact durable baseline until awake verification")
            check(f.store.record?.requiresWakeRestore == true,
                  "Lock during an awaited restore durably preserves wake ownership")
            // Wake may report neither the previous dim nor the acknowledged
            // baseline. It is not evidence that the user touched brightness.
            f.backend.value = 0.14
            check(await f.service.recoverIfNeeded(), "A fresh activation rechecks the driver after the interrupted restore")
            check(f.backend.value == original && f.store.record == nil,
                  "The following wake restores the original instead of accepting its own dim as the next baseline")
        }
        for error in [DisplayDimmingError.displayAsleep, .readFailed(-7)] {
            let f = Fixture(), original = f.backend.value
            check(await f.service.setDimmed(true, targetBrightness: 0.02), "Wake read-failure fixture starts dimmed")
            check(await f.service.suspendUntilActive(), "Wake read-failure fixture retains its journal through sleep")
            f.backend.readFailure = error
            let writes = f.backend.writes.count
            check(!(await f.service.recoverIfNeeded()), "A sleeping or unreadable panel cannot confirm restoration")
            check(f.store.record?.baseline == original && f.backend.writes.count == writes,
                  "An untrusted wake reading never clears ownership or creates a dimmed baseline")
            f.backend.readFailure = nil
            check(await f.service.recoverIfNeeded(), "A later awake reading retries the same restoration")
            check(f.backend.value == original && f.store.record == nil,
                  "Successful wake recovery restores the original after a transient read failure")
        }
        do {
            let f = Fixture(), original = f.backend.value
            check(await f.service.setDimmed(true, targetBrightness: 0.02), "Failed restore setter fixture starts dimmed")
            f.backend.nextWriteFailure = DisplayDimmingError.writeFailed(-8)
            f.backend.failAfterApplying = true
            check(!(await f.service.restore()), "A setter error cannot claim a completed restore even after applying it")
            check(f.store.record?.baseline == original && f.store.record?.pendingTarget == original,
                  "A failed restore setter retains the original and pending baseline for verification")
            check(await f.service.recoverIfNeeded(), "A later verified baseline resolves an uncertain restore setter")
            check(f.backend.value == original && f.store.record == nil,
                  "Uncertain restore completion never replaces the original baseline")
        }
        for order in ["rewear-before-unlock", "unlock-before-rewear"] {
            let f = Fixture(), original = 0.6252058744430542
            f.backend.value = original
            for (cycle, wakeValue) in [0.04, 0.14, 0.49, 0.91].enumerated() {
                check(await f.service.setDimmed(true, targetBrightness: 0.23),
                      "\(order) cycle \(cycle): seated removal starts an owned dim")
                check(f.store.record?.baseline == original,
                      "\(order) cycle \(cycle): repeated removal keeps the undimmed baseline")
                check(await f.service.suspendUntilActive(),
                      "\(order) cycle \(cycle): departure suspends without discarding ownership")
                let writes = f.backend.writes.count
                f.backend.value = wakeValue
                if order == "rewear-before-unlock" {
                    // Rewear alone does not grant an active session. The caller
                    // keeps the dimmer suspended until unlock is confirmed.
                    check(await f.service.suspendUntilActive(),
                          "Rewear before unlock leaves brightness suspended")
                    check(f.backend.writes.count == writes,
                          "Fresh AirPods cannot issue a brightness write while locked")
                }
                check(await f.service.recoverIfNeeded(),
                      "\(order) cycle \(cycle): confirmed activation restores despite a changed wake reading")
                check(f.backend.value == original && f.store.record == nil && !f.service.hasPendingRestore,
                      "\(order) cycle \(cycle): wake restores the exact original, including when the OS reading is higher")
                check(f.service.lastRestoreObservedBrightness == wakeValue &&
                      f.service.lastRestorationDecision == "wake-restore-verified",
                      "\(order) cycle \(cycle): diagnostics retain the actual pre-restore wake reading and decision")
                if order == "unlock-before-rewear" {
                    check(await f.service.setDimmed(true, targetBrightness: 0.23),
                          "A fresh seated check may dim again while unlocked AirPods remain out")
                    check(f.store.record?.baseline == original && f.store.record?.requiresWakeRestore == true,
                          "An immediately resumed seated episode captures the restored baseline with bounded wake ownership")
                    check(await f.service.restore(), "Later rewear restores the resumed seated episode")
                    check(f.backend.value == original, "Unlock-first then rewear restores consistently on every cycle")
                }
            }
        }
        do {
            let f = Fixture(), original = f.backend.value
            check(await f.service.setDimmed(true, targetBrightness: 0.23), "Durable wake fixture begins dimmed")
            check(await f.service.suspendUntilActive(), "Durable wake fixture records suspension")
            // Serialize through Codable, as the real persistent store does,
            // then construct a new service without relying on in-memory flags.
            let journal = try JSONEncoder().encode(f.store.record!)
            f.store.record = try JSONDecoder().decode(DisplayBrightnessRestoreRecord.self, from: journal)
            f.backend.value = 0.09
            let relaunched = DisplayDimmingService(brightness: f.backend, store: f.store,
                assertions: f.assertions, now: { 1235 }, wakeClock: { f.wake.time },
                wakeDelay: { try await f.wake.wait($0) })
            check(await relaunched.recoverIfNeeded(), "Active relaunch restores durable suspended ownership")
            check(f.backend.value == original && f.store.record == nil &&
                  relaunched.lastRestoreObservedBrightness == 0.09 && relaunched.lastRestorationDecision == "wake-restore-verified",
                  "Interrupted relaunch preserves the baseline even when wake changed brightness")
        }
        do {
            let legacy = Data(#"{"version":1,"displayID":"legacy","baseline":0.8,"lastApplied":0.2,"createdAt":1234}"#.utf8)
            let record = try JSONDecoder().decode(DisplayBrightnessRestoreRecord.self, from: legacy)
            check(record.isValid && record.requiresWakeRestore == nil,
                  "Existing version-one journals decode without inventing a historical suspension")
        }
        do {
            let f = Fixture(), original = f.backend.value
            check(await f.service.setDimmed(true, targetBrightness: 0.23), "Wake write-failure fixture begins dimmed")
            check(await f.service.suspendUntilActive(), "Wake write-failure fixture records suspension")
            f.backend.value = 0.1
            f.backend.nextWriteFailure = DisplayDimmingError.writeFailed(-9)
            check(!(await f.service.recoverIfNeeded()), "A failed wake setter cannot claim restoration")
            check(f.store.record?.requiresWakeRestore == true && f.store.record?.baseline == original,
                  "Failed wake restoration keeps its durable baseline and wake intent for retry")
            f.backend.value = 0.16
            check(await f.service.recoverIfNeeded(), "A changed reading during retry still restores the suspended baseline")
            check(f.backend.value == original && f.store.record == nil,
                  "A later verified wake retry is the point where ownership is cleared")
        }
        do {
            let f = Fixture(), original = f.backend.value
            check(await f.service.setDimmed(true, targetBrightness: 0.23), "Delayed restore-read fixture begins dimmed")
            f.backend.holdReads = true
            let restore = Task { await f.service.restore() }
            await settle { f.backend.pendingReads.count == 1 }
            let suspend = Task { await f.service.suspendUntilActive() }
            await settle { f.service.isSuspended }
            f.backend.value = 0.11
            f.backend.holdReads = false; f.backend.completeRead()
            let restored = await restore.value, suspended = await suspend.value
            check(!restored && suspended,
                  "Suspension supersedes an awaited restoration read")
            check(f.store.record?.requiresWakeRestore == true && f.backend.writes.count == 1,
                  "A late read cannot relinquish wake ownership or write while suspended")
            check(await f.service.recoverIfNeeded(), "Activation restores after suspension interrupted the earlier read")
            check(f.backend.value == original && f.store.record == nil,
                  "Interrupted restore-read ownership survives through verified wake")
        }
        do {
            let f = Fixture(), original = f.backend.value
            check(await f.service.setDimmed(true, targetBrightness: 0.23), "Second-lock fixture begins dimmed")
            check(await f.service.suspendUntilActive(), "First lock records durable wake ownership")
            f.backend.value = 0.13; f.backend.holdWrites = true
            let recovery = Task { await f.service.recoverIfNeeded() }
            await settle { f.backend.pendingWrites.count == 1 }
            let secondLock = Task { await f.service.suspendUntilActive() }
            await settle { f.service.isSuspended }
            f.backend.holdWrites = false; f.backend.completeWrite()
            let recovered = await recovery.value, suspended = await secondLock.value
            check(!recovered && suspended && f.store.record?.requiresWakeRestore == true &&
                  f.store.record?.baseline == original && f.store.record?.pendingTarget == original,
                  "A second lock defeats a late wake-restore acknowledgement and retains all ownership")
            f.backend.value = 0.07
            check(await f.service.recoverIfNeeded(), "The second unlock retries restoration against another changed panel value")
            check(f.backend.value == original && f.store.record == nil,
                  "Only verified restoration in the newest active session clears the suspended baseline")
        }
        do {
            let f = Fixture(); f.backend.value = 0
            check(await f.service.setDimmed(true), "Wake verification fixture records an original zero")
            check(await f.service.suspendUntilActive(), "Original zero remains owned through suspension")
            f.backend.value = 0.17; f.backend.quantizedZero = 0.01
            check(!(await f.service.recoverIfNeeded()), "A setter that does not verify the wake baseline cannot claim success")
            check(f.store.record?.requiresWakeRestore == true && f.store.record?.baseline == 0,
                  "Unverified wake restoration retains the durable zero baseline")
            f.backend.quantizedZero = nil
            check(await f.service.recoverIfNeeded(), "Wake restoration retries after an unverified setter result")
            check(f.backend.value == 0 && f.store.record == nil,
                  "The journal clears only when the actual wake baseline is verified")
        }
        do {
            let f = Fixture()
            check(await f.service.setDimmed(true, targetBrightness: 0.23), "Awake manual restore fixture starts dimmed")
            f.backend.value = 0.4
            let writes = f.backend.writes.count
            check(await f.service.restore(), "An uninterrupted awake manual brightness adjustment resolves ownership")
            check(f.backend.value == 0.4 && f.backend.writes.count == writes && f.store.record == nil &&
                  f.service.lastRestorationDecision == "manual-override-preserved",
                  "Normal awake restoration still respects manual brightness without writing the former baseline")
            check(await f.service.suspendUntilActive(), "Suspending after an observed manual edit has no owned dim")
            check(await f.service.recoverIfNeeded(), "Wake after an observed manual edit is harmless")
            check(f.backend.value == 0.4 && f.backend.writes.count == writes,
                  "Wake cannot recreate ownership already relinquished to an awake manual edit")
        }
        do {
            let f = Fixture()
            check(await f.service.setDimmed(true, targetBrightness: 0.23), "Post-wake manual fixture starts dimmed")
            check(await f.service.suspendUntilActive(), "Post-wake manual fixture records suspension")
            f.backend.value = 0.12
            check(await f.service.recoverIfNeeded(), "Wake restoration completes before a subsequent awake episode")
            f.wake.time += 16
            check(await f.service.setDimmed(true, targetBrightness: 0.23), "A new awake episode starts after verified wake restoration")
            f.backend.value = 0.43
            let writes = f.backend.writes.count
            check(await f.service.restore(), "A manual adjustment in the new awake episode is preserved")
            check(f.backend.value == 0.43 && f.backend.writes.count == writes &&
                  f.service.lastRestorationDecision == "manual-override-preserved",
                  "The wake-restoration exception does not leak into later ordinary awake dimming")
        }
        do {
            let f = Fixture()
            check(await f.service.suspendUntilActive(), "Unlock-first fixture suspends without any dim journal")
            f.backend.readingValues = [1, 0.82, 0.66, 0.66, 0.66, 0.66]
            check(await f.service.recoverIfNeeded(), "Empty-journal activation waits for changing wake brightness to settle")
            check(f.wake.delays.first == 3 && f.wake.time >= 104 && f.backend.value == 0.66 &&
                  f.backend.writes.isEmpty && !f.service.awaitingWakeStability,
                  "No new dim is permitted until the quiet interval and stable awake readings finish")
            check(await f.service.setDimmed(true, targetBrightness: 0.23), "Fresh presence can dim after the wake barrier")
            check(f.store.record?.baseline == 0.66 && f.store.record?.requiresWakeRestore == true,
                  "The new post-wake journal uses the settled baseline and records wake ownership")
            f.backend.value = 0.2691709101200104
            check(await f.service.restore(), "Rewear restores a newly created post-wake dim despite the observed changed getter value")
            check(f.backend.value == 0.66 && f.store.record == nil &&
                  f.service.lastRestoreObservedBrightness == 0.2691709101200104 &&
                  f.service.lastRestorationDecision == "wake-restore-verified",
                  "The reproduced altered post-dim reading is not mislabeled as an intentional manual edit")
        }
        do {
            let f = Fixture(); f.backend.value = 1
            check(await f.service.suspendUntilActive(), "Stable full-brightness fixture begins without a journal")
            check(await f.service.recoverIfNeeded(), "A stable full-brightness wake reading remains a valid user baseline")
            check(await f.service.setDimmed(true, targetBrightness: 0.23), "The accepted full-brightness baseline can be dimmed")
            f.backend.value = 0.2691709101200104
            check(await f.service.restore(), "The observed 1.0 → 0.23 → 0.26917 sequence restores its recorded stable baseline")
            check(f.backend.value == 1 && f.store.record == nil,
                  "The fix does not assume that every 1.0 wake reading is transient or substitute historical brightness")
        }
        do {
            let f = Fixture(); f.backend.value = 0.66
            check(await f.service.suspendUntilActive(), "Delayed baseline-change fixture suspends without ownership")
            check(await f.service.recoverIfNeeded(), "Initial wake readings stabilize before a later dim request")
            f.backend.readingValues = [1, 0.92, 0.66, 0.66, 0.66, 0.66]
            check(await f.service.setDimmed(true, targetBrightness: 0.23), "A changed first-dim reading is itself stabilized")
            check(f.store.record?.baseline == 0.66 && f.store.record?.requiresWakeRestore == true && f.backend.writes.count == 1,
                  "A later transient wake reading cannot become the baseline of the new dim")
            f.backend.value = 0.2691709101200104
            check(await f.service.setDimmed(true, targetBrightness: 0.18), "A target update respects existing post-wake ownership")
            check(f.store.record?.baseline == 0.66 && f.store.record?.requiresWakeRestore == true && f.backend.value == 0.18,
                  "Repeated dim requests cannot discard a wake-tagged baseline on an altered OS value")
            check(await f.service.restore(), "The updated target still restores the same settled baseline")
            check(f.backend.value == 0.66, "Changing the dim target never replaces the original wake baseline")
        }
        do {
            let f = Fixture()
            check(await f.service.suspendUntilActive(), "Unsettled empty-journal fixture records a wake boundary")
            f.backend.onRead = { f.backend.value = f.backend.reads.isMultiple(of: 2) ? 0.6 : 0.9 }
            check(!(await f.service.recoverIfNeeded()), "Continuously changing awake readings fail within the bounded settling interval")
            check(f.service.awaitingWakeStability && !f.service.hasPendingRestore && f.backend.writes.isEmpty &&
                  f.wake.time <= 108.000001 && f.service.lastError != nil,
                  "No-journal failure keeps the recovery barrier pending without inventing ownership or writing brightness")
            check(!(await f.service.setDimmed(true)), "New dimming cannot bypass failed no-journal wake settling")
            let reads = f.backend.reads
            check(await f.service.suspendUntilActive(), "A new lock cancels the pending active-session recovery")
            check(f.backend.reads == reads && f.backend.writes.isEmpty,
                  "Remaining locked performs no settling reads or brightness writes")
            f.backend.onRead = nil; f.backend.value = 0.7
            check(await f.service.recoverIfNeeded(), "A later active retry can finish empty-journal stabilization")
            check(!f.service.awaitingWakeStability && !f.service.hasPendingRestore && f.service.lastError == nil,
                  "Successful no-journal retry releases the brightness barrier without starting sensors")
        }
        do {
            let f = Fixture(); f.backend.value = 0.66
            check(await f.service.suspendUntilActive(), "First-dim settling failure fixture crosses a wake boundary")
            check(await f.service.recoverIfNeeded(), "Initial activation settles before the first-dim instability")
            f.backend.onRead = { f.backend.value = f.backend.reads.isMultiple(of: 2) ? 0.6 : 0.9 }
            check(!(await f.service.setDimmed(true, targetBrightness: 0.23)),
                  "A changing first-dim baseline cannot be captured after the settling limit")
            check(f.service.awaitingWakeStability && !f.service.hasPendingRestore && f.backend.writes.isEmpty,
                  "Failed first-dim stabilization retains the recovery barrier without creating ownership")
            f.wake.time += 16
            check(!(await f.service.setDimmed(true)),
                  "An expired wake window cannot bypass the unresolved first-dim stability barrier")
            f.backend.onRead = nil; f.backend.value = 0.7
            check(await f.service.recoverIfNeeded(), "Explicit recovery retries the unresolved first-dim instability")
            check(!f.service.awaitingWakeStability && f.backend.writes.isEmpty,
                  "Stable recovery clears the barrier while preserving the current user brightness")
        }
        do {
            let f = Fixture()
            check(await f.service.setDimmed(true, targetBrightness: 0.23), "Unsettled owned-journal fixture records baseline")
            let original = f.store.record!.baseline
            check(await f.service.suspendUntilActive(), "Existing ownership crosses the wake boundary")
            f.backend.onRead = { f.backend.value = f.backend.reads.isMultiple(of: 2) ? 0.3 : 0.5 }
            let writes = f.backend.writes.count
            check(!(await f.service.recoverIfNeeded()), "An owned baseline waits when awake values never stabilize")
            check(f.service.awaitingWakeStability && f.store.record?.baseline == original &&
                  f.store.record?.requiresWakeRestore == true && f.backend.writes.count == writes && f.store.clears == 0,
                  "The durable journal is neither cleared nor replaced before wake readings are trustworthy")
            f.backend.onRead = nil; f.backend.value = 0.2691709101200104
            check(await f.service.recoverIfNeeded(), "A later stable reading permits the retained wake restoration")
            check(f.backend.value == original && f.store.record == nil,
                  "Settling failure preserves original ownership across retries")
        }
        do {
            let f = Fixture(); f.backend.value = 0.72
            check(await f.service.suspendUntilActive(), "Expired wake-window fixture starts with empty-journal suspension")
            check(await f.service.recoverIfNeeded(), "The wake context begins only after successful stabilization")
            f.wake.time += 3600
            check(await f.service.setDimmed(true, targetBrightness: 0.23), "An unrelated dim an hour later behaves as ordinary awake dimming")
            check(f.store.record?.requiresWakeRestore != true, "An unrelated future dim does not inherit stale wake ownership")
            f.backend.value = 0.4
            let writes = f.backend.writes.count
            check(await f.service.restore(), "A manual edit in the later unrelated episode remains authoritative")
            check(f.backend.value == 0.4 && f.backend.writes.count == writes &&
                  f.service.lastRestorationDecision == "manual-override-preserved",
                  "Bounded post-wake protection does not weaken normal awake manual override respect")
        }
        do {
            let f = Fixture(); f.backend.value = 0.68
            check(await f.service.suspendUntilActive(), "New post-wake relaunch fixture starts without ownership")
            check(await f.service.recoverIfNeeded(), "New post-wake relaunch fixture establishes a stable baseline")
            check(await f.service.setDimmed(true, targetBrightness: 0.23), "First post-wake dim records durable protection")
            f.store.record = try JSONDecoder().decode(DisplayBrightnessRestoreRecord.self,
                from: JSONEncoder().encode(f.store.record!))
            f.backend.value = 0.2691709101200104
            let recovered = DisplayDimmingService(brightness: f.backend, store: f.store, assertions: f.assertions,
                wakeClock: { f.wake.time }, wakeDelay: { try await f.wake.wait($0) })
            check(await recovered.recoverIfNeeded(), "Relaunch settles and restores a journal created after the previous wake")
            check(f.backend.value == 0.68 && f.store.record == nil,
                  "Post-wake ownership survives a process interruption and altered getter value")
        }
        do {
            let f = Fixture()
            check(await f.service.suspendUntilActive(), "Unsupported empty-journal fixture records suspension")
            f.backend.readFailure = DisplayDimmingError.unsupported
            check(await f.service.recoverIfNeeded(), "A Mac without controllable built-in brightness can finish empty-journal recovery")
            check(!f.service.awaitingWakeStability && !f.service.hasPendingRestore && f.service.lastError == nil &&
                  f.service.lastRestorationDecision == "wake-dimming-unavailable" && f.backend.writes.isEmpty,
                  "Unsupported brightness alone does not block camera or motion recovery when nothing needs restoration")
        }
        do {
            let f = Fixture()
            check(await f.service.suspendUntilActive(), "Late unsupported-read fixture begins without a journal")
            f.backend.holdReads = true
            let recovery = Task { await f.service.recoverIfNeeded() }
            await settle { f.backend.pendingReads.count == 1 }
            let locked = Task { await f.service.suspendUntilActive() }
            await settle { f.service.isSuspended }
            f.backend.holdReads = false
            f.backend.failRead(DisplayDimmingError.unsupported)
            let recovered = await recovery.value, suspended = await locked.value
            check(!recovered && suspended && f.service.awaitingWakeStability,
                  "An old unsupported read cannot clear the new suspension's wake barrier")
            check(f.backend.writes.isEmpty && f.store.record == nil,
                  "A stale unsupported recovery result neither writes brightness nor creates ownership")
            let reads = f.backend.reads, delays = f.wake.delays.count
            check(await f.service.recoverIfNeeded(), "A subsequent active recovery retries after the stale unsupported result")
            check(f.backend.reads >= reads + 4 && f.wake.delays[delays] == 3 && !f.service.awaitingWakeStability,
                  "The next active recovery still performs its quiet interval and stable brightness readings")
        }
        do {
            let backend = FakeBrightness(), store = FakeRestoreStore(), assertions = FakeIdleAssertions()
            var waiting = false
            let service = DisplayDimmingService(brightness: backend, store: store, assertions: assertions,
                wakeDelay: { _ in waiting = true; try await Task.sleep(nanoseconds: 30_000_000_000) })
            check(await service.suspendUntilActive(), "Timer cancellation fixture records suspension")
            let recovery = Task { await service.recoverIfNeeded() }
            await settle { waiting }
            let locked = Task { await service.suspendUntilActive() }
            let recovered = await recovery.value, suspended = await locked.value
            check(!recovered && suspended && service.isSuspended && service.awaitingWakeStability,
                  "New lock immediately cancels the settling timer instead of waiting for its duration")
            check(backend.reads == 0 && backend.writes.isEmpty,
                  "Cancelled wake settling cannot start hardware work after the lock")
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
