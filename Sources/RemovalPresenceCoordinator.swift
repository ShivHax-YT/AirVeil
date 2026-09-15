import Foundation
import Combine

@MainActor protocol RemovalPresenceMonitoring: AnyObject {
    var state: PresenceState { get }
    var status: String { get }
    func start(reference: PresenceSeatReference) async throws
    func stop() async
    func refresh()
}

@MainActor protocol RemovalPresenceDimming: AnyObject {
    var isDimmed: Bool { get }
    var isBusy: Bool { get }
    var hasPendingRestore: Bool { get }
    var status: String { get }
    func setDimmed(_ dimmed: Bool, targetBrightness: Double, keepDisplayAwake: Bool) async -> Bool
    func restore() async -> Bool
    func recoverIfNeeded() async -> Bool
    func suspendUntilActive() async -> Bool
}

extension PresenceService: RemovalPresenceMonitoring {}
extension DisplayDimmingService: RemovalPresenceDimming {}

enum RemovalPresencePhase: String, Equatable {
    case idle, preparing, checking, present, uncertain, finishing, sleeping, suspended, failed
}

/// Owns one debounced removal episode. Geometry confirms occupancy, never
/// identity. The caller owns removal detection, lock state, and camera handoff.
@MainActor final class RemovalPresenceCoordinator: ObservableObject {
    @Published private(set) var status = "Presence-aware removal is idle."
    @Published private(set) var isActive = false
    @Published private(set) var isBusy = false
    @Published private(set) var phase: RemovalPresencePhase = .idle

    var canResumeHeading: Bool {
        !isActive && !isBusy && !inactive && phase != .sleeping &&
        cameraFullyStopped && restorationConfirmed && !dimmer.isBusy && !dimmer.hasPendingRestore
    }

    private let presence: any RemovalPresenceMonitoring
    private let dimmer: any RemovalPresenceDimming
    private let prepareCamera: @MainActor () async -> Void
    private let requestDisplaySleep: @MainActor () async throws -> Void
    private let unknownGrace: Double
    private var generation: UInt64 = 0
    private var dimRevision: UInt64 = 0
    private var startTask: Task<Void, Never>?
    private var dimTask: Task<Void, Never>?
    private var cleanupTask: Task<Bool, Never>?
    private var stopBarrier: (id: UInt64, task: Task<Void, Never>)?
    private var stopRevision: UInt64 = 0
    private var cameraFullyStopped = true
    private var restorationConfirmed = true
    private var inactive = false
    private var presenceStarted = false
    private var sleepConsumed = false
    private var departureArmed = false
    private var unknownSince: Double?
    private var lastTime = 0.0
    private var target = 0.0
    private var requestedTarget: Double?
    private var dimError: String?
    private var allowsDimming = true
    private var allowsUncertainSleep = true

    convenience init(prepareCamera: @escaping @MainActor () async -> Void,
                     requestDisplaySleep: @escaping @MainActor () async throws -> Void) {
        self.init(presence: PresenceService(), dimmer: DisplayDimmingService(),
                  prepareCamera: prepareCamera, requestDisplaySleep: requestDisplaySleep)
    }

    init(presence: any RemovalPresenceMonitoring, dimmer: any RemovalPresenceDimming,
         prepareCamera: @escaping @MainActor () async -> Void,
         requestDisplaySleep: @escaping @MainActor () async throws -> Void,
         unknownGrace: Double = 8) {
        self.presence = presence; self.dimmer = dimmer
        self.prepareCamera = prepareCamera; self.requestDisplaySleep = requestDisplaySleep
        self.unknownGrace = unknownGrace.isFinite ? max(0.1, unknownGrace) : 8
    }

    /// Call once for an explicit, debounced removal event. A resumed episode
    /// requires fresh presence before it may put a manually woken display back
    /// to sleep. No reference means no invented foreground seat.
    func begin(reference: PresenceSeatReference?, targetBrightness: Double = 0,
               now: Double, allowSleepBeforePresence: Bool = true,
               allowDimming: Bool = true, allowUncertainSleep: Bool = true) {
        guard !inactive else { status = "Presence checks are paused while the session is inactive."; return }
        guard now.isFinite, now >= 0 else { cancel(); status = "Presence timing is unavailable."; return }
        let ticket = invalidate()
        target = normalizedTarget(targetBrightness)
        allowsDimming = allowDimming; allowsUncertainSleep = allowUncertainSleep
        lastTime = now; unknownSince = now
        sleepConsumed = false; departureArmed = allowSleepBeforePresence
        presenceStarted = false; requestedTarget = nil; dimError = nil
        isActive = true; isBusy = true; phase = .preparing
        status = "Preparing a local foreground-seat check."
        guard let reference, PresenceTracker.isReferenceUsable(reference, now: now) else {
            if departureArmed && allowsUncertainSleep { sleepOnce(reason: "No usable seat reference is available. Using the existing display-sleep action.") }
            else { finishWithoutSleep(reason: allowsUncertainSleep
                ? "Wear your AirPods before another automatic removal action."
                : "No current seat reference is available. Set center before automatic removal checks.") }
            return
        }
        let cleanup = startCleanup(ticket: ticket, suspend: false)
        startTask = Task { [weak self] in
            guard let self else { return }
            let restored = await cleanup.value
            guard current(ticket) else { return }
            guard restored else {
                isActive = false
                finishCleanup(restored: false, suspended: false)
                return
            }
            await prepareCamera()
            guard current(ticket) else { return }
            cameraFullyStopped = false
            do {
                try await presence.start(reference: reference)
                guard current(ticket) else { return }
                presenceStarted = true; isBusy = false; phase = .checking
                status = "Checking whether the foreground seat is occupied."
            } catch {
                guard current(ticket) else { return }
                isBusy = false; phase = .uncertain
                status = error.localizedDescription
            }
        }
    }

    /// Clock ticks expire uncertainty; only the presence engine can confirm an
    /// empty seat. The bounded error fallback is explicitly distinct from it.
    func update(now: Double) {
        guard isActive, !inactive, !sleepConsumed, now.isFinite, now >= lastTime,
              phase != .finishing else { return }
        lastTime = now
        if presenceStarted { presence.refresh() }
        let state: PresenceState = presenceStarted ? presence.state : .unknown
        switch state {
        case .present:
            guard allowsDimming else {
                finishWithoutSleep(reason: "You are still seated. The AirPods connection changed; brightness stays unchanged.")
                return
            }
            departureArmed = true; unknownSince = nil
            phase = .present
            status = dimError ?? (dimmer.isDimmed ? "You are still seated. The display stays dimmed." : "You are still seated. Dimming the built-in display.")
            if requestedTarget != target { requestDim(target) }
        case .absent:
            if departureArmed { sleepOnce(reason: "The foreground seat is empty. Turning off the display.") }
            else { finishWithoutSleep(reason: "Automatic removal sleep remains paused until fresh seated presence or another wear session.") }
        case .unknown:
            if unknownSince == nil { unknownSince = now }
            if phase != .preparing {
                phase = .uncertain
                if presenceStarted { status = presence.status }
            }
            guard let unknownSince, now - unknownSince >= unknownGrace else { return }
            if departureArmed && allowsUncertainSleep { sleepOnce(reason: "Presence could not be confirmed within the grace period. Using the existing display-sleep action.") }
            else if !allowsUncertainSleep { finishWithoutSleep(reason: "Presence could not be confirmed. The check ended and any dimmed brightness was restored.") }
            else { finishWithoutSleep(reason: "Presence remains uncertain. Automatic removal sleep stays paused after manual wake.") }
        }
    }

    func updateTarget(_ brightness: Double) {
        guard brightness.isFinite else { return }
        let next = normalizedTarget(brightness)
        guard next != target else { return }
        target = next
        if allowsDimming, isActive, !inactive, !sleepConsumed, requestedTarget != nil { requestDim(next) }
    }

    /// Invalidates work synchronously; cleanup may need to await a camera or
    /// driver operation. Heading stays blocked until the barriers complete.
    func cancel(inactive requestedInactive: Bool = false) {
        // Ordinary Pause/Enable must remain synchronous when this controller
        // has no camera or brightness work to finish.
        if !requestedInactive, canResumeHeading { return }
        inactive = inactive || requestedInactive
        let ticket = invalidate()
        isActive = false; isBusy = true
        phase = inactive ? .suspended : .finishing
        status = inactive ? "Presence checks are paused while the session is inactive." : "Stopping presence and restoring brightness."
        let cleanup = startCleanup(ticket: ticket, suspend: inactive)
        Task { [weak self] in
            let restored = await cleanup.value
            guard let self, self.generation == ticket else { return }
            self.finishCleanup(restored: restored, suspended: self.inactive)
        }
    }

    func suspend() { cancel(inactive: true) }

    /// Called only after the caller independently confirms awake and unlocked.
    @discardableResult
    func recoverAfterActivation() async -> Bool {
        inactive = false
        return await finishForRewear(recoveringAfterActivation: true)
    }

    @discardableResult
    func finishForRewear() async -> Bool {
        await finishForRewear(recoveringAfterActivation: false)
    }

    private func finishForRewear(recoveringAfterActivation: Bool) async -> Bool {
        let ticket = invalidate()
        isActive = false; isBusy = true; phase = inactive ? .suspended : .finishing
        status = "Stopping presence and restoring brightness before head tracking."
        let restored = await startCleanup(ticket: ticket, suspend: inactive,
            recoveringAfterActivation: recoveringAfterActivation).value
        guard generation == ticket else { return false }
        finishCleanup(restored: restored, suspended: inactive)
        return canResumeHeading
    }

    private func requestDim(_ value: Double) {
        requestedTarget = value; dimError = nil; restorationConfirmed = false
        dimRevision &+= 1
        let revision = dimRevision, ticket = generation
        dimTask?.cancel()
        isBusy = true
        dimTask = Task { [weak self] in
            guard let self, current(ticket), dimRevision == revision else { return }
            let changed = await dimmer.setDimmed(true, targetBrightness: value, keepDisplayAwake: true)
            guard current(ticket), dimRevision == revision else { return }
            isBusy = false
            if !changed { dimError = dimmer.status }
            if phase == .present { status = changed ? "You are still seated. The display stays dimmed." : dimmer.status }
        }
    }

    private func sleepOnce(reason: String) {
        guard isActive, !sleepConsumed, !inactive else { return }
        sleepConsumed = true
        let ticket = invalidate()
        isBusy = true; phase = .finishing; status = reason
        let cleanup = startCleanup(ticket: ticket, suspend: true)
        Task { [weak self] in
            _ = await cleanup.value
            guard let self, self.current(ticket), self.sleepConsumed else { return }
            // Preserve black through the transition to display sleep. Raising
            // brightness here would flash the desktop before it locks. Release
            // idle protection now; the durable baseline is restored after an
            // independently confirmed awake/unlocked session or fresh rewear.
            do {
                try await self.requestDisplaySleep()
                guard self.current(ticket) else { return }
                self.isActive = false; self.isBusy = false; self.phase = .sleeping
                self.status = "Display sleep was requested. Manual wake remains available."
            } catch {
                guard self.current(ticket) else { return }
                let failure = error.localizedDescription
                _ = await self.startCleanup(ticket: ticket, suspend: false).value
                guard self.current(ticket) else { return }
                self.isActive = false; self.isBusy = false; self.phase = .failed
                self.status = "Display sleep could not be requested: \(failure)"
            }
        }
    }

    private func finishWithoutSleep(reason: String) {
        let ticket = invalidate()
        isActive = false; isBusy = true; phase = .finishing; status = reason
        let cleanup = startCleanup(ticket: ticket, suspend: false)
        Task { [weak self] in
            let restored = await cleanup.value
            guard let self, self.generation == ticket else { return }
            self.finishCleanup(restored: restored, suspended: false)
            if restored { self.status = reason }
        }
    }

    private func invalidate() -> UInt64 {
        generation &+= 1; dimRevision &+= 1
        startTask?.cancel(); startTask = nil
        dimTask?.cancel(); dimTask = nil
        presenceStarted = false
        return generation
    }

    private func current(_ ticket: UInt64) -> Bool {
        generation == ticket && isActive && !inactive
    }

    /// Concurrent callers join the same physical stop. A second stop returning
    /// early must not falsely prove that a previous capture has released it.
    private func stopCamera() async {
        if let barrier = stopBarrier { await barrier.task.value; return }
        stopRevision &+= 1
        let id = stopRevision, presence = presence
        let task = Task { @MainActor in await presence.stop() }
        stopBarrier = (id, task)
        await task.value
        if stopBarrier?.id == id { stopBarrier = nil }
    }

    private func startCleanup(ticket: UInt64, suspend: Bool,
                              recoveringAfterActivation: Bool = false) -> Task<Bool, Never> {
        let task = Task { [weak self] () -> Bool in
            guard let self, generation == ticket else { return false }
            async let stopped: Void = stopCamera()
            async let restored: Bool = restoreBrightness(ticket: ticket, suspend: suspend,
                recoveringAfterActivation: recoveringAfterActivation)
            let result = await restored
            await stopped
            guard generation == ticket else { return false }
            cameraFullyStopped = true
            restorationConfirmed = !suspend && result && !dimmer.hasPendingRestore && !dimmer.isBusy
            return restorationConfirmed
        }
        cleanupTask = task
        return task
    }

    private func restoreBrightness(ticket: UInt64, suspend: Bool,
                                   recoveringAfterActivation: Bool) async -> Bool {
        guard generation == ticket else { return false }
        if suspend { return await dimmer.suspendUntilActive() }
        if recoveringAfterActivation { return await dimmer.recoverIfNeeded() }
        return await dimmer.restore()
    }

    private func finishCleanup(restored: Bool, suspended: Bool) {
        isBusy = false
        if suspended { phase = .suspended; status = "Presence is paused. Brightness recovery waits for an active session." }
        else if restored { phase = .idle; status = "Presence camera is off and owned brightness is restored." }
        else { phase = .failed; status = "Presence camera is off. Brightness restoration still needs attention: \(dimmer.status)" }
    }

    private func normalizedTarget(_ value: Double) -> Double {
        value.isFinite ? min(0.5, max(0, value)) : 0
    }
}
