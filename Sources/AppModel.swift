import AppKit
import SwiftUI
import Combine
import QuartzCore
import ScreenCaptureKit

@MainActor
final class AppModel: NSObject, ObservableObject {
    let motion = MotionService()
    let overlay = DesktopOverlayController()
    @Published var pauseShortcutAvailable = false
    @Published var enabled = false
    @Published var starting = false
    @Published var calibrating = false
    private var calibrationTicket = 0
    @Published var message = "AirPods are detected automatically. Face the display and set center."
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

    var pauseHint: String { pauseShortcutAvailable ? "Pause anytime  ⌃⌥⌘P" : "Pause from the AirVeil menu" }
    var effectiveYaw: Double { (inverted ? -1 : 1) * motion.yawDegrees }
    var shielded: Bool { enabled && (!motion.trackingValid || !overlay.isRunning || overlay.failureReason != nil) }
    var headline: String {
        if starting { return "Starting desktop effect…" }
        if shielded { return "Tracking interrupted — screen covered" }
        if enabled && !overlay.isReady { return "Preparing live desktop frames…" }
        if enabled { return "Following your head" }
        return "Desktop effect paused"
    }
    var direction: String {
        if shielded { return "Screen covered · tracking or capture needs attention" }
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
                Task { @MainActor in self?.suspend() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.startMotionAutomatically() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.message = "Display configuration changed. Pause, set center, and enable again to rebuild the effect."
                self?.motion.stop()
                self?.motion.start()
                self?.installClock()
            }
        })
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
                           opaque: opaque || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,shield: shielded,wholeScreen: wholeScreen)
        }
    }
    func startMotionAutomatically() {
        guard !motion.isRunning else { return }
        motion.start()
        message = "AirPods are detected automatically. Face the display, then choose Set center."
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
                    if motion.isCalibrated { simulate = false; message = "Center set. Turn left and right to confirm the preview follows the opposite side." }
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
            defer { if ticket == accessTicket { checkingAccess = false } }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard ticket == accessTicket else { return }
                guard !content.displays.isEmpty else { throw VeilRenderError.unavailable("No displays are available for capture.") }
                verifiedScreenAccess = true; permissionGranted = true; captureErrorDetails = ""
                message = "Screen access check passed. Set center and enable the effect to start live capture."
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
    func enable() {
        guard !enabled && !starting else { return }
        guard motion.isFresh && motion.isCalibrated else { message = "Wear your AirPods and set your center before enabling the desktop effect."; return }
        refreshPermission()
        accessTicket += 1; checkingAccess = false
        starting = true; generation += 1
        let ticket = generation
        Task {
            do {
                try await overlay.start()
                guard generation == ticket else { return }
                starting = false; enabled = true; simulate = false
                verifiedScreenAccess = true; permissionGranted = true; captureErrorDetails = ""
                message = "Head tracking is active. " + pauseHint
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
    func pause() {
        accessTicket += 1; checkingAccess = false
        calibrationTicket += 1; calibrating = false
        generation += 1; enabled = false; starting = false; overlay.stop()
        strengths = VeilStrength(left: 0,right: 0)
        message = "Desktop effect paused. Your screen is clear."
        stateChanged?()
    }
    private func suspend() {
        pause(); motion.stop()
        message = "Paused for sleep or session change. AirPods detection resumes automatically; set center to resume the effect."
    }
    func shutdown() { pause(); motion.stop(); clock?.invalidate() }
}
