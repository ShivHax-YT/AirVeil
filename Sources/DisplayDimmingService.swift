import Foundation
import Combine
import CoreGraphics
import ColorSync
import IOKit
import IOKit.graphics
import IOKit.pwr_mgt
import Darwin

struct DisplayBrightnessReading: Equatable, Sendable {
    let displayID: String
    let brightness: Double
}

struct DisplayBrightnessRestoreRecord: Codable, Equatable, Sendable {
    var version = 1
    let displayID: String
    let baseline: Double
    var lastApplied: Double
    var pendingTarget: Double?
    let createdAt: TimeInterval

    var isValid: Bool {
        version == 1 && !displayID.isEmpty && displayID.count <= 512 &&
        [baseline, lastApplied].allSatisfy { $0.isFinite && (0...1).contains($0) } &&
        (pendingTarget.map { $0.isFinite && (0...1).contains($0) } ?? true) && createdAt.isFinite
    }
}

enum DisplayDimmingError: LocalizedError, Equatable {
    case unsupported
    case invalidReading
    case readFailed(Int32)
    case writeFailed(Int32)
    case verificationFailed
    case assertionFailed(Int32)
    case ledgerFailed
    case timedOut
    case displayAsleep

    var errorDescription: String? {
        switch self {
        case .unsupported: return "This built-in display does not expose brightness control."
        case .invalidReading: return "The built-in display returned an invalid brightness value."
        case .readFailed(let code): return "Could not read built-in display brightness (\(code))."
        case .writeFailed(let code): return "Could not change built-in display brightness (\(code))."
        case .verificationFailed: return "The display did not confirm the requested brightness."
        case .assertionFailed(let code): return "Could not keep the dimmed display awake (\(code))."
        case .ledgerFailed: return "Could not save the brightness restore record."
        case .timedOut: return "Brightness control timed out. Any pending change will be restored when the display responds."
        case .displayAsleep: return "The display is asleep. Brightness restoration will wait until it is awake."
        }
    }
}

@MainActor protocol DisplayBrightnessControlling: AnyObject {
    func read(displayID: String?) async throws -> DisplayBrightnessReading
    func write(_ brightness: Double, displayID: String) async throws -> DisplayBrightnessReading
}

@MainActor protocol DisplayBrightnessRestoreStoring: AnyObject {
    func load() throws -> DisplayBrightnessRestoreRecord?
    func save(_ record: DisplayBrightnessRestoreRecord) throws
    func clear() throws
}

@MainActor protocol DisplayIdleAssertionControlling: AnyObject {
    func acquire() throws -> UInt32
    func release(_ assertion: UInt32)
}

/// Owns only changes to the built-in panel. A durable journal precedes every
/// brightness write, and one worker serializes writes with restoration. A late
/// dim cannot overtake a newer restore or silently capture its own dim as zero.
@MainActor final class DisplayDimmingService: ObservableObject {
    @Published private(set) var isDimmed = false
    @Published private(set) var isBusy = false
    @Published private(set) var status = "Display brightness is unchanged."
    @Published private(set) var lastError: String?
    var hasPendingRestore: Bool { record != nil }
    var keepsDisplayAwake: Bool { assertion != nil }
    var isSuspended: Bool { desired == .suspended }
    static let defaultTargetBrightness = 0.08
    static let targetRange = 0.05...0.5
    /// Permits hardware quantization, but is much smaller than one normal key step.
    private static let ownershipTolerance = 0.0125

    private enum Desired: Equatable {
        case restored
        case suspended
        case dimmed(Double, Bool)
    }
    private struct Waiter {
        let revision: UInt64
        let continuation: CheckedContinuation<Bool, Never>
        let timeout: Task<Void, Never>
    }
    private let brightness: any DisplayBrightnessControlling
    private let store: any DisplayBrightnessRestoreStoring
    private let assertions: any DisplayIdleAssertionControlling
    private let timeout: TimeInterval
    private let now: () -> TimeInterval
    private var desired: Desired = .restored
    private var revision: UInt64 = 0
    private var worker: Task<Void, Never>?
    private var waiters: [UUID: Waiter] = [:]
    private var record: DisplayBrightnessRestoreRecord?
    private var loadedLedger = false
    private var manualOverride = false
    private var assertion: UInt32?

    convenience init() {
        self.init(brightness: SystemBuiltInBrightnessController(),
                  store: UserDefaultsBrightnessRestoreStore(), assertions: SystemDisplayIdleAssertionController())
    }

    init(brightness: any DisplayBrightnessControlling,
         store: any DisplayBrightnessRestoreStoring,
         assertions: any DisplayIdleAssertionControlling,
         timeout: TimeInterval = 3,
         now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.brightness = brightness; self.store = store; self.assertions = assertions
        self.timeout = timeout.isFinite ? min(10, max(0.02, timeout)) : 3
        self.now = now
    }

    /// Call only while the removal policy explicitly requests dimming. The
    /// assertion prevents idle display sleep, never manual lock or system sleep.
    @discardableResult
    func setDimmed(_ dimmed: Bool, targetBrightness: Double = 0.08,
                   keepDisplayAwake: Bool = true) async -> Bool {
        guard dimmed else { return await restore() }
        guard !isSuspended else { return false }
        guard targetBrightness.isFinite else {
            lastError = DisplayDimmingError.invalidReading.localizedDescription
            status = lastError!; return false
        }
        let target = min(Self.targetRange.upperBound, max(Self.targetRange.lowerBound, targetBrightness))
        return await request(.dimmed(target, keepDisplayAwake))
    }

    /// Await true before resuming a dependent effect or completing normal quit.
    /// False leaves the journal available for retry or next-launch recovery.
    @discardableResult
    func restore() async -> Bool { await request(.restored) }

    /// Explicit startup recovery; initialization alone never changes hardware.
    @discardableResult
    func recoverIfNeeded() async -> Bool { await request(.restored) }

    /// Manual lock, display sleep, and inactive sessions win over dimming.
    /// Already-issued driver work is serialized to completion, but this state
    /// issues no new brightness writes. Wake/unlock explicitly recovers later.
    @discardableResult
    func suspendUntilActive() async -> Bool { await request(.suspended) }

    private func request(_ next: Desired) async -> Bool {
        if next == .restored {
            releaseAssertion()
            manualOverride = false
        } else if next == .suspended {
            releaseAssertion()
        } else if case .dimmed(_, false) = next { releaseAssertion() }
        if worker == nil || desired != next {
            revision &+= 1
            desired = next
        }
        let ticket = revision
        return await withCheckedContinuation { continuation in
            let id = UUID(), delay = timeout
            let deadline = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch { return }
                self?.timedOut(id: id, revision: ticket)
            }
            waiters[id] = Waiter(revision: ticket, continuation: continuation, timeout: deadline)
            if worker == nil {
                isBusy = true
                worker = Task { [self] in await reconcile() }
            }
        }
    }

    private func timedOut(id: UUID, revision ticket: UInt64) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(returning: false)
        guard ticket == revision else { return }
        releaseAssertion()
        lastError = DisplayDimmingError.timedOut.localizedDescription
        status = lastError!
        // Do not abandon an in-flight write: let the serial worker receive its
        // eventual result, then restore it. The journal survives forced exit.
        if desired != .suspended { desired = .restored }
        revision &+= 1
        finishWaiters(through: ticket, success: false)
    }

    private func reconcile() async {
        while true {
            let ticket = revision, requested = desired
            var success = false
            do {
                if !loadedLedger {
                    let stored = try store.load()
                    if let stored, !stored.isValid { throw DisplayDimmingError.ledgerFailed }
                    record = stored; loadedLedger = true
                }
                switch requested {
                case .restored: success = try await restoreOwnedBrightness(ticket: ticket)
                case .suspended:
                    releaseAssertion()
                    status = record == nil ? "Brightness control is paused while the session is inactive." :
                        "Brightness restoration is waiting for an active session."
                    success = true
                case .dimmed(let target, let awake): success = try await applyDim(target: target, awake: awake, ticket: ticket)
                }
            } catch {
                releaseAssertion()
                lastError = error.localizedDescription
                status = error.localizedDescription
                if ticket == revision, case .dimmed = requested, record != nil {
                    // A failed setter may already have changed the panel. Roll
                    // it back before any new operation instead of losing zero.
                    desired = .restored; revision &+= 1
                    finishWaiters(through: ticket, success: false)
                }
            }
            if ticket != revision { continue }
            worker = nil; isBusy = false
            finishWaiters(through: ticket, success: success)
            return
        }
    }

    private func applyDim(target: Double, awake: Bool, ticket: UInt64) async throws -> Bool {
        guard !manualOverride else {
            if awake, assertion == nil { assertion = try assertions.acquire() }
            status = "Brightness was adjusted manually. Your setting is being kept."
            return false
        }
        let current = try await brightness.read(displayID: record?.displayID)
        try validate(current, matching: record?.displayID)
        guard ticket == revision else { return false }
        if let record, !owns(current.brightness, record: record) {
            try relinquishOwnership()
            manualOverride = true
            if awake, assertion == nil { assertion = try assertions.acquire() }
            status = "Brightness was adjusted manually. Your setting is being kept."
            return false
        }
        if awake, assertion == nil { assertion = try assertions.acquire() }
        if !awake { releaseAssertion() }
        let original = record ?? DisplayBrightnessRestoreRecord(displayID: current.displayID,
            baseline: current.brightness, lastApplied: current.brightness, pendingTarget: nil, createdAt: now())
        let applied = min(original.baseline, target)
        if record != nil, original.pendingTarget == nil,
           abs(current.brightness - applied) <= 0.000001,
           abs(original.lastApplied - current.brightness) <= 0.000001 {
            // Presence polling does not repeatedly flush an unchanged journal.
            if !isDimmed { isDimmed = true }
            if lastError != nil { lastError = nil }
            let message = "Built-in display dimmed to \(Int((current.brightness * 100).rounded()))%."
            if status != message { status = message }
            return true
        }
        var journal = original
        journal.pendingTarget = applied
        try store.save(journal); record = journal
        let actual: DisplayBrightnessReading
        if abs(current.brightness - applied) <= 0.000001 { actual = current }
        else { actual = try await brightness.write(applied, displayID: original.displayID) }
        try validate(actual, matching: original.displayID)
        guard abs(actual.brightness - applied) <= Self.ownershipTolerance else { throw DisplayDimmingError.verificationFailed }
        journal.lastApplied = actual.brightness; journal.pendingTarget = nil
        try store.save(journal); record = journal
        isDimmed = true
        if ticket == revision {
            lastError = nil
            status = "Built-in display dimmed to \(Int((actual.brightness * 100).rounded()))%."
        }
        return true
    }

    private func restoreOwnedBrightness(ticket: UInt64) async throws -> Bool {
        releaseAssertion()
        guard var journal = record else {
            isDimmed = false
            if lastError == nil { status = "Display brightness is unchanged." }
            return true
        }
        let current = try await brightness.read(displayID: journal.displayID)
        try validate(current, matching: journal.displayID)
        guard ticket == revision else { return false }
        guard owns(current.brightness, record: journal) else {
            try relinquishOwnership()
            lastError = nil
            status = "Brightness was adjusted manually. Your setting was kept."
            return true
        }
        if abs(current.brightness - journal.baseline) > 0.000001 {
            journal.pendingTarget = journal.baseline
            try store.save(journal); record = journal
            let restored = try await brightness.write(journal.baseline, displayID: journal.displayID)
            try validate(restored, matching: journal.displayID)
            guard abs(restored.brightness - journal.baseline) <= Self.ownershipTolerance else { throw DisplayDimmingError.verificationFailed }
        }
        try store.clear(); record = nil
        isDimmed = false; lastError = nil
        status = "Original display brightness restored."
        return true
    }

    private func validate(_ reading: DisplayBrightnessReading, matching id: String? = nil) throws {
        guard !reading.displayID.isEmpty, reading.brightness.isFinite,
              (0...1).contains(reading.brightness), id == nil || id == reading.displayID else {
            throw DisplayDimmingError.invalidReading
        }
    }
    private func owns(_ value: Double, record: DisplayBrightnessRestoreRecord) -> Bool {
        abs(value - record.lastApplied) <= Self.ownershipTolerance ||
        record.pendingTarget.map { abs(value - $0) <= Self.ownershipTolerance } == true
    }
    private func relinquishOwnership() throws {
        // Brightness ownership and seated-presence idle protection are
        // independent. A brightness key press keeps the user's setting while
        // the caller's valid seated-presence request still keeps the display
        // awake. Restore, suspension, and failures release that assertion.
        try store.clear(); record = nil
        isDimmed = false
    }
    private func releaseAssertion() {
        if let assertion { assertions.release(assertion); self.assertion = nil }
    }
    private func finishWaiters(through ticket: UInt64, success: Bool) {
        let completed = waiters.filter { $0.value.revision <= ticket }
        for (id, waiter) in completed {
            waiters.removeValue(forKey: id)
            waiter.timeout.cancel()
            waiter.continuation.resume(returning: success && waiter.revision == ticket)
        }
    }
}

@MainActor final class UserDefaultsBrightnessRestoreStore: DisplayBrightnessRestoreStoring {
    private let defaults: UserDefaults
    private let key: String
    init(defaults: UserDefaults = .standard, key: String = "displayDimmingRestoreV1") {
        self.defaults = defaults; self.key = key
    }
    func load() throws -> DisplayBrightnessRestoreRecord? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try JSONDecoder().decode(DisplayBrightnessRestoreRecord.self, from: data)
    }
    func save(_ record: DisplayBrightnessRestoreRecord) throws {
        defaults.set(try JSONEncoder().encode(record), forKey: key)
        guard defaults.synchronize() else { throw DisplayDimmingError.ledgerFailed }
    }
    func clear() throws {
        defaults.removeObject(forKey: key)
        guard defaults.synchronize() else { throw DisplayDimmingError.ledgerFailed }
    }
}

@MainActor private final class SystemDisplayIdleAssertionController: DisplayIdleAssertionControlling {
    func acquire() throws -> UInt32 {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "AirVeil: confirmed presence while display is dimmed" as CFString, &id)
        guard result == kIOReturnSuccess else { throw DisplayDimmingError.assertionFailed(result) }
        return id
    }
    func release(_ assertion: UInt32) { IOPMAssertionRelease(assertion) }
}

@MainActor private final class SystemBuiltInBrightnessController: DisplayBrightnessControlling {
    private let queue = DispatchQueue(label: "AirVeil.BuiltInBrightness", qos: .userInitiated)
    private let worker = BuiltInBrightnessWorker()
    func read(displayID: String?) async throws -> DisplayBrightnessReading {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [worker] in
                do { continuation.resume(returning: try worker.read(displayID: displayID)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    func write(_ brightness: Double, displayID: String) async throws -> DisplayBrightnessReading {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [worker] in
                do { continuation.resume(returning: try worker.write(brightness, displayID: displayID)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// DisplayServices is runtime-loaded because Apple Silicon does not expose the
/// legacy IODisplay brightness service. The public IOKit path is a fallback for
/// older built-in panels. Neither route touches an external display or prefs.
private final class BuiltInBrightnessWorker: @unchecked Sendable {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private var framework: UnsafeMutableRawPointer?
    private var getter: GetBrightness?
    private var setter: SetBrightness?
    private var privateDisplay: CGDirectDisplayID?
    private var loaded = false
    deinit { if let framework { dlclose(framework) } }

    private func loadFramework() {
        guard !loaded else { return }; loaded = true
        framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL)
        guard let framework, let get = dlsym(framework, "DisplayServicesGetBrightness"),
              let set = dlsym(framework, "DisplayServicesSetBrightness") else { return }
        getter = unsafeBitCast(get, to: GetBrightness.self)
        setter = unsafeBitCast(set, to: SetBrightness.self)
    }
    private func builtInDisplay(matching identifier: String?) throws -> (CGDirectDisplayID, String) {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { throw DisplayDimmingError.unsupported }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard count > 0, CGGetOnlineDisplayList(count, &displays, &count) == .success else { throw DisplayDimmingError.unsupported }
        for id in displays.prefix(Int(count)) where CGDisplayIsBuiltin(id) != 0 {
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { continue }
            let stable = CFUUIDCreateString(nil, uuid) as String
            if identifier == nil || identifier == stable { return (id, stable) }
        }
        throw DisplayDimmingError.unsupported
    }
    func read(displayID: String?) throws -> DisplayBrightnessReading {
        let (display, stable) = try builtInDisplay(matching: displayID)
        loadFramework()
        if let getter {
            var value: Float = 0
            let result = getter(display, &value)
            if result == 0 {
                privateDisplay = display
                return DisplayBrightnessReading(displayID: stable, brightness: Double(value))
            }
        }
        privateDisplay = nil
        let service = try legacyService()
        defer { IOObjectRelease(service) }
        var value: Float = 0
        let result = IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &value)
        guard result == kIOReturnSuccess else { throw DisplayDimmingError.readFailed(result) }
        return DisplayBrightnessReading(displayID: stable, brightness: Double(value))
    }
    func write(_ brightness: Double, displayID: String) throws -> DisplayBrightnessReading {
        guard brightness.isFinite, (0...1).contains(brightness) else { throw DisplayDimmingError.invalidReading }
        let (display, _) = try builtInDisplay(matching: displayID)
        guard CGDisplayIsAsleep(display) == 0 else { throw DisplayDimmingError.displayAsleep }
        loadFramework()
        if privateDisplay == display, let setter {
            let result = setter(display, Float(brightness))
            guard result == 0 else { throw DisplayDimmingError.writeFailed(result) }
        } else {
            let service = try legacyService()
            defer { IOObjectRelease(service) }
            let result = IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, Float(brightness))
            guard result == kIOReturnSuccess else { throw DisplayDimmingError.writeFailed(result) }
        }
        return try read(displayID: displayID)
    }
    private func legacyService() throws -> io_service_t {
        // IOBacklightDisplay identifies an internal panel; never enumerate and
        // write generic external IODisplayConnect services.
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOBacklightDisplay"))
        guard service != 0 else { throw DisplayDimmingError.unsupported }
        return service
    }
}
