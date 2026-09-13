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
    func put(_ buffer: CVPixelBuffer) { lock.lock(); defer { lock.unlock() }; if accepting { pending = buffer } }
    var hasPending: Bool { lock.lock(); defer { lock.unlock() }; return pending != nil }
    func take() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; let result = pending; pending = nil; return result }
    func invalidate() { lock.lock(); defer { lock.unlock() }; accepting = false; pending = nil }
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
    private var needsRender = true
    var rendersBaseImage = false { didSet { if oldValue != rendersBaseImage { needsRender = true } } }
    var sourcePixelScale: Double = 1 { didSet { if oldValue != sourcePixelScale { blurDirty = true } } }
    var frameMailbox: VeilFrameMailbox? { didSet { needsRender = true } }
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
    private var didReportFailure = false

    convenience init(frame: NSRect) { self.init(frame: frame, device: MTLCreateSystemDefaultDevice()) }
    override init(frame frameRect: NSRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        preferredFramesPerSecond = 60
        enableSetNeedsDisplay = false
        isPaused = false
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
        blurDirty = true; hasFrame = true; needsRender = true
    }

    func setEffect(left: Double, right: Double, blurPoints: Double, feather: Double, opaque: Bool, shield: Bool) {
        func finite(_ value: Double, _ fallback: Double) -> Double { value.isFinite ? value : fallback }
        let nextLeft = min(1, max(0, finite(left, 0)))
        let nextRight = min(1, max(0, finite(right, 0)))
        let sigma = min(80, max(1, finite(blurPoints, 32)))
        let nextFeather = min(0.5, max(0.001, finite(feather, 0.12)))
        if self.left != nextLeft || self.right != nextRight || self.blurPoints != sigma ||
            self.feather != nextFeather || concealOpaque != opaque || self.shield != shield {
            needsRender = true
        }
        self.left = nextLeft; self.right = nextRight
        if self.blurPoints != sigma { self.blurPoints = sigma; blurDirty = true }
        self.feather = nextFeather
        self.concealOpaque = opaque; self.shield = shield
    }

    private func encode(to target: MTLTexture, command: MTLCommandBuffer) throws {
        guard let device, let pipeline else { throw VeilRenderError.unavailable(initializationError ?? "Renderer unavailable.") }
        if let buffer = frameMailbox?.take() {
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            if source?.width != width || source?.height != height { try allocate(width: width, height: height) }
            var wrapper: CVMetalTexture?
            guard let cache, CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, width, height, 0, &wrapper) == kCVReturnSuccess,
                  let wrapper, let incoming = CVMetalTextureGetTexture(wrapper), let source,
                  let blit = command.makeBlitCommandEncoder() else { throw VeilRenderError.unavailable("Could not map the captured desktop frame.") }
            blit.copy(from: incoming, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0), sourceSize: .init(width: width, height: height, depth: 1), to: source, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init(x: 0, y: 0, z: 0))
            blit.endEncoding()
            // Core Video owns the IOSurface lifetime, not merely MTLTexture.
            let keeper = CaptureTextureKeeper(texture: wrapper, buffer: buffer)
            command.addCompletedHandler { _ in withExtendedLifetime(keeper) {} }
            blurDirty = true
            if !hasFrame {
                hasFrame = true
                command.addCompletedHandler { [weak self] buffer in
                    guard buffer.status == .completed else { return }
                    Task { @MainActor [weak self] in self?.onFirstFrame?() }
                }
            }
        }
        guard let source, levels.count == 3 else { throw VeilRenderError.unavailable("No render textures.") }
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
            blurDirty = false
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
        var values: [Float] = [Float(left), Float(right), Float(feather), 0, concealOpaque ? 1 : 0, (shield || !hasFrame) ? 1 : 0, rendersBaseImage ? 1 : 0, 0]
        values.withUnsafeMutableBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    func draw(in view: MTKView) {
        // Keep MTKView's update source alive for incoming captures and motion,
        // but do not acquire a drawable or submit unchanged pixels every tick.
        guard needsRender || blurDirty || frameMailbox?.hasPending == true else { return }
        guard initializationError == nil, inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable = currentDrawable, let command = commandQueue?.makeCommandBuffer() else { inFlight.signal(); return }
        do { try encode(to: drawable.texture, command: command) }
        catch { inFlight.signal(); reportFailure(error.localizedDescription); return }
        let gate = inFlight
        command.addCompletedHandler { [weak self] buffer in
            gate.signal()
            let failure = buffer.error?.localizedDescription
            let duration = max(0, buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            Task { @MainActor [weak self] in
                self?.lastGPUTimeMS = duration
                if let failure { self?.reportFailure(failure) }
            }
        }
        command.present(drawable)
        command.commit()
        needsRender = false
        drawSubmissionCount &+= 1
    }

    /// Discard sensitive source pixels immediately on explicit pause/session loss.
    /// Already committed commands retain their own resource references until completion.
    func releaseCapturedResources() {
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
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { needsRender = true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsRender = true }

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
