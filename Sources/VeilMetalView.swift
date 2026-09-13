import AppKit
import MetalKit
import MetalPerformanceShaders
import CoreVideo

enum VeilRenderError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { switch self { case .unavailable(let reason): return reason } }
}

/// One pending image, replaced rather than queued when capture outruns display.
final class VeilFrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CVPixelBuffer?
    private var accepting = true
    private var onFrame: (@Sendable () -> Void)?
    func put(_ buffer: CVPixelBuffer) {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        let notify = pending == nil ? onFrame : nil
        pending = buffer
        lock.unlock()
        // Never enter the main actor while holding the producer lock. A pending
        // frame coalesces later arrivals until the renderer consumes it.
        notify?()
    }
    func setFrameNotification(_ callback: (@Sendable () -> Void)?) {
        lock.lock()
        onFrame = accepting ? callback : nil
        let notify = pending != nil ? onFrame : nil
        lock.unlock()
        notify?()
    }
    var hasPending: Bool { lock.lock(); defer { lock.unlock() }; return pending != nil }
    func peek() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return pending }
    func take() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; let result = pending; pending = nil; return result }
    func invalidate() { lock.lock(); defer { lock.unlock() }; accepting = false; pending = nil; onFrame = nil }
}

private final class CaptureTextureKeeper: @unchecked Sendable {
    let texture: CVMetalTexture
    let buffer: CVPixelBuffer
    init(texture: CVMetalTexture, buffer: CVPixelBuffer) { self.texture = texture; self.buffer = buffer }
}

@MainActor final class VeilMetalView: MTKView, MTKViewDelegate {
    private(set) var initializationError: String?
    private(set) var lastGPUTimeMS: Double = 0
    private(set) var drawSubmissionCount: UInt64 = 0
    private(set) var sourceBlitCount: UInt64 = 0
    private(set) var gaussianPassCount: UInt64 = 0
    private(set) var redrawRequestCount: UInt64 = 0
    private var needsRender = true
    private var redrawScheduled = false
    private var displayInvalidated = false
    private var resourceGeneration: UInt64 = 0
    private var resourcesReleased = false
    /// Controls visual work only. The headphone stream belongs to AppModel.
    var renderingEnabled = true {
        didSet {
            if oldValue != renderingEnabled {
                displayInvalidated = false
                if renderingEnabled { requestRender() }
            }
        }
    }
    var rendersBaseImage = false { didSet { if oldValue != rendersBaseImage { requestRender() } } }
    var sourcePixelScale: Double = 1 { didSet { if oldValue != sourcePixelScale { blurDirty = true; requestRender() } } }
    var frameMailbox: VeilFrameMailbox? {
        didSet {
            oldValue?.setFrameNotification(nil)
            resourceGeneration &+= 1
            redrawScheduled = false
            displayInvalidated = false
            guard let frameMailbox else { return }
            resourcesReleased = false
            hasFrame = false
            let run = resourceGeneration
            frameMailbox.setFrameNotification { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.resourceGeneration == run, !self.resourcesReleased else { return }
                    if !self.hasFrame || self.requiresSourceForOutput { self.requestRender() }
                }
            }
            requestRender()
        }
    }
    var onRenderFailure: ((String) -> Void)?
    var onFirstFrame: (() -> Void)?
    private var hasFrame = false
    private var commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var cache: CVMetalTextureCache?
    private var source: MTLTexture?
    private var levels: [MTLTexture] = []
    private var kernels: [MPSImageGaussianBlur] = []
    private var kernelSigma: Double = -1
    private var blurDirty = false
    private let inFlight = DispatchSemaphore(value: 2)
    private var left: Double = 0
    private var right: Double = 0
    private var blurPoints: Double = 32
    private var feather: Double = 0.12
    private var concealOpaque = false
    private var shield = false
    private var wholeScreen = false
    private var didReportFailure = false

    convenience init(frame: NSRect) { self.init(frame: frame, device: MTLCreateSystemDefaultDevice()) }
    override init(frame frameRect: NSRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        preferredFramesPerSecond = 60
        enableSetNeedsDisplay = true
        isPaused = true
        wantsLayer = true
        layer?.isOpaque = false
        (layer as? CAMetalLayer)?.isOpaque = false
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        delegate = self
        do { try configure() } catch { initializationError = error.localizedDescription }
    }
    required init(coder: NSCoder) { fatalError("Use init(frame:)") }
    override var isOpaque: Bool { false }

    private func configure() throws {
        guard let device, let queue = device.makeCommandQueue() else { throw VeilRenderError.unavailable("Metal is unavailable on this Mac.") }
        commandQueue = queue
        let url = Bundle.main.url(forResource: "Veil", withExtension: "metal")
            ?? Bundle.main.url(forResource: "Veil", withExtension: "metal", subdirectory: "Resources")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Veil.metal")
        let text = try String(contentsOf: url, encoding: .utf8)
        let library = try device.makeLibrary(source: text, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "veilVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "veilFragment")
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        // Shader emits premultiplied pixels. The window compositor supplies the desktop.
        descriptor.colorAttachments[0].isBlendingEnabled = false
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess else {
            throw VeilRenderError.unavailable("Could not create the capture texture cache.")
        }
        try allocate(width: 1, height: 1)
        var pixel: UInt32 = 0xFF182018
        source?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
    }

    private func allocate(width: Int, height: Int) throws {
        guard let device else { throw VeilRenderError.unavailable("No Metal device.") }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .shared
        guard let image = device.makeTexture(descriptor: descriptor) else { throw VeilRenderError.unavailable("Could not allocate desktop image.") }
        var bank: [MTLTexture] = []
        descriptor.storageMode = .private
        for _ in 0..<3 {
            guard let level = device.makeTexture(descriptor: descriptor) else { throw VeilRenderError.unavailable("Could not allocate blur textures.") }
            bank.append(level)
        }
        source = image; levels = bank; blurDirty = true
    }

    func setImage(_ image: CGImage) throws {
        guard let device else { throw VeilRenderError.unavailable(initializationError ?? "Metal unavailable.") }
        let texture = try MTKTextureLoader(device: device).newTexture(cgImage: image, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft])
        try allocate(width: texture.width, height: texture.height)
        source = texture
        sourcePixelScale = Double(image.width) / max(1, Double(bounds.width))
        resourcesReleased = false
        blurDirty = true; hasFrame = true; requestRender()
    }

    func setEffect(left: Double, right: Double, blurPoints: Double, feather: Double, opaque: Bool, shield: Bool, wholeScreen: Bool = false) {
        func finite(_ value: Double, _ fallback: Double) -> Double { value.isFinite ? value : fallback }
        let nextLeft = min(1, max(0, finite(left, 0)))
        let nextRight = min(1, max(0, finite(right, 0)))
        let sigma = min(80, max(1, finite(blurPoints, 32)))
        let nextFeather = min(0.5, max(0.001, finite(feather, 0.12)))
        let changed = self.left != nextLeft || self.right != nextRight || self.blurPoints != sigma ||
            self.feather != nextFeather || concealOpaque != opaque || self.shield != shield || self.wholeScreen != wholeScreen
        self.left = nextLeft; self.right = nextRight
        if self.blurPoints != sigma { self.blurPoints = sigma; blurDirty = true }
        self.feather = nextFeather
        self.concealOpaque = opaque; self.shield = shield; self.wholeScreen = wholeScreen
        if changed { requestRender() }
    }

    private var fullOpaque: Bool {
        concealOpaque && ((left == 1 && right == 1) || (wholeScreen && (left == 1 || right == 1)))
    }
    private var requiresSourceForOutput: Bool {
        !shield && !fullOpaque && (rendersBaseImage || left > 0 || right > 0)
    }
    private var requiresBlur: Bool { requiresSourceForOutput && (left > 0 || right > 0) }
    private var hasWork: Bool {
        needsRender || (!hasFrame && frameMailbox?.hasPending == true) ||
            (requiresSourceForOutput && frameMailbox?.hasPending == true) || (hasFrame && requiresBlur && blurDirty)
    }

    /// Coalesces producer, effect, resize, and completion notifications into a
    /// single AppKit invalidation. The MTKView periodic loop remains paused.
    func requestRender() {
        needsRender = true
        scheduleDisplayIfNeeded()
    }
    private func scheduleDisplayIfNeeded() {
        guard renderingEnabled, !resourcesReleased, !redrawScheduled, !displayInvalidated, hasWork else { return }
        redrawScheduled = true
        let run = resourceGeneration
        Task { @MainActor [weak self] in
            guard let self, self.resourceGeneration == run else { return }
            self.redrawScheduled = false
            guard self.renderingEnabled, !self.resourcesReleased, self.hasWork else { return }
            self.displayInvalidated = true
            self.redrawRequestCount &+= 1
            self.needsDisplay = true
        }
    }

    private func mapCapture(_ buffer: CVPixelBuffer) throws -> (MTLTexture, CaptureTextureKeeper) {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        var wrapper: CVMetalTexture?
        guard let cache, CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, width, height, 0, &wrapper) == kCVReturnSuccess,
              let wrapper, let incoming = CVMetalTextureGetTexture(wrapper) else {
            throw VeilRenderError.unavailable("Could not map the captured desktop frame.")
        }
        return (incoming, CaptureTextureKeeper(texture: wrapper, buffer: buffer))
    }

    private func encode(to target: MTLTexture, command: MTLCommandBuffer) throws {
        guard !resourcesReleased, let device, let pipeline else { throw VeilRenderError.unavailable(initializationError ?? "Renderer unavailable.") }
        // A neutral/solid surface retains only the newest pending CV buffer.
        // Validate its first frame without copying or blurring invisible pixels.
        let incomingBuffer = requiresSourceForOutput ? frameMailbox?.take() : (!hasFrame ? frameMailbox?.peek() : nil)
        if let buffer = incomingBuffer {
            let (incoming, keeper) = try mapCapture(buffer)
            command.addCompletedHandler { _ in withExtendedLifetime(keeper) {} }
            if requiresSourceForOutput {
                if source?.width != incoming.width || source?.height != incoming.height {
                    try allocate(width: incoming.width, height: incoming.height)
                }
                guard let source, let blit = command.makeBlitCommandEncoder() else {
                    throw VeilRenderError.unavailable("Could not copy the captured desktop frame.")
                }
                blit.copy(from: incoming, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0), sourceSize: .init(width: incoming.width, height: incoming.height, depth: 1), to: source, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init(x: 0, y: 0, z: 0))
                blit.endEncoding()
                sourceBlitCount &+= 1
                blurDirty = true
            }
            if !hasFrame {
                hasFrame = true
                let run = resourceGeneration
                command.addCompletedHandler { [weak self] buffer in
                    guard buffer.status == .completed else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.resourceGeneration == run, !self.resourcesReleased else { return }
                        self.onFirstFrame?()
                    }
                }
            }
        }
        if !hasFrame || !requiresSourceForOutput {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = (shield || !hasFrame || fullOpaque)
                ? MTLClearColorMake(0.075, 0.085, 0.105, 1) : MTLClearColorMake(0, 0, 0, 0)
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                throw VeilRenderError.unavailable("Could not clear the overlay.")
            }
            encoder.endEncoding()
            return
        }
        guard let source, levels.count == 3 else { throw VeilRenderError.unavailable("No render textures.") }
        if requiresBlur {
            let sigma = blurPoints * min(4, max(0.25, sourcePixelScale.isFinite ? sourcePixelScale : 1))
            if kernelSigma != sigma {
                kernels = [6.0/32, 0.5, 1].map { fraction in
                    let kernel = MPSImageGaussianBlur(device: device, sigma: Float(sigma * fraction))
                    kernel.edgeMode = .clamp
                    return kernel
                }
                kernelSigma = sigma; blurDirty = true
            }
            if blurDirty {
                for i in 0..<3 { kernels[i].encode(commandBuffer: command, sourceTexture: source, destinationTexture: levels[i]) }
                gaussianPassCount &+= 3
                blurDirty = false
            }
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clearColor
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw VeilRenderError.unavailable("Could not create compositor encoder.") }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        for i in 0..<3 { encoder.setFragmentTexture(levels[i], index: i + 1) }
        var values: [Float] = [Float(left), Float(right), Float(feather), 0, concealOpaque ? 1 : 0, (shield || !hasFrame) ? 1 : 0, rendersBaseImage ? 1 : 0, wholeScreen ? 1 : 0]
        values.withUnsafeMutableBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    func draw(in view: MTKView) {
        _ = submitRender { command in
            guard let drawable = currentDrawable else { return nil }
            command.present(drawable)
            return drawable.texture
        }
    }

    @discardableResult
    private func submitRender(target: (MTLCommandBuffer) -> MTLTexture?) -> Bool {
        displayInvalidated = false
        guard renderingEnabled, !resourcesReleased, hasWork else { return false }
        guard initializationError == nil, inFlight.wait(timeout: .now()) == .success else { return false }
        // Busy slots leave work dirty. A completion requests a later draw,
        // without polling the GPU or blocking the main actor.
        guard let command = commandQueue?.makeCommandBuffer(), let texture = target(command) else {
            inFlight.signal(); return false
        }
        do { try encode(to: texture, command: command) }
        catch { inFlight.signal(); reportFailure(error.localizedDescription); return false }
        let gate = inFlight
        let run = resourceGeneration
        command.addCompletedHandler { [weak self] buffer in
            gate.signal()
            let failure = buffer.error?.localizedDescription
            let duration = max(0, buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            Task { @MainActor [weak self] in
                guard let self, self.resourceGeneration == run, !self.resourcesReleased else { return }
                self.lastGPUTimeMS = duration
                if let failure { self.reportFailure(failure) }
                else { self.scheduleDisplayIfNeeded() }
            }
        }
        command.commit()
        needsRender = false
        drawSubmissionCount &+= 1
        return true
    }

    /// Synthetic demand/lifecycle validation without an on-screen window. The
    /// optional GPU event lets a bounded test exercise real in-flight pressure.
    @discardableResult
    func renderPendingOffscreen(to target: MTLTexture, waitingFor event: MTLSharedEvent? = nil) -> Bool {
        submitRender { command in
            if let event { command.encodeWaitForEvent(event, value: 1) }
            return target
        }
    }

    /// Discard sensitive source pixels immediately on explicit pause/session loss.
    /// Already committed commands retain their own resource references until completion.
    func releaseCapturedResources() {
        renderingEnabled = false
        resourcesReleased = true
        resourceGeneration &+= 1
        redrawScheduled = false
        displayInvalidated = false
        isPaused = true
        frameMailbox?.invalidate()
        frameMailbox = nil
        source = nil
        levels.removeAll()
        kernels.removeAll()
        kernelSigma = -1
        if let cache { CVMetalTextureCacheFlush(cache, 0) }
        hasFrame = false
        blurDirty = false
        needsRender = false
        didReportFailure = false
    }

    private func reportFailure(_ text: String) {
        guard !didReportFailure else { return }
        didReportFailure = true
        onRenderFailure?(text)
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { requestRender() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); requestRender() }

    /// Synthetic artifact validation only; never called by the live rendering loop.
    func renderOffscreen(width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0, let device, let command = commandQueue?.makeCommandBuffer() else { throw VeilRenderError.unavailable("Cannot render test image.") }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: colorPixelFormat, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw VeilRenderError.unavailable("Cannot allocate test image.") }
        try encode(to: texture, command: command)
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        lastGPUTimeMS = max(0, command.gpuEndTime - command.gpuStartTime) * 1000
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw VeilRenderError.unavailable("Could not export test image.") }
        return image
    }
}
