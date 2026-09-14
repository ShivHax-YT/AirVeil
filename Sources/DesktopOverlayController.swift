import AppKit
import Combine
import ScreenCaptureKit
import CoreMedia

struct VeilDisplayInfo: Identifiable, Equatable {
    let id: UInt32
    let stableID: String
    let name: String
    let frame: NSRect
    let backingScale: CGFloat
}

/// Only values that affect capture geometry or its input-blocking surface.
/// Display names and enumeration order can change without changing capture.
struct VeilDisplayCaptureLayout: Equatable {
    let id: UInt32
    let stableID: String
    let frame: NSRect
    let backingScale: CGFloat
    let pixelWidth: Int
    let pixelHeight: Int
    let menuBand: CGFloat
}

/// The capture owner compares notifications against its committed startup
/// layout. A notification alone is not evidence that running streams changed.
struct VeilDisplayConfigurationGuard {
    private var baseline: [VeilDisplayCaptureLayout]?

    mutating func begin(_ layout: [VeilDisplayCaptureLayout]) { baseline = normalized(layout) }
    mutating func stop() { baseline = nil }

    mutating func shouldRebuild(current: [VeilDisplayCaptureLayout]?, isRunning: Bool) -> Bool {
        guard isRunning else { return false }
        let next = current.map(normalized)
        guard next != baseline else { return false }
        // Keep guarding the fault cover layout until stop/re-enable. Duplicate
        // notifications must not recreate those windows either.
        baseline = next
        return true
    }
    private func normalized(_ layout: [VeilDisplayCaptureLayout]) -> [VeilDisplayCaptureLayout] {
        layout.sorted { $0.id < $1.id }
    }
}

private final class VeilPointerBlockerView: NSView {
    var onBlockedPointer: (() -> Void)?
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite:0, alpha:1.0/255.0).setFill()
        dirtyRect.fill()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onBlockedPointer?() }
    override func mouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) { onBlockedPointer?() }
    override func rightMouseUp(with event: NSEvent) {}
    override func rightMouseDragged(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) { onBlockedPointer?() }
    override func otherMouseUp(with event: NSEvent) {}
    override func otherMouseDragged(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) { onBlockedPointer?() }
    override func magnify(with event: NSEvent) {}
    override func rotate(with event: NSEvent) {}
    override func swipe(with event: NSEvent) {}
}

private final class VeilPointerBlockerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        // The content view paints one alpha step so its hit area survives
        // 8-bit surface quantization; never rely on a completely clear panel.
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        isMovable = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary, .canJoinAllApplications]
        contentView = VeilPointerBlockerView(frame: .zero)
    }
}

private final class VeilOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class DisplayCaptureSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let mailbox: VeilFrameMailbox
    var onFailure: (@Sendable (String) -> Void)?
    private let failureLock = NSLock()
    private var reportedFailure = false
    private func fail(_ message: String) {
        failureLock.lock()
        let report = !reportedFailure
        reportedFailure = true
        failureLock.unlock()
        if report { onFailure?(message) }
    }
    init(mailbox: VeilFrameMailbox) { self.mailbox = mailbox }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fail("Screen capture stopped: \(error.localizedDescription)")
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return }
        switch status {
        case .complete:
            guard CMSampleBufferDataIsReady(sampleBuffer), let image = sampleBuffer.imageBuffer else { return }
            mailbox.put(image)
        case .idle, .started: break // No changed desktop pixels; retain the latest valid image.
        case .blank, .suspended, .stopped: fail("The display capture became unavailable (\(status.rawValue)). Pause and enable again.")
        @unknown default: fail("The display capture entered an unsupported state.")
        }
    }
}

@MainActor final class DesktopOverlayController: ObservableObject {
    @Published private(set) var status = "Desktop effect paused"
    @Published private(set) var isRunning = false
    @Published private(set) var isReady = false
    @Published private(set) var failureReason: String?
    @Published private(set) var availableDisplays: [VeilDisplayInfo] = []
    @Published private(set) var blockedPointerEventCount: UInt64 = 0
    var activeDisplayCount: Int { isRunning ? sessions.count : 0 }
    var drawSubmissionCount: UInt64 { sessions.reduce(0) { $0 + $1.view.drawSubmissionCount } }
    var sourceBlitCount: UInt64 { sessions.reduce(0) { $0 + $1.view.sourceBlitCount } }
    var gaussianPassCount: UInt64 { sessions.reduce(0) { $0 + $1.view.gaussianPassCount } }
    var redrawRequestCount: UInt64 { sessions.reduce(0) { $0 + $1.view.redrawRequestCount } }
    @MainActor private final class DisplaySession {
        let window: VeilOverlayWindow
        let view: VeilMetalView
        let mailbox = VeilFrameMailbox()
        let blockers = [VeilPointerBlockerPanel(), VeilPointerBlockerPanel()]
        let menuBand: CGFloat
        var sink: DisplayCaptureSink?
        var stream: SCStream?
        var ready = false
        init(screen: NSScreen) {
            menuBand = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)
            view = VeilMetalView(frame: NSRect(origin: .zero, size: screen.frame.size))
            window = VeilOverlayWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary, .canJoinAllApplications]
            window.contentView = view
            view.autoresizingMask = [.width, .height]
            view.frameMailbox = mailbox
        }
        func observeBlockedPointer(_ callback: @escaping () -> Void) {
            for blocker in blockers { (blocker.contentView as? VeilPointerBlockerView)?.onBlockedPointer = callback }
        }
        func hideBlockers() { for blocker in blockers where blocker.isVisible { blocker.orderOut(nil) } }
        func setBlockers(_ intervals: [VeilInputInterval], active: Bool) {
            let frame = window.frame
            let usableHeight = max(0, frame.height - menuBand)
            for (index, blocker) in blockers.enumerated() {
                guard active, index < intervals.count, usableHeight > 0 else {
                    if blocker.isVisible { blocker.orderOut(nil) }
                    continue
                }
                let interval = intervals[index]
                let rect = NSRect(x:frame.minX+frame.width*interval.lower, y:frame.minY,
                                  width:frame.width*(interval.upper-interval.lower), height:usableHeight)
                if blocker.frame != rect { blocker.setFrame(rect, display:false) }
                if !blocker.isVisible { blocker.order(.above, relativeTo:window.windowNumber) }
            }
        }
        func coverWithoutGPU() {
            view.isPaused = true
            view.releaseCapturedResources()
            view.isHidden = true
            window.backgroundColor = NSColor(calibratedRed: 0.075, green: 0.085, blue: 0.105, alpha: 1)
            window.orderFrontRegardless()
        }
    }
    private static func identities(for screens: [NSScreen]) throws -> [VeilDisplayCaptureLayout] {
        try screens.map { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                throw VeilRenderError.unavailable("An active display has no capture identifier.")
            }
            let id = number.uint32Value
            let stableID = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
                ?? "display-id-\(id)"
            return VeilDisplayCaptureLayout(id: id, stableID: stableID, frame: screen.frame,
                backingScale: screen.backingScaleFactor, pixelWidth: CGDisplayPixelsWide(id), pixelHeight: CGDisplayPixelsHigh(id),
                menuBand: max(NSStatusBar.system.thickness, screen.safeAreaInsets.top))
        }.sorted { $0.id < $1.id }
    }
    private func validateStartup(generation run: UInt64, initialDisplays: [VeilDisplayCaptureLayout]) throws {
        guard run == generation else { throw CancellationError() }
        guard !failed else {
            throw VeilRenderError.unavailable(failureReason ?? "Capture failed while starting. Enable again.")
        }
        guard try Self.identities(for: NSScreen.screens) == initialDisplays else {
            throw VeilRenderError.unavailable("Display arrangement changed while capture was starting. Enable again to capture every current display.")
        }
    }

    private var displayConfiguration = VeilDisplayConfigurationGuard()
    private var sessions: [DisplaySession] = []
    private var generation: UInt64 = 0
    private var failed = false
    private var displayObserver: NSObjectProtocol?
    private var selectedDisplayIDs: Set<UInt32>?
    private var effect: (left: Double, right: Double, blur: Double, feather: Double, opaque: Bool, shield: Bool, wholeScreen: Bool, blockInput: Bool, blocksEntireDisplay: Bool) = (0, 0, 32, 0.12, false, false, false, false, false)

    init() {
        refreshDisplays()
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.displaysChanged() }
        }
    }

    func refreshDisplays() {
        availableDisplays = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = number.uint32Value
            let stableID: String
            if let uuid = CGDisplayCreateUUIDFromDisplayID(id) {
                stableID = CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
            } else { stableID = "display-id-\(id)" }
            return VeilDisplayInfo(id:id, stableID:stableID, name:screen.localizedName, frame:screen.frame, backingScale:screen.backingScaleFactor)
        }
    }

    func start(selectedDisplayIDs: Set<UInt32>? = nil) async throws {
        stop()
        self.selectedDisplayIDs = selectedDisplayIDs
        refreshDisplays()
        // Do not reject an explicit start based only on the advisory CoreGraphics
        // preflight; ScreenCaptureKit performs its own OS authorization check.
        generation &+= 1
        let run = generation
        failed = false
        status = "Preparing display capture…"
        let allScreens = NSScreen.screens
        let initialDisplays = try Self.identities(for: allScreens)
        let screens = allScreens.filter { screen in
            guard let selectedDisplayIDs else { return true }
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return selectedDisplayIDs.contains(number.uint32Value)
        }
        guard !screens.isEmpty else { throw VeilRenderError.unavailable("Select at least one connected display before enabling AirVeil.") }
        let fresh = screens.map { DisplaySession(screen: $0) }
        sessions = fresh
        do {
            for session in fresh {
                session.observeBlockedPointer { [weak self] in
                    guard let self, self.generation == run, self.isRunning else { return }
                    self.blockedPointerEventCount &+= 1
                }
                if let error = session.view.initializationError { throw VeilRenderError.unavailable(error) }
            }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            try validateStartup(generation: run, initialDisplays: initialDisplays)
            guard let ownApp = content.applications.first(where: { $0.processID == ProcessInfo.processInfo.processIdentifier }) else {
                throw VeilRenderError.unavailable("AirVeil could not identify its own windows for capture exclusion. Keep Settings open and try again.")
            }
            for (screen, session) in zip(screens, fresh) {
                try validateStartup(generation: run, initialDisplays: initialDisplays)
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
                    throw VeilRenderError.unavailable("An active display could not be matched to screen capture.")
                }
                let filter = SCContentFilter(display: display, excludingApplications: [ownApp], exceptingWindows: [])
                if #available(macOS 14.2, *) { filter.includeMenuBar = true }
                let config = SCStreamConfiguration()
                let scale = Double(filter.pointPixelScale)
                guard scale.isFinite, scale > 0, filter.contentRect.width > 0, filter.contentRect.height > 0 else {
                    throw VeilRenderError.unavailable("Invalid display capture geometry.")
                }
                config.width = Int((filter.contentRect.width * scale).rounded())
                config.height = Int((filter.contentRect.height * scale).rounded())
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.colorSpaceName = CGColorSpace.sRGB
                config.showsCursor = false
                config.capturesAudio = false
                config.queueDepth = 3
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                session.view.sourcePixelScale = scale
                let sink = DisplayCaptureSink(mailbox: session.mailbox)
                sink.onFailure = { [weak self] reason in Task { @MainActor [weak self] in self?.captureFailed(reason, generation: run) } }
                let stream = SCStream(filter: filter, configuration: config, delegate: sink)
                session.sink = sink; session.stream = stream
                session.view.onRenderFailure = { [weak self] reason in self?.captureFailed("Renderer failed: \(reason)", generation: run) }
                session.view.onFirstFrame = { [weak self, weak session] in
                    guard let self, self.generation == run, !self.failed else { return }
                    session?.ready = true
                    if self.sessions.allSatisfy({ $0.ready }) { self.isReady = true; self.status = "Live desktop capture"; self.updateBlockers() }
                }
                try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "app.airveil.capture.\(number.uint32Value)", qos: .userInteractive))
                try await stream.startCapture()
                guard run == generation else { try? await stream.stopCapture(); throw CancellationError() }
                try validateStartup(generation: run, initialDisplays: initialDisplays)
            }
            try validateStartup(generation: run, initialDisplays: initialDisplays)
            displayConfiguration.begin(initialDisplays)
            isRunning = true
            status = "Waiting for first desktop frames…"
            applyEffect()
            for session in fresh { session.window.orderFrontRegardless() }
            updateBlockers()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, self.generation == run, !self.isReady else { return }
                self.captureFailed("No first desktop frame arrived. Pause and check Screen Recording permission.", generation: run)
            }
        } catch {
            if run == generation { stop(); status = error.localizedDescription }
            throw error
        }
    }

    /// Explicit disable always hides synchronously. Obsolete callbacks cannot restore coverage.
    func stop() {
        displayConfiguration.stop()
        generation &+= 1
        let old = sessions
        sessions.removeAll()
        isRunning = false; isReady = false; failed = false; failureReason = nil
        status = "Desktop effect paused"
        for session in old {
            session.mailbox.invalidate()
            session.view.isPaused = true
            session.view.onFirstFrame = nil
            session.view.onRenderFailure = nil
            session.window.orderOut(nil)
            session.hideBlockers()
            for blocker in session.blockers { blocker.close() }
            session.view.releaseCapturedResources()
        }
        Task {
            for session in old {
                if let stream = session.stream { try? await stream.stopCapture() }
                session.window.close()
            }
        }
    }

    func update(left: Double, right: Double, blurPoints: Double, feather: Double, opaque: Bool, shield: Bool, wholeScreen: Bool = false, blockInput: Bool = false, blocksEntireDisplay: Bool = false) {
        effect = (left, right, blurPoints, feather, opaque, shield, wholeScreen, blockInput, blocksEntireDisplay)
        applyEffect()
        updateBlockers()
    }
    private func updateBlockers() {
        let regions = VeilInputGeometry.intervals(left:effect.left, right:effect.right, feather:effect.feather, wholeScreen:effect.wholeScreen, blocksEntireDisplay:effect.blocksEntireDisplay, shield:effect.shield || failed)
        for session in sessions { session.setBlockers(regions, active:isRunning && effect.blockInput && (isReady || effect.shield || failed)) }
    }
    private func applyEffect() {
        for session in sessions {
            session.view.setEffect(left: effect.left, right: effect.right, blurPoints: effect.blur, feather: effect.feather, opaque: effect.opaque, shield: effect.shield || failed, wholeScreen: effect.wholeScreen)
        }
    }
    private func captureFailed(_ message: String, generation run: UInt64) {
        guard run == generation, !failed else { return }
        failed = true
        isReady = false
        failureReason = message
        status = "Covered — \(message)"
        // A solid AppKit backing remains effective even if the GPU caused this failure.
        for session in sessions { session.mailbox.invalidate(); session.coverWithoutGPU() }
        updateBlockers()
        let stoppedSessions = sessions
        Task {
            for session in stoppedSessions {
                if let stream = session.stream { try? await stream.stopCapture() }
            }
        }
    }
    private func displaysChanged() {
        refreshDisplays()
        guard displayConfiguration.shouldRebuild(current: try? Self.identities(for: NSScreen.screens),
                                                  isRunning: isRunning) else { return }
        captureFailed("Display arrangement changed. Pause and enable again to rebuild capture.", generation: generation)
        // Disconnected-screen windows can be moved by AppKit onto another screen.
        // Replace fault covers using only the user's currently connected selection.
        let old = sessions
        sessions = []
        for session in old {
            session.window.orderOut(nil)
            session.hideBlockers()
            session.window.close()
            for blocker in session.blockers { blocker.close() }
        }
        for screen in NSScreen.screens {
            if let selectedDisplayIDs {
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      selectedDisplayIDs.contains(number.uint32Value) else { continue }
            }
            let session = DisplaySession(screen: screen)
            let run = generation
            session.observeBlockedPointer { [weak self] in
                guard let self, self.generation == run, self.isRunning else { return }
                self.blockedPointerEventCount &+= 1
            }
            session.coverWithoutGPU()
            sessions.append(session)
        }
        updateBlockers()
        if sessions.isEmpty { status = "Selected display disconnected — enable again after connecting it" }
    }
}
