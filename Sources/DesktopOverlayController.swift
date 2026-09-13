import AppKit
import Combine
import ScreenCaptureKit
import CoreMedia

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
    @MainActor private final class DisplaySession {
        let window: VeilOverlayWindow
        let view: VeilMetalView
        let mailbox = VeilFrameMailbox()
        var sink: DisplayCaptureSink?
        var stream: SCStream?
        var ready = false
        init(screen: NSScreen) {
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
        func coverWithoutGPU() {
            view.isPaused = true
            view.releaseCapturedResources()
            view.isHidden = true
            window.backgroundColor = NSColor(calibratedRed: 0.075, green: 0.085, blue: 0.105, alpha: 1)
            window.orderFrontRegardless()
        }
    }
    private var sessions: [DisplaySession] = []
    private var generation: UInt64 = 0
    private var failed = false
    private var displayObserver: NSObjectProtocol?
    private var effect: (left: Double, right: Double, blur: Double, feather: Double, opaque: Bool, shield: Bool, wholeScreen: Bool) = (0, 0, 32, 0.12, false, false, false)

    init() {
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.displaysChanged() }
        }
    }

    func start() async throws {
        stop()
        // Do not reject an explicit start based only on the advisory CoreGraphics
        // preflight; ScreenCaptureKit performs its own OS authorization check.
        generation &+= 1
        let run = generation
        failed = false
        status = "Preparing display capture…"
        let screens = NSScreen.screens
        guard !screens.isEmpty else { throw VeilRenderError.unavailable("No active displays found.") }
        let fresh = screens.map { DisplaySession(screen: $0) }
        sessions = fresh
        do {
            for session in fresh {
                if let error = session.view.initializationError { throw VeilRenderError.unavailable(error) }
            }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard run == generation else { throw CancellationError() }
            guard let ownApp = content.applications.first(where: { $0.processID == ProcessInfo.processInfo.processIdentifier }) else {
                throw VeilRenderError.unavailable("AirVeil could not identify its own windows for capture exclusion. Keep Settings open and try again.")
            }
            for (screen, session) in zip(screens, fresh) {
                guard run == generation else { throw CancellationError() }
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
                    if self.sessions.allSatisfy({ $0.ready }) { self.isReady = true; self.status = "Live desktop capture" }
                }
                try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "app.airveil.capture.\(number.uint32Value)", qos: .userInteractive))
                try await stream.startCapture()
                guard run == generation else { try? await stream.stopCapture(); throw CancellationError() }
            }
            guard run == generation else { throw CancellationError() }
            isRunning = true
            status = "Waiting for first desktop frames…"
            applyEffect()
            for session in fresh { session.window.orderFrontRegardless() }
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
            session.view.releaseCapturedResources()
        }
        Task {
            for session in old {
                if let stream = session.stream { try? await stream.stopCapture() }
                session.window.close()
            }
        }
    }

    func update(left: Double, right: Double, blurPoints: Double, feather: Double, opaque: Bool, shield: Bool, wholeScreen: Bool = false) {
        effect = (left, right, blurPoints, feather, opaque, shield, wholeScreen)
        applyEffect()
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
        let stoppedSessions = sessions
        Task {
            for session in stoppedSessions {
                if let stream = session.stream { try? await stream.stopCapture() }
            }
        }
    }
    private func displaysChanged() {
        guard isRunning else { return }
        captureFailed("Display arrangement changed. Pause and enable again to rebuild capture.", generation: generation)
        // Cover newly attached/resized screens too, without trusting obsolete capture geometry.
        for screen in NSScreen.screens where !sessions.contains(where: { $0.window.frame == screen.frame }) {
            let session = DisplaySession(screen: screen)
            session.coverWithoutGPU()
            sessions.append(session)
        }
    }
}
