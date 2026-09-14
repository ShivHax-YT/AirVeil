import AppKit
import SwiftUI
import Combine
import QuartzCore
import ScreenCaptureKit
import CoreMedia

@MainActor
final class AppModel: NSObject, ObservableObject {
    let motion = MotionService()
    lazy var cameraHeading = CameraHeadingCoordinator(motion: motion)
    let presentation = TrackingPresentation()
    var previewFrame: ((VeilStrength) -> Void)?
    var previewVisibility: ((Bool) -> Void)?
    private var previewVisible = true
    private var forceFrame = false
    let overlay = DesktopOverlayController()
    let displaySleep = DisplaySleepService()
    let presence = PresenceService()
    let dimming = DisplayDimmingService()
    lazy var removalPresence = RemovalPresenceCoordinator(presence: presence, dimmer: dimming,
        prepareCamera: { [weak self] in
            guard let self else { return }
            self.cameraHeading.setSessionActive(false)
            await self.cameraHeading.camera.waitUntilStopped()
        }, requestDisplaySleep: { [weak self] in
            guard let self, self.isMacSessionActive, !self.isShuttingDown,
                  self.sleepDisplaysOnRemoval, self.removalActionPending,
                  self.pendingDisconnectCount == self.motion.removalEventCount,
                  self.motion.removalConnectionState == .disconnected else { return }
            self.displaySleepRequestCount += 1
            try await self.displaySleep.requestDisplaySleep()
        })
    private var seatReference: PresenceSeatReference?
    private var seatLayout: String?
    private var lastDisplayLayout: String?
    private var restoringRemoval = false
    private var nextRemovalRecoveryAt = -Double.infinity
    private var resumePresenceEvent: UInt64?
    private var screenLocked = false
    var sessionLockState: () -> Bool = { false }
    @Published var dimWhilePresent = true { didSet { cancelRemovalAction(); persist() } }
    @Published var removalBrightness = 0.0 {
        didSet { if !loading { removalPresence.updateTarget(removalBrightness); persist() } }
    }
    var presenceReady: Bool { seatReference != nil && seatLayout == cameraLayoutKey }
    private var usesRemovalPresence: Bool { dimWhilePresent && cameraHeading.isEnabled }

    @Published private(set) var referenceRecoveryStatus = "Face the display and use Set center. Camera assistance can restore screen direction after removal."
    private var systemAwake = true
    private var screensAwake = true
    private var sessionActive = true
    private var isShuttingDown = false
    private var isMacSessionActive: Bool { systemAwake && screensAwake && sessionActive && !screenLocked }
    @Published var sleepDisplaysOnRemoval = false {
        didSet {
            motion.monitorsIndividualAirPods = sleepDisplaysOnRemoval
            cancelRemovalAction()
            persist()
        }
    }
    @Published private(set) var removalStatus = "Automatic display off is off."
    private(set) var displaySleepRequestCount = 0
    private var removalGuard = AirPodsRemovalGuard()
    private var removalTimer: Timer?
    private var removalTicket = 0
    private var removalActionPending = false
    private var pendingDisconnectCount: UInt64?
    @Published var pauseShortcutAvailable = false
    @Published var enabled = false
    @Published var starting = false
    @Published var calibrating = false
    private var calibrationTicket = 0
    private var resumeWhenReferenceReturns = false
    @Published private(set) var selectedDisplayKeys: Set<String>?
    @Published var blockInput = true { didSet { persist() } }
    @Published var blocksEntireDisplay = false { didSet { persist() } }
    @Published var message = "AirPods are detected automatically. Face the display and use Set center once."
    @Published var previewYaw = 0.0 { didSet { wakeAnimation(force: true) } }
    @Published var simulate = true { didSet { wakeAnimation(force: true) } }
    private(set) var strengths = VeilStrength(left: 0, right: 0)
    // Legacy shared value remains readable for existing saved preferences and
    // reset behavior. Independent controls take over once edited.
    @Published var onset = 8.0 {
        didSet {
            if !loading { leftOnset = onset; rightOnset = onset }
            persist()
        }
    }
    @Published var leftOnset = 8.0 { didSet { reconcileFullAngle(); persist() } }
    @Published var rightOnset = 8.0 { didSet { reconcileFullAngle(); persist() } }
    @Published var fullAngle = 32.0 { didSet { persist() } }
    var minimumFullAngle: Double { max(26, max(leftOnset, rightOnset) + 1) }
    func onsetForTurn(_ yaw: Double) -> Double { yaw >= 0 ? leftOnset : rightOnset }
    private func reconcileFullAngle() {
        guard !loading else { return }
        if fullAngle <= max(leftOnset, rightOnset) { fullAngle = min(70, max(leftOnset, rightOnset) + 8) }
    }
    @Published var blurPoints = 32.0 { didSet { persist() } }
    @Published var feather = 0.12 { didSet { persist() } }
    @Published var response = 0.07 { didSet { persist() } }
    @Published var inverted = false { didSet { persist() } }
    @Published var wholeScreen = false { didSet { persist() } }
    @Published var opaque = false { didSet { persist() } }
    @Published var permissionGranted = false
    @Published private(set) var checkingAccess = false
    private(set) var captureErrorDetails = ""
    private var verifiedScreenAccess = false
    private var accessTicket = 0
    private var clock: CADisplayLink?
    private var lastTime = 0.0
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    private var subscriptions = Set<AnyCancellable>()
    private var loading = true
    var showWindow: (() -> Void)?
    var stateChanged: (() -> Void)?

    var selectedDisplayIDs: Set<UInt32>? {
        guard let selectedDisplayKeys else { return nil }
        return Set(overlay.availableDisplays.filter { selectedDisplayKeys.contains($0.stableID) }.map(\.id))
    }
    var selectedDisplayCount: Int { selectedDisplayIDs?.count ?? overlay.availableDisplays.count }
    func isDisplaySelected(_ display: VeilDisplayInfo) -> Bool { selectedDisplayKeys?.contains(display.stableID) ?? true }
    func selectDisplay(_ display: VeilDisplayInfo, selected: Bool) {
        pause()
        var keys = selectedDisplayKeys ?? Set(overlay.availableDisplays.map(\.stableID))
        if selected { keys.insert(display.stableID) } else { keys.remove(display.stableID) }
        selectedDisplayKeys = keys
        persist()
        message = "Display selection updated. Enable the effect when ready."
    }
    var pauseHint: String { pauseShortcutAvailable ? "Pause anytime  ⌃⌥⌘P" : "Pause from the AirVeil menu" }
    var trackingValid: Bool { cameraHeading.isEnabled ? cameraHeading.trackingValid : motion.trackingValid }
    var effectiveYaw: Double { (inverted ? -1 : 1) * (cameraHeading.isEnabled ? cameraHeading.yawDegrees : motion.yawDegrees) }
    var headTrackingStatus: String { cameraHeading.isEnabled ? cameraHeading.status : motion.status }
    var hasSavedCenter: Bool { cameraHeading.isEnabled ? cameraHeading.hasCenter : motion.hasSavedCenter }
    var centerBusy: Bool { calibrating || cameraHeading.isBusy }
    private var cameraLayoutKey: String {
        overlay.availableDisplays.sorted { $0.stableID < $1.stableID }.map {
            "\($0.stableID):\($0.frame.origin.x),\($0.frame.origin.y),\($0.frame.width),\($0.frame.height):\($0.backingScale)"
        }.joined(separator: "|")
    }
    func enableCameraAssistance() { pause(); cameraHeading.requestEnable() }
    func disableCameraAssistance() { pause(); seatReference = nil; seatLayout = nil; cameraHeading.disable() }
    func refreshCameraDirection() { guard removalPresence.canResumeHeading else { return }; cameraHeading.refreshDirection() }
    var shielded: Bool { enabled && (!trackingValid || !overlay.isRunning || overlay.failureReason != nil) }
    var headline: String {
        if starting { return "Starting desktop effect…" }
        if shielded { return "Tracking changed — clearing effect" }
        if enabled && !overlay.isReady { return "Preparing live desktop frames…" }
        if enabled { return "Following your head" }
        return "Desktop effect paused"
    }
    var direction: String {
        if shielded { return "Clearing the screen · tracking or capture changed" }
        if enabled && !overlay.isReady { return "Waiting for live desktop frames" }
        let yaw = simulate && !enabled ? previewYaw : effectiveYaw
        if abs(yaw) <= onsetForTurn(yaw) { return "Centered · screen clear" }
        if wholeScreen { return yaw > 0 ? "Looking left · blur sweeps right to left" : "Looking right · blur sweeps left to right" }
        return yaw > 0 ? "Looking left · right side obscured" : "Looking right · left side obscured"
    }
    override init() {
        super.init()
        let d = UserDefaults.standard
        onset = Self.read(d, "onset", 8, 0...25)
        leftOnset = Self.read(d, "blurOnsetLeft", onset, 0...60)
        rightOnset = Self.read(d, "blurOnsetRight", onset, 0...60)
        fullAngle = max(max(leftOnset, rightOnset) + 1, Self.read(d, "fullAngle", 32, 26...70))
        blurPoints = Self.read(d, "blurPoints", 32, 8...64)
        feather = Self.read(d, "feather", 0.12, 0.02...0.30)
        response = Self.read(d, "response", 0.07, 0.025...0.20)
        inverted = d.bool(forKey: "inverted")
        opaque = d.bool(forKey: "opaque")
        wholeScreen = d.bool(forKey: "wholeScreen")
        blockInput = d.object(forKey: "blockInput") == nil ? true : d.bool(forKey: "blockInput")
        blocksEntireDisplay = d.bool(forKey: "blocksEntireDisplay")
        sleepDisplaysOnRemoval = d.bool(forKey: "sleepDisplaysOnRemoval")
        dimWhilePresent = d.object(forKey: "dimWhilePresent") == nil ? true : d.bool(forKey: "dimWhilePresent")
        removalBrightness = Self.read(d, "removalBrightnessV2", 0, 0...0.5)
        selectedDisplayKeys = d.stringArray(forKey: "selectedDisplays").map { Set($0) }
        lastDisplayLayout = cameraLayoutKey
        motion.monitorsIndividualAirPods = sleepDisplaysOnRemoval
        loading = false
        refreshPermission()
        motion.$fusionSample.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.checkTrackingSafety()
            self?.wakeAnimation()
        }.store(in: &subscriptions)
        cameraHeading.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send(); self?.stateChanged?() }
        }.store(in: &subscriptions)
        cameraHeading.onAcceptedFace = { [weak self] cameraID, configurationID, bounds, capturedAt in
            guard let self else { return }
            self.seatReference = PresenceSeatReference(cameraID: cameraID, configurationID: configurationID,
                faceBounds: bounds, captureHostTime: capturedAt)
            self.seatLayout = self.cameraLayoutKey
            self.objectWillChange.send()
        }
        removalPresence.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send(); self?.stateChanged?() }
        }.store(in: &subscriptions)
        overlay.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.objectWillChange.send(); self.stateChanged?()
            }
        }.store(in: &subscriptions)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleWorkspaceEvent(name) }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleWorkspaceEvent(name) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isShuttingDown else { return }
                self.handleDisplayConfigurationChange()
            }
        })
        installClock()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkAirPodsRemoval()
                self?.checkReferenceRecovery()
                self?.refreshPresentation()
            }
        }
        removalTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func handleDisplayConfigurationChange() {
        guard !isShuttingDown else { return }
        let layout = cameraLayoutKey
        guard lastDisplayLayout != layout else { return }
        lastDisplayLayout = layout
        pause()
        seatReference = nil; seatLayout = nil
        message = "Displays changed. Choose displays and enable again. If you moved your display, use Set center explicitly."
        startMotionAutomatically()
        installClock()
    }
    private static func read(_ d: UserDefaults, _ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
        guard d.object(forKey: key) != nil else { return fallback }
        let x = d.double(forKey: key)
        return x.isFinite ? min(range.upperBound, max(range.lowerBound, x)) : fallback
    }
    private func persist() {
        guard !loading else { return }
        let d = UserDefaults.standard
        for (k,v) in [("onset",onset),("fullAngle",fullAngle),("blurPoints",blurPoints),("feather",feather),("response",response)] { d.set(v,forKey:k) }
        d.set(leftOnset, forKey: "blurOnsetLeft"); d.set(rightOnset, forKey: "blurOnsetRight")
        d.set(blockInput,forKey:"blockInput"); d.set(blocksEntireDisplay,forKey:"blocksEntireDisplay")
        d.set(sleepDisplaysOnRemoval,forKey:"sleepDisplaysOnRemoval")
        d.set(dimWhilePresent,forKey:"dimWhilePresent")
        d.set(removalBrightness,forKey:"removalBrightnessV2")
        if let selectedDisplayKeys { d.set(Array(selectedDisplayKeys).sorted(),forKey:"selectedDisplays") }
        else { d.removeObject(forKey:"selectedDisplays") }
        d.set(inverted,forKey:"inverted"); d.set(opaque,forKey:"opaque"); d.set(wholeScreen,forKey:"wholeScreen")
        wakeAnimation(force: true)
    }
    private func installClock() {
        clock?.invalidate()
        clock = NSScreen.main?.displayLink(target: self, selector: #selector(frame(_:)))
        clock?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        clock?.add(to: .main, forMode: .common)
        clock?.isPaused = true
        lastTime = 0
        wakeAnimation(force: true)
    }
    func setPreviewVisible(_ visible: Bool) {
        previewVisible = visible
        previewVisibility?(visible)
        if visible && isMacSessionActive { refreshPresentation(); wakeAnimation(force: true) }
        else if !enabled { clock?.isPaused = true; lastTime = 0 }
    }
    private func refreshPresentation() {
        guard previewVisible, isMacSessionActive else { return }
        let yaw = simulate && !enabled ? previewYaw : effectiveYaw
        presentation.update(TrackingSnapshot(headline: headline, direction: direction,
            angle: Int((yaw.isFinite ? yaw : 0).rounded()), status: headTrackingStatus,
            source: motion.isFresh ? motion.sourceName : "",
            sampleRate: motion.isFresh ? Int((motion.sampleRate / 5).rounded()) * 5 : 0,
            canSetCenter: motion.isFresh && !centerBusy, trackingValid: trackingValid, hasSavedCenter: hasSavedCenter,
            centerBusy: centerBusy, canEnable: canRequestEnable))
    }
    private func animationTarget() -> VeilStrength {
        let yaw = enabled || !simulate ? (trackingValid ? effectiveYaw : 0) : previewYaw
        return VeilMath.target(yawDegrees: yaw, leftOnset: leftOnset, rightOnset: rightOnset, full: fullAngle, wholeScreen: wholeScreen)
    }
    private func wakeAnimation(force: Bool = false) {
        guard !loading, !isShuttingDown, isMacSessionActive, enabled || previewVisible else { return }
        let target = animationTarget()
        if force || abs(target.left-strengths.left) > 0.0001 || abs(target.right-strengths.right) > 0.0001 {
            forceFrame = forceFrame || force
            clock?.isPaused = false
        }
    }
    @objc private func frame(_ link: CADisplayLink) {
        checkTrackingSafety()
        guard isMacSessionActive, enabled || previewVisible else { clock?.isPaused = true; lastTime = 0; return }
        let now = CACurrentMediaTime()
        let dt = lastTime == 0 ? 1.0/60 : min(0.1,max(0,now-lastTime))
        lastTime = now
        let target = animationTarget()
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let next = VeilMath.advance(current: strengths,target: target,dt: dt,response: reduced ? 0.025 : response)
        let settled = abs(next.left-target.left) < 0.0001 && abs(next.right-target.right) < 0.0001
        let changed = abs(next.left-strengths.left) > 0.00001 || abs(next.right-strengths.right) > 0.00001
        if changed || settled { strengths = settled ? target : next }
        if previewVisible && (changed || settled || forceFrame) { previewFrame?(strengths) }
        if enabled && (changed || settled || forceFrame) {
            overlay.update(left: strengths.left,right: strengths.right,blurPoints: blurPoints,feather: feather,
                           opaque: opaque || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,shield: shielded,wholeScreen: wholeScreen,blockInput: blockInput,blocksEntireDisplay: blocksEntireDisplay)
        }
        forceFrame = false
        if settled { clock?.isPaused = true; lastTime = 0 }
    }
    // Signal loss must not leave an unusable black screen or input blockers.
    // Retained reference recovery may resume capture; no path silently sets a new zero.
    func checkTrackingSafety() {
        guard enabled || starting else { return }
        if !trackingValid {
            pause(cancelRemoval: false)
            resumeWhenReferenceReturns = true
            message = "Tracking changed, so the screen was cleared. Follow the head-tracking guidance to resume."
        } else if overlay.failureReason != nil {
            let reason = overlay.failureReason ?? "Capture stopped."
            pause(cancelRemoval: false)
            message = "Effect paused and screen cleared. " + reason
        }
    }
    /// Separate from tracking safety: a reference jump clears the blur but
    /// cannot turn off displays. Only a debounced disconnect or confirmed per-bud removal can.
    func checkAirPodsRemoval(now: TimeInterval = CMClockGetHostTimeClock().time.seconds) {
        guard !isShuttingDown, isMacSessionActive else {
            if removalActionPending { cancelRemovalAction() }
            removalGuard.reset(disconnectCount: motion.removalEventCount)
            return
        }
        if removalActionPending && (!sleepDisplaysOnRemoval || !motion.isRunning ||
            pendingDisconnectCount != motion.removalEventCount) {
            // A genuinely observed fresh rewear may be followed by another
            // removal while the previous camera/brightness cleanup is pending.
            let nextEpisode = removalGuard
            let preserveRewear = sleepDisplaysOnRemoval && motion.isRunning &&
                pendingDisconnectCount != motion.removalEventCount && nextEpisode.armed
            cancelRemovalAction()
            if preserveRewear { removalGuard = nextEpisode }
        }
        if removalActionPending {
            if motion.removalConnectionState == .connected {
                _ = removalGuard.update(enabled: sleepDisplaysOnRemoval, running: motion.isRunning,
                    connected: true, disconnected: false, freshMotion: motion.isFresh,
                    disconnectCount: motion.removalEventCount, now: now)
                finishRemovalForRewear(now: now)
            } else if removalPresence.isActive {
                removalPresence.update(now: now)
                setRemovalStatus(removalPresence.status)
            }
            return
        }
        guard removalPresence.canResumeHeading, !restoringRemoval else {
            setRemovalStatus(removalPresence.status)
            if !restoringRemoval, removalPresence.phase == .failed,
               !removalPresence.isBusy, !dimming.isBusy, now >= nextRemovalRecoveryAt {
                nextRemovalRecoveryAt = now + 2
                recoverRemovalAfterActivation()
            }
            return
        }
        let shouldSleep = removalGuard.update(enabled: sleepDisplaysOnRemoval,
            running: motion.isRunning, connected: motion.removalConnectionState == .connected,
            disconnected: motion.removalConnectionState == .disconnected, freshMotion: motion.isFresh,
            disconnectCount: motion.removalEventCount, now: now)
        if shouldSleep {
            let restoreEffect = enabled || starting || resumeWhenReferenceReturns
            pause(cancelRemoval: false)
            resumeWhenReferenceReturns = restoreEffect
            removalActionPending = true
            removalTicket += 1
            let ticket = removalTicket
            let event = motion.removalEventCount
            pendingDisconnectCount = event
            if usesRemovalPresence {
                removalPresence.begin(reference: presenceReady ? seatReference : nil,
                    targetBrightness: removalBrightness, now: now)
                setRemovalStatus(removalPresence.status)
                return
            }
            setRemovalStatus("AirPods removed or disconnected. Turning off displays…")
            Task {
                guard removalTicket == ticket, sleepDisplaysOnRemoval, motion.isRunning,
                      motion.removalConnectionState == .disconnected, motion.removalEventCount == event else {
                    if removalTicket == ticket { removalActionPending = false }
                    return
                }
                do {
                    displaySleepRequestCount += 1
                    try await displaySleep.requestDisplaySleep()
                    guard removalTicket == ticket else { return }
                    setRemovalStatus("Display off requested. Wake your Mac normally when you return.")
                } catch {
                    guard removalTicket == ticket else { return }
                    setRemovalStatus("Could not turn off displays: \(error.localizedDescription)")
                }
                removalActionPending = false
            }
        } else if !sleepDisplaysOnRemoval {
            setRemovalStatus("Automatic display off is off.")
        } else if removalGuard.deadline != nil {
            setRemovalStatus("AirPods disconnected. Waiting briefly for a reconnect…")
        } else if removalGuard.armed {
            setRemovalStatus(usesRemovalPresence
                ? (presenceReady ? "Ready. Stay seated to dim; leave the seat to turn off displays." : "Use Set center once to remember your seat. Until then, removal turns off displays.")
                : "Ready. Displays turn off after AirPods removal or disconnection.")
        } else if motion.removalConnectionState != .disconnected {
            setRemovalStatus("Wear your AirPods to arm automatic display off.")
        }
    }
    private func finishRemovalForRewear(now: Double) {
        guard !restoringRemoval, now >= nextRemovalRecoveryAt else { return }
        nextRemovalRecoveryAt = now + 2
        restoringRemoval = true
        removalTicket += 1
        let ticket = removalTicket
        displaySleep.cancel()
        Task {
            let restored = await removalPresence.finishForRewear()
            guard ticket == removalTicket, !isShuttingDown else { return }
            restoringRemoval = false
            guard restored else { setRemovalStatus(removalPresence.status); return }
            removalActionPending = false; pendingDisconnectCount = nil; resumePresenceEvent = nil
            cameraHeading.setSessionActive(isMacSessionActive)
            setRemovalStatus("AirPods are back. Your previous brightness is restored.")
        }
    }
    private func cancelRemovalAction() {
        removalTicket += 1
        restoringRemoval = false
        nextRemovalRecoveryAt = -Double.infinity
        resumePresenceEvent = nil
        if !loading, !removalPresence.canResumeHeading || !isMacSessionActive {
            removalPresence.cancel(inactive: !isMacSessionActive)
        }
        removalActionPending = false
        pendingDisconnectCount = nil
        removalGuard.reset(disconnectCount: motion.removalEventCount)
        displaySleep.cancel()
        setRemovalStatus(sleepDisplaysOnRemoval ? "Wear your AirPods to arm automatic display off." : "Automatic display off is off.")
    }
    private func setRemovalStatus(_ value: String) {
        if removalStatus != value { removalStatus = value }
    }
    func openLockScreenSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
    func startMotionAutomatically() {
        guard !isShuttingDown, isMacSessionActive, !motion.isRunning else { return }
        motion.start()
        message = "AirPods are detected automatically. Face the display and use Set center once."
    }

    /// Camera recovery measures against the saved screen anchor. Manual mode
    /// requires explicit calibration after a gap; stillness never establishes zero.
    func checkReferenceRecovery() {
        guard !isShuttingDown else { return }
        guard removalPresence.canResumeHeading, !restoringRemoval else {
            cameraHeading.setSessionActive(false)
            checkTrackingSafety()
            return
        }
        cameraHeading.setSessionActive(isMacSessionActive)
        cameraHeading.update(layoutKey: cameraLayoutKey)
        checkTrackingSafety()
        if cameraHeading.isEnabled {
            setReferenceRecoveryStatus(cameraHeading.status)
            if isMacSessionActive, trackingValid, resumeWhenReferenceReturns,
               !removalActionPending, !enabled, !starting, !centerBusy {
                resumeWhenReferenceReturns = false; enable()
            }
            return
        }
        guard isMacSessionActive else {
            setReferenceRecoveryStatus("Tracking is paused while the Mac is asleep or inactive.")
            return
        }
        guard motion.hasSavedCenter else {
            setReferenceRecoveryStatus("Face the display and use Set center once. No original center is saved yet.")
            return
        }
        guard motion.referenceState != .invalid else {
            setReferenceRecoveryStatus("The sensor reference changed. Face the display and use Set center explicitly.")
            return
        }
        guard trackingValid else {
            setReferenceRecoveryStatus("Waiting for fresh AirPods motion. Camera assistance can restore direction after removal.")
            return
        }
        setReferenceRecoveryStatus("Using your chosen center for this uninterrupted session. Enable camera assistance to restore direction after removal.")
        guard resumeWhenReferenceReturns, !removalActionPending, !enabled, !starting, !calibrating else { return }
        resumeWhenReferenceReturns = false
        enable()
    }
    private func setReferenceRecoveryStatus(_ value: String) {
        if referenceRecoveryStatus != value { referenceRecoveryStatus = value }
    }

    /// Separate sleep, display, and login-session state prevents a display wake
    /// from restarting capture while the Mac's user session remains inactive.
    func handleWorkspaceEvent(_ name: Notification.Name) {
        let wasActive = isMacSessionActive
        switch name {
        case NSWorkspace.willSleepNotification: systemAwake = false
        case NSWorkspace.screensDidSleepNotification: screensAwake = false
        case NSWorkspace.sessionDidResignActiveNotification: sessionActive = false
        case NSWorkspace.didWakeNotification: systemAwake = true
        case NSWorkspace.screensDidWakeNotification: screensAwake = true
        case NSWorkspace.sessionDidBecomeActiveNotification: sessionActive = true
        default: return
        }
        screenLocked = sessionLockState()
        if isShuttingDown {
            if !isMacSessionActive { cameraHeading.setSessionActive(false); removalPresence.suspend() }
            return
        }
        if isMacSessionActive {
            if !wasActive { recoverRemovalAfterActivation() }
            else { startMotionAutomatically() }
        } else { cameraHeading.setSessionActive(false); suspend() }
    }
    func handleScreenLock(_ locked: Bool) {
        let wasActive = isMacSessionActive
        screenLocked = locked
        if isShuttingDown {
            if !isMacSessionActive { cameraHeading.setSessionActive(false); removalPresence.suspend() }
            return
        }
        if isMacSessionActive {
            if !wasActive { recoverRemovalAfterActivation() }
        }
        else { cameraHeading.setSessionActive(false); suspend() }
    }
    func prepareAfterLaunch() {
        screenLocked = sessionLockState()
        if isShuttingDown {
            if !isMacSessionActive { cameraHeading.setSessionActive(false); removalPresence.suspend() }
            return
        }
        if isMacSessionActive { recoverRemovalAfterActivation() }
        else { cameraHeading.setSessionActive(false); suspend() }
    }
    private func recoverRemovalAfterActivation() {
        guard !restoringRemoval else { return }
        restoringRemoval = true
        removalTicket += 1
        let ticket = removalTicket
        cameraHeading.setSessionActive(false)
        Task {
            let restored = await removalPresence.recoverAfterActivation()
            guard ticket == removalTicket, !isShuttingDown, isMacSessionActive else { return }
            restoringRemoval = false
            guard restored else { setRemovalStatus(removalPresence.status); return }
            startMotionAutomatically()
            if let event = resumePresenceEvent, event == motion.removalEventCount,
               motion.removalConnectionState == .disconnected, sleepDisplaysOnRemoval, usesRemovalPresence {
                removalActionPending = true; pendingDisconnectCount = event
                removalPresence.begin(reference: presenceReady ? seatReference : nil,
                    targetBrightness: removalBrightness, now: CMClockGetHostTimeClock().time.seconds,
                    allowSleepBeforePresence: false)
            } else {
                resumePresenceEvent = nil
                cameraHeading.setSessionActive(true)
            }
            refreshPresentation(); wakeAnimation(force: true)
        }
    }
    func calibrate() {
        guard !isShuttingDown, isMacSessionActive, removalPresence.canResumeHeading, !restoringRemoval, motion.isFresh else { message = "Wait for an active Mac session and fresh AirPods motion before setting center."; return }
        if cameraHeading.isEnabled {
            cameraHeading.setCenter(layoutKey: cameraLayoutKey)
            simulate = false
            message = "Face straight ahead within 5° and hold briefly. One check sets your center and aligns the AirPods."
            return
        }
        calibrationTicket += 1
        let ticket = calibrationTicket
        calibrating = true
        message = "Face the display and hold still for a moment…"
        Task {
            for _ in 0..<50 {
                guard ticket == calibrationTicket else { return }
                guard motion.isFresh else { calibrating = false; message = "Waiting for AirPods to resume. Set center when motion returns."; return }
                if motion.canCalibrate {
                    motion.calibrate()
                    calibrating = false
                    if motion.isCalibrated {
                        simulate = false
                        message = "Center set. Turn left and right to confirm the preview follows the opposite side."
                        if resumeWhenReferenceReturns { resumeWhenReferenceReturns = false; enable() }
                    }
                    else { message = motion.status }
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard ticket == calibrationTicket else { return }
            calibrating = false
            message = "Could not find a steady pose. Face the display, hold still, and try Set center again."
        }
    }
    func resetDefaults() {
        cameraHeading.disable()
        onset = 8; fullAngle = 32; blurPoints = 32; feather = 0.12; response = 0.07
        inverted = false; opaque = false; wholeScreen = false
        blockInput = true; blocksEntireDisplay = false
        sleepDisplaysOnRemoval = false; dimWhilePresent = true; removalBrightness = 0
        seatReference = nil; seatLayout = nil
        pause()
        selectedDisplayKeys = nil; persist()
        message = "Default settings restored."
    }
    // Preflight is advisory. ScreenCaptureKit remains the authority and still
    // enforces macOS consent when an explicit access check or Enable is requested.
    func refreshPermission() {
        permissionGranted = overlay.isReady || verifiedScreenAccess || CGPreflightScreenCaptureAccess()
    }
    func requestScreenPermission() {
        guard !checkingAccess else { return }
        accessTicket += 1
        let ticket = accessTicket
        checkingAccess = true
        message = "Checking screen access with macOS…"
        Task {
            guard ticket == accessTicket && checkingAccess else { return }
            defer { if ticket == accessTicket { checkingAccess = false } }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard ticket == accessTicket else { return }
                guard !content.displays.isEmpty else { throw VeilRenderError.unavailable("No displays are available for capture.") }
                verifiedScreenAccess = true; permissionGranted = true; captureErrorDetails = ""
                message = "Screen access check passed. Set center once, then enable the effect to start live capture."
            } catch {
                guard ticket == accessTicket else { return }
                let detail = error as NSError
                let denied = detail.domain == SCStreamErrorDomain && detail.code == SCStreamError.Code.userDeclined.rawValue
                if denied { verifiedScreenAccess = false; permissionGranted = false }
                captureErrorDetails = "\(detail.domain) (\(detail.code)): \(detail.localizedDescription)"
                message = "Screen access could not be verified: \(detail.localizedDescription)"
                if denied {
                    message += " Allow AirVeil in Screen & System Audio Recording, then reopen if requested."
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }
    var canRequestEnable: Bool {
        selectedDisplayCount > 0 && isMacSessionActive && removalPresence.canResumeHeading && !restoringRemoval &&
        (trackingValid || (cameraHeading.isEnabled && cameraHeading.hasCenter && motion.isFresh && !centerBusy))
    }
    func enable() {
        guard !isShuttingDown, isMacSessionActive, removalPresence.canResumeHeading, !restoringRemoval, !enabled && !starting else { return }
        guard selectedDisplayCount > 0 else { message = "Select at least one display to blur."; return }
        guard trackingValid else {
            if cameraHeading.isEnabled, cameraHeading.hasCenter, motion.isFresh {
                resumeWhenReferenceReturns = true
                cameraHeading.resumeTracking()
                message = "Checking your saved screen direction. The effect will resume after this check."
            } else { message = "Wear your AirPods and set a valid center before enabling the desktop effect." }
            return
        }
        refreshPermission()
        accessTicket += 1; checkingAccess = false
        starting = true; generation += 1
        let ticket = generation
        Task {
            guard generation == ticket && starting && isMacSessionActive else { return }
            guard trackingValid else {
                pause(cancelRemoval:false)
                resumeWhenReferenceReturns = true
                message = "Waiting for fresh motion with your saved center before capture can resume."
                return
            }
            do {
                try await overlay.start(selectedDisplayIDs: selectedDisplayIDs)
                guard generation == ticket else { return }
                guard isMacSessionActive && trackingValid else {
                    pause(cancelRemoval: false)
                    resumeWhenReferenceReturns = true
                    message = "Tracking changed while starting. Follow the head-tracking guidance to resume."
                    return
                }
                starting = false; enabled = true; simulate = false
                verifiedScreenAccess = true; permissionGranted = true; captureErrorDetails = ""
                message = "Head tracking is active. " + pauseHint
                wakeAnimation(force: true)
                stateChanged?()
            } catch {
                guard generation == ticket else { return }
                starting = false; enabled = false; overlay.stop()
                let detail = error as NSError
                captureErrorDetails = "\(detail.domain) (\(detail.code)): \(detail.localizedDescription)"
                if detail.domain == SCStreamErrorDomain && detail.code == SCStreamError.Code.userDeclined.rawValue {
                    verifiedScreenAccess = false; permissionGranted = false
                }
                message = "Could not start desktop capture: \(error.localizedDescription)"
                stateChanged?()
            }
        }
    }
    func pause(cancelRemoval: Bool = true) {
        if cancelRemoval {
            motion.clearRemovalEvidence()
            cancelRemovalAction(); cameraHeading.cancelPendingRecovery()
        }
        resumeWhenReferenceReturns = false
        accessTicket += 1; checkingAccess = false
        calibrationTicket += 1; calibrating = false
        generation += 1; enabled = false; starting = false; overlay.stop()
        strengths = VeilStrength(left: 0,right: 0)
        if previewVisible { previewFrame?(strengths) }
        wakeAnimation(force: true)
        message = "Desktop effect paused. Your screen is clear."
        stateChanged?()
    }
    private func suspend() {
        let restoreEffect = enabled || starting || resumeWhenReferenceReturns
        let resumeEvent = removalActionPending && usesRemovalPresence && motion.removalConnectionState == .disconnected
            ? pendingDisconnectCount : resumePresenceEvent
        pause(cancelRemoval: false)
        cancelRemovalAction()
        resumePresenceEvent = resumeEvent
        clock?.isPaused = true; lastTime = 0
        resumeWhenReferenceReturns = restoreEffect
        message = "Capture paused for sleep or session change. Your saved screen direction will be checked on return."
    }
    func prepareForTermination() async {
        isShuttingDown = true
        removalTicket += 1
        displaySleep.cancel()
        cameraHeading.shutdown()
        if isMacSessionActive { _ = await removalPresence.finishForRewear() }
        else { removalPresence.suspend() }
    }
    func shutdown() {
        isShuttingDown = true
        pause(cancelRemoval: false); cameraHeading.shutdown(); motion.stop()
        clock?.invalidate(); removalTimer?.invalidate()
    }
}
