import AppKit
import SwiftUI
import Combine
import QuartzCore
import ScreenCaptureKit

@MainActor
final class AppModel: NSObject, ObservableObject {
    let motion = MotionService()
    let overlay = DesktopOverlayController()
    let displaySleep = DisplaySleepService()
    @Published var autoCenter = true {
        didSet {
            autoCenterSteadySince = nil
            if !autoCenter {
                resumeAfterRecenter = false
                if automaticResumeStarting { pause(cancelRemoval: false) }
            }
            setAutoCenterStatus(autoCenter ? "Face the display briefly after putting on your AirPods." : "Automatic center is off. Use Set center.")
            persist()
        }
    }
    @Published private(set) var autoCenterStatus = "Face the display briefly after putting on your AirPods."
    private(set) var automaticCenterCount = 0
    private var autoCenterEligible = true
    private var autoCenterSteadySince: TimeInterval?
    private var autoCenterLastCheck: TimeInterval?
    private var observedDisconnectCount: UInt64 = 0
    private var observedConnection = MotionConnectionState.unknown
    private var automaticResumeStarting = false
    private var systemAwake = true
    private var screensAwake = true
    private var sessionActive = true
    private var isShuttingDown = false
    private var isMacSessionActive: Bool { systemAwake && screensAwake && sessionActive }
    @Published var sleepDisplaysOnRemoval = false {
        didSet {
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
    private var resumeAfterRecenter = false
    @Published private(set) var selectedDisplayKeys: Set<String>?
    @Published var blockInput = true { didSet { persist() } }
    @Published var blocksEntireDisplay = false { didSet { persist() } }
    @Published var message = "AirPods are detected automatically. Face the display and hold still briefly."
    @Published var previewYaw = 0.0
    @Published var simulate = true
    @Published var strengths = VeilStrength(left: 0, right: 0)
    @Published var onset = 8.0 { didSet { persist() } }
    @Published var fullAngle = 32.0 { didSet { persist() } }
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
    var effectiveYaw: Double { (inverted ? -1 : 1) * motion.yawDegrees }
    var shielded: Bool { enabled && (!motion.trackingValid || !overlay.isRunning || overlay.failureReason != nil) }
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
        if abs(yaw) <= onset { return "Centered · screen clear" }
        if wholeScreen { return yaw > 0 ? "Looking left · blur sweeps right to left" : "Looking right · blur sweeps left to right" }
        return yaw > 0 ? "Looking left · right side obscured" : "Looking right · left side obscured"
    }
    override init() {
        super.init()
        let d = UserDefaults.standard
        onset = Self.read(d, "onset", 8, 0...25)
        fullAngle = Self.read(d, "fullAngle", 32, 26...70)
        blurPoints = Self.read(d, "blurPoints", 32, 8...64)
        feather = Self.read(d, "feather", 0.12, 0.02...0.30)
        response = Self.read(d, "response", 0.07, 0.025...0.20)
        inverted = d.bool(forKey: "inverted")
        opaque = d.bool(forKey: "opaque")
        wholeScreen = d.bool(forKey: "wholeScreen")
        blockInput = d.object(forKey: "blockInput") == nil ? true : d.bool(forKey: "blockInput")
        blocksEntireDisplay = d.bool(forKey: "blocksEntireDisplay")
        sleepDisplaysOnRemoval = d.bool(forKey: "sleepDisplaysOnRemoval")
        autoCenter = d.object(forKey: "autoCenter") == nil ? true : d.bool(forKey: "autoCenter")
        selectedDisplayKeys = d.stringArray(forKey: "selectedDisplays").map { Set($0) }
        autoCenterEligible = !motion.isCalibrated
        observedDisconnectCount = motion.disconnectEventCount
        observedConnection = motion.connectionState
        loading = false
        refreshPermission()
        motion.objectWillChange.throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true).sink { [weak self] _ in
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
                self?.pause()
                self?.message = "Displays changed. Choose the displays to blur and enable again once centered."
                self?.motion.stop()
                self?.startMotionAutomatically()
                self?.installClock()
            }
        })
        installClock()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkAutomaticCenter()
                self?.checkAirPodsRemoval()
            }
        }
        removalTimer = timer
        RunLoop.main.add(timer, forMode: .common)
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
        d.set(blockInput,forKey:"blockInput"); d.set(blocksEntireDisplay,forKey:"blocksEntireDisplay")
        d.set(sleepDisplaysOnRemoval,forKey:"sleepDisplaysOnRemoval")
        d.set(autoCenter,forKey:"autoCenter")
        if let selectedDisplayKeys { d.set(Array(selectedDisplayKeys).sorted(),forKey:"selectedDisplays") }
        else { d.removeObject(forKey:"selectedDisplays") }
        d.set(inverted,forKey:"inverted"); d.set(opaque,forKey:"opaque"); d.set(wholeScreen,forKey:"wholeScreen")
    }
    private func installClock() {
        clock?.invalidate()
        clock = NSScreen.main?.displayLink(target: self, selector: #selector(frame(_:)))
        clock?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        clock?.add(to: .main, forMode: .common)
        lastTime = 0
    }
    @objc private func frame(_ link: CADisplayLink) {
        checkTrackingSafety()
        let now = CACurrentMediaTime()
        let dt = lastTime == 0 ? 1.0/60 : min(0.1,max(0,now-lastTime))
        lastTime = now
        let yaw = enabled || !simulate ? (motion.trackingValid ? effectiveYaw : 0) : previewYaw
        let target = VeilMath.target(yawDegrees: yaw, onset: onset, full: fullAngle, wholeScreen: wholeScreen)
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let next = VeilMath.advance(current: strengths,target: target,dt: dt,response: reduced ? 0.025 : response)
        if abs(next.left-strengths.left) > 0.00001 || abs(next.right-strengths.right) > 0.00001 { strengths = next }
        if enabled {
            overlay.update(left: strengths.left,right: strengths.right,blurPoints: blurPoints,feather: feather,
                           opaque: opaque || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,shield: shielded,wholeScreen: wholeScreen,blockInput: blockInput,blocksEntireDisplay: blocksEntireDisplay)
        }
    }
    // Signal loss must not leave an unusable black screen or input blockers.
    // Resume is deliberate because reconnecting can replace the sensor frame.
    func checkTrackingSafety() {
        guard enabled else { return }
        if !motion.trackingValid {
            pause(cancelRemoval: false)
            resumeAfterRecenter = true
            message = "Tracking changed, so the screen was cleared. Follow the head-tracking guidance to resume."
        } else if overlay.failureReason != nil {
            let reason = overlay.failureReason ?? "Capture stopped."
            pause(cancelRemoval: false)
            message = "Effect paused and screen cleared. " + reason
        }
    }
    /// Separate from tracking safety: a reference jump clears the blur but
    /// cannot turn off displays. Only a debounced delegate disconnect can.
    func checkAirPodsRemoval(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if removalActionPending && (!sleepDisplaysOnRemoval || !motion.isRunning ||
            motion.connectionState != .disconnected || pendingDisconnectCount != motion.disconnectEventCount) {
            cancelRemovalAction()
        }
        guard !removalActionPending else { return }
        let shouldSleep = removalGuard.update(enabled: sleepDisplaysOnRemoval,
            running: motion.isRunning, connected: motion.connectionState == .connected,
            disconnected: motion.connectionState == .disconnected, freshMotion: motion.isFresh,
            disconnectCount: motion.disconnectEventCount, now: now)
        if shouldSleep {
            let restoreEffect = enabled || starting || resumeAfterRecenter
            pause(cancelRemoval: false)
            resumeAfterRecenter = restoreEffect
            removalActionPending = true
            removalTicket += 1
            let ticket = removalTicket
            let event = motion.disconnectEventCount
            pendingDisconnectCount = event
            setRemovalStatus("AirPods removed or disconnected. Turning off displays…")
            Task {
                guard removalTicket == ticket, sleepDisplaysOnRemoval, motion.isRunning,
                      motion.connectionState == .disconnected, motion.disconnectEventCount == event else {
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
            setRemovalStatus("Ready. Displays turn off after AirPods removal or disconnection.")
        } else if motion.connectionState != .disconnected {
            setRemovalStatus("Wear your AirPods to arm automatic display off.")
        }
    }
    private func cancelRemovalAction() {
        removalTicket += 1
        removalActionPending = false
        pendingDisconnectCount = nil
        removalGuard.reset(disconnectCount: motion.disconnectEventCount)
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
        autoCenterEligible = true
        autoCenterSteadySince = nil
        autoCenterLastCheck = nil
        motion.start()
        message = autoCenter ? "AirPods are detected automatically. Face the display and hold still briefly." : "AirPods are detected automatically. Face the display, then choose Set center."
    }

    /// One automatic reference per wear/start session. Stillness cannot identify
    /// the display; this explicitly assumes the wearer is facing it. A reference
    /// jump in an existing connection must never silently center a held turn.
    func checkAutomaticCenter(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !isShuttingDown else { return }
        let newDisconnect = motion.disconnectEventCount != observedDisconnectCount
        let restarted = motion.connectionState == .unknown && observedConnection != .unknown
        observedDisconnectCount = motion.disconnectEventCount
        observedConnection = motion.connectionState
        if newDisconnect || restarted || !motion.isRunning {
            autoCenterEligible = true
            autoCenterSteadySince = nil
            autoCenterLastCheck = nil
        }
        guard autoCenter else {
            setAutoCenterStatus("Automatic center is off. Use Set center.")
            return
        }
        guard isMacSessionActive, motion.isRunning, !removalActionPending else {
            autoCenterSteadySince = nil
            autoCenterLastCheck = nil
            setAutoCenterStatus("Waiting for an active Mac session and AirPods.")
            return
        }
        if motion.isCalibrated {
            autoCenterEligible = false
            autoCenterSteadySince = nil
            setAutoCenterStatus("Center is set. It stays fixed while you turn your head.")
            return
        }
        guard autoCenterEligible else {
            setAutoCenterStatus("Head reference changed during this connection. Face the display and use Set center.")
            return
        }
        guard now.isFinite, now >= 0, motion.connectionState == .connected,
              motion.isFresh, motion.canCalibrate, !calibrating else {
            autoCenterSteadySince = nil
            autoCenterLastCheck = nil
            setAutoCenterStatus("Face the display and hold still briefly to set center automatically.")
            return
        }
        // A coordinator/UI gap cannot stand in for observed continuous stability.
        if let last = autoCenterLastCheck, now < last || now - last > 0.3 {
            autoCenterSteadySince = nil
        }
        autoCenterLastCheck = now
        guard let steadySince = autoCenterSteadySince else {
            autoCenterSteadySince = now
            setAutoCenterStatus("Hold still facing the display. Setting center automatically…")
            return
        }
        guard now - steadySince >= 0.8 else { return }
        motion.calibrate()
        guard motion.isCalibrated else {
            autoCenterSteadySince = nil
            setAutoCenterStatus(motion.status)
            return
        }
        automaticCenterCount += 1
        autoCenterEligible = false
        autoCenterSteadySince = nil
        simulate = false
        setAutoCenterStatus("Center set automatically, assuming you faced the display. Set center can correct it.")
        message = "Center set automatically. Your existing blur settings are ready."
        if resumeAfterRecenter {
            resumeAfterRecenter = false
            enable(automatically: true)
        }
    }

    private func setAutoCenterStatus(_ value: String) {
        if autoCenterStatus != value { autoCenterStatus = value }
    }

    /// Separate sleep, display, and login-session state prevents a display wake
    /// from restarting capture while the Mac's user session remains inactive.
    func handleWorkspaceEvent(_ name: Notification.Name) {
        guard !isShuttingDown else { return }
        switch name {
        case NSWorkspace.willSleepNotification: systemAwake = false
        case NSWorkspace.screensDidSleepNotification: screensAwake = false
        case NSWorkspace.sessionDidResignActiveNotification: sessionActive = false
        case NSWorkspace.didWakeNotification: systemAwake = true
        case NSWorkspace.screensDidWakeNotification: screensAwake = true
        case NSWorkspace.sessionDidBecomeActiveNotification: sessionActive = true
        default: return
        }
        if isMacSessionActive { startMotionAutomatically() }
        else { suspend() }
    }
    func calibrate() {
        guard motion.isFresh else { message = "Wait for fresh AirPods motion before setting center."; return }
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
                        autoCenterEligible = false
                        autoCenterSteadySince = nil
                        simulate = false
                        message = "Center set. Turn left and right to confirm the preview follows the opposite side."
                        if resumeAfterRecenter { resumeAfterRecenter = false; enable() }
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
        onset = 8; fullAngle = 32; blurPoints = 32; feather = 0.12; response = 0.07
        inverted = false; opaque = false; wholeScreen = false
        blockInput = true; blocksEntireDisplay = false
        sleepDisplaysOnRemoval = false
        autoCenter = true
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
                message = autoCenter ? "Screen access check passed. Face the display briefly, then enable the desktop effect." : "Screen access check passed. Set center and enable the effect to start live capture."
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
    func enable(automatically: Bool = false) {
        guard !enabled && !starting else { return }
        guard selectedDisplayCount > 0 else { message = "Select at least one display to blur."; return }
        guard motion.isFresh && motion.isCalibrated else { message = "Wear your AirPods and set your center before enabling the desktop effect."; return }
        guard !automatically || (autoCenter && isMacSessionActive) else { return }
        autoCenterEligible = false
        refreshPermission()
        accessTicket += 1; checkingAccess = false
        starting = true; generation += 1
        automaticResumeStarting = automatically
        let ticket = generation
        Task {
            guard generation == ticket && starting else { return }
            do {
                try await overlay.start(selectedDisplayIDs: selectedDisplayIDs)
                guard generation == ticket else { return }
                guard motion.trackingValid else {
                    pause(cancelRemoval: false)
                    resumeAfterRecenter = true
                    message = "Tracking changed while starting. Follow the head-tracking guidance to resume."
                    return
                }
                starting = false; enabled = true; simulate = false
                automaticResumeStarting = false
                verifiedScreenAccess = true; permissionGranted = true; captureErrorDetails = ""
                message = "Head tracking is active. " + pauseHint
                stateChanged?()
            } catch {
                guard generation == ticket else { return }
                starting = false; enabled = false; overlay.stop()
                automaticResumeStarting = false
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
        if cancelRemoval { cancelRemovalAction() }
        resumeAfterRecenter = false
        automaticResumeStarting = false
        autoCenterSteadySince = nil
        autoCenterLastCheck = nil
        accessTicket += 1; checkingAccess = false
        calibrationTicket += 1; calibrating = false
        generation += 1; enabled = false; starting = false; overlay.stop()
        strengths = VeilStrength(left: 0,right: 0)
        message = "Desktop effect paused. Your screen is clear."
        stateChanged?()
    }
    private func suspend() {
        let restoreEffect = enabled || starting || resumeAfterRecenter
        pause(); motion.stop()
        resumeAfterRecenter = restoreEffect
        autoCenterEligible = true
        message = "Paused for sleep or session change. Face the display after returning; automatic center can restore the effect."
    }
    func shutdown() { isShuttingDown = true; pause(); motion.stop(); clock?.invalidate(); removalTimer?.invalidate() }
}
