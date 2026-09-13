import AppKit
import ImageIO
import UniformTypeIdentifiers
import CoreVideo
import Metal

@main struct RenderTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let view = VeilMetalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.isPaused = true
        if let error = view.initializationError { throw VeilRenderError.unavailable(error) }
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/render-artifacts")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for scale in [1, 2] {
            let width = 640 * scale, height = 400 * scale
            let input = synthetic(width: width, height: height, inverted: false)
            try view.setImage(input)
            view.sourcePixelScale = Double(scale)
            view.rendersBaseImage = false
            view.setEffect(left: 0, right: 0, blurPoints: 32, feather: 0.12, opaque: false, shield: false)
            let blurBeforeNeutral = view.gaussianPassCount
            let neutral = try view.renderOffscreen(width: width, height: height)
            precondition(view.gaussianPassCount == blurBeforeNeutral, "Neutral must not compute unused Gaussian levels")
            let neutralBytes = bytes(neutral)
            precondition(neutralBytes.allSatisfy { $0 == 0 }, "Neutral must be entirely transparent black")

            view.setEffect(left: 0, right: 1, blurPoints: 32, feather: 0.12, opaque: false, shield: false)
            let right = try view.renderOffscreen(width: width, height: height)
            let rightBytes = bytes(right)
            precondition(pixel(rightBytes, width, width/8, height/2)[3] == 0, "Clear side must remain transparent")
            precondition(pixel(rightBytes, width, width*7/8, height/2)[3] == 255, "Covered side must have full alpha")
            var previous: UInt8 = 0
            for x in 0..<width {
                let value = pixel(rightBytes, width, x, height/2)[3]
                precondition(value >= previous, "Feather alpha must be monotonic")
                previous = value
                for channel in pixel(rightBytes, width, x, height/2).prefix(3) {
                    precondition(channel <= value, "Premultiplied color may not exceed alpha")
                }
            }
            view.setEffect(left: 1, right: 0, blurPoints: 32, feather: 0.12, opaque: false, shield: false)
            let leftBytes = bytes(try view.renderOffscreen(width: width, height: height))
            for x in 0..<width {
                precondition(abs(Int(pixel(rightBytes,width,x,height/2)[3])-Int(pixel(leftBytes,width,width-1-x,height/2)[3])) <= 1, "Masks must mirror")
            }

            view.setEffect(left: 0, right: 1, blurPoints: 32, feather: 0.12, opaque: true, shield: false)
            let opaqueA = bytes(try view.renderOffscreen(width: width, height: height))
            try view.setImage(synthetic(width: width, height: height, inverted: true))
            let opaqueB = bytes(try view.renderOffscreen(width: width, height: height))
            for y in stride(from: 0, to: height, by: 17) {
                for x in (width*3/4)..<width {
                    precondition(pixel(opaqueA,width,x,y) == pixel(opaqueB,width,x,y), "Opaque outer side must be independent of captured content")
                }
            }
            view.setEffect(left: 0, right: 0, blurPoints: 32, feather: 0.12, opaque: false, shield: true)
            let blurBeforeShield = view.gaussianPassCount
            let shieldBytes = bytes(try view.renderOffscreen(width: width, height: height))
            precondition(view.gaussianPassCount == blurBeforeShield, "Shield must not compute unused Gaussian levels")
            for i in stride(from: 3, to: shieldBytes.count, by: 4) { precondition(shieldBytes[i] == 255, "Fault shield must cover every pixel") }

            try view.setImage(input)
            view.rendersBaseImage = true
            view.setEffect(left: 0, right: 0, blurPoints: 32, feather: 0.12, opaque: false, shield: false)
            let baseBytes = bytes(try view.renderOffscreen(width: width, height: height))
            let topLeft = pixel(baseBytes,width,8*scale,8*scale)
            let bottomLeft = pixel(baseBytes,width,8*scale,height-8*scale)
            precondition(topLeft[2] > 200 && topLeft[0] < 40, "Top-left red marker must preserve orientation")
            precondition(bottomLeft[0] > 200 && bottomLeft[2] < 40, "Bottom-left blue marker must preserve orientation")
            view.setEffect(left: 0, right: 1, blurPoints: 32, feather: 0.12, opaque: false, shield: false)
            try save(view.renderOffscreen(width: width, height: height), to: output.appendingPathComponent("right-blur-\(scale)x.png"))
            view.setEffect(left: 1, right: 0, blurPoints: 32, feather: 0.12, opaque: false, shield: false)
            try save(view.renderOffscreen(width: width, height: height), to: output.appendingPathComponent("left-blur-\(scale)x.png"))
            view.rendersBaseImage = false
            view.setEffect(left: 0, right: 0, blurPoints: 32, feather: 0.12, opaque: false, shield: false, wholeScreen: true)
            let wholeNeutral = bytes(try view.renderOffscreen(width: width, height: height))
            precondition(wholeNeutral.allSatisfy { $0 == 0 },
                         "Whole-screen neutral must be entirely transparent")
            for progress in [0.25, 0.5, 0.75] {
                view.setEffect(left: 0, right: progress, blurPoints: 32, feather: 0.12, opaque: false, shield: false, wholeScreen: true)
                let sweptRight = bytes(try view.renderOffscreen(width: width, height: height))
                let boundary = 1.06 - 1.12 * progress
                var previousAlpha: UInt8 = 0
                for x in 0..<width {
                    let alpha = pixel(sweptRight,width,x,height/2)[3]
                    let normalized = (Double(x) + 0.5) / Double(width)
                    precondition(alpha >= previousAlpha, "Whole-screen right sweep must be spatially monotonic")
                    if normalized < boundary - 0.06 { precondition(alpha == 0, "Ahead of sweep must stay clear") }
                    if normalized > boundary + 0.06 { precondition(alpha == 255, "Behind sweep must reach full blur coverage") }
                    previousAlpha = alpha
                }
                view.setEffect(left: progress, right: 0, blurPoints: 32, feather: 0.12, opaque: false, shield: false, wholeScreen: true)
                let sweptLeft = bytes(try view.renderOffscreen(width: width, height: height))
                for x in 0..<width {
                    precondition(abs(Int(pixel(sweptRight,width,x,height/2)[3])-Int(pixel(sweptLeft,width,width-1-x,height/2)[3])) <= 1,
                                 "Whole-screen sweeps must mirror at every progress")
                }
                view.rendersBaseImage = true
                view.setEffect(left: 0, right: progress, blurPoints: 32, feather: 0.12, opaque: false, shield: false, wholeScreen: true)
                try save(view.renderOffscreen(width: width, height: height), to: output.appendingPathComponent("whole-right-\(Int(progress*100))-\(scale)x.png"))
                view.rendersBaseImage = false
            }
            for leftward in [false, true] {
                view.setEffect(left: leftward ? 1 : 0, right: leftward ? 0 : 1, blurPoints: 32, feather: 0.12, opaque: false, shield: false, wholeScreen: true)
                let full = bytes(try view.renderOffscreen(width: width, height: height))
                for offset in stride(from: 3, to: full.count, by: 4) {
                    precondition(full[offset] == 255, "Completed whole-screen sweep must cover every pixel, including both edges")
                }
            }
            view.setEffect(left: 0.3, right: 0.7, blurPoints: 32, feather: 0.12, opaque: false, shield: false, wholeScreen: true)
            let reversalA = bytes(try view.renderOffscreen(width: width, height: height))
            view.setEffect(left: 0.301, right: 0.699, blurPoints: 32, feather: 0.12, opaque: false, shield: false, wholeScreen: true)
            let reversalB = bytes(try view.renderOffscreen(width: width, height: height))
            for offset in stride(from: 3, to: reversalA.count, by: 4) {
                precondition(abs(Int(reversalA[offset])-Int(reversalB[offset])) <= 5,
                             "Small reversal progress must never teleport the sweep")
            }
            // Compare pointer intervals directly with real shader alpha, including
            // reversals where both directional feathers contribute to coverage.
            for whole in [false,true] {
                for (l,r) in [(0.0,0.0),(0.0,0.03),(0.03,0.0),(0.0,0.25),(0.5,0.0),(0.0,0.75),(1.0,0.0),(0.47,0.47),(0.49,0.49),(0.3,0.7),(0.7,0.3)] {
                    view.setEffect(left:l,right:r,blurPoints:32,feather:0.12,opaque:false,shield:false,wholeScreen:whole)
                    let shader = bytes(try view.renderOffscreen(width:width,height:height))
                    let intervals = VeilInputGeometry.intervals(left:l,right:r,feather:0.12,wholeScreen:whole)
                    for x in 0..<width {
                        let position = (Double(x)+0.5)/Double(width)
                        let alpha = Int(pixel(shader,width,x,height/2)[3])
                        let blocked = intervals.contains { position > $0.lower && position < $0.upper }
                        // One byte around threshold is deliberately excluded because
                        // the shader attachment quantizes float alpha to 8 bits.
                        if alpha <= 11 { precondition(!blocked, "Clear shader pixels must allow pointer input") }
                        if alpha >= 14 { precondition(blocked, "Visible shader coverage must intercept pointer input") }
                    }
                }
            }
            print("PASS \(scale)x pointer regions match real GPU alpha for half/full sweep and reversal")
            print("PASS \(scale)x whole-screen: directional quarter/half/three-quarter sweep, mirror, clear/full endpoints, continuous reversal")
            print("PASS \(scale)x: transparent neutral, mirrored/monotonic feather, premultiplied alpha, opaque independence, full shield, image orientation")
        }
        // Exercise the actual capture-buffer path, not only CGImage preview upload.
        // Queue two distinct sources before drawing: only the newest may appear.
        let mailbox = VeilFrameMailbox()
        view.frameMailbox = mailbox
        view.rendersBaseImage = false
        view.sourcePixelScale = 1
        view.setEffect(left: 0, right: 1, blurPoints: 32, feather: 0.12, opaque: false, shield: false)
        let redFrame = try solidCaptureBuffer(width: 96, height: 64, bgra: 0xFFFF0000)
        let blueFrame = try solidCaptureBuffer(width: 96, height: 64, bgra: 0xFF0000FF)
        mailbox.put(redFrame)
        mailbox.put(blueFrame)
        let newest = bytes(try view.renderOffscreen(width: 96, height: 64))
        precondition(pixel(newest,96,90,32) == [255,0,0,255], "Capture must display newest queued frame without channel swapping")
        precondition(!mailbox.hasPending, "Rendering must consume the newest pending frame")
        for _ in 0..<8 {
            let idle = bytes(try view.renderOffscreen(width: 96, height: 64))
            precondition(idle == newest, "Idle capture must retain exact pixels without recursive darkening")
        }
        for frame in 0..<16 {
            let isRed = frame.isMultiple(of: 2)
            mailbox.put(isRed ? redFrame : blueFrame)
            let live = bytes(try view.renderOffscreen(width: 96, height: 64))
            precondition(pixel(live,96,90,32) == (isRed ? [0,0,255,255] : [255,0,0,255]),
                         "New capture pixels must fully replace previous source without trails")
            precondition(pixel(live,96,5,32) == [0,0,0,0], "Capture updates may not copy pixels onto the clear side")
        }
        // Reallocation after changed source dimensions may not use old-size levels.
        mailbox.put(try solidCaptureBuffer(width: 192, height: 128, bgra: 0xFF00FF00))
        let resized = bytes(try view.renderOffscreen(width: 96, height: 64))
        precondition(pixel(resized,96,90,32) == [0,255,0,255], "Resized capture must rebuild source and blur targets")
        view.releaseCapturedResources()
        print("PASS capture textures: newest-frame coalescing, idle retention, changing live pixels without trails, clear-side transparency, source resize")
        try await testDemandRendering()
        print("Synthetic render artifacts: \(output.path)")
    }
    @MainActor static func drainMainActor() async {
        for _ in 0..<8 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    @MainActor static func testDemandRendering() async throws {
        let view = VeilMetalView(frame: NSRect(x: 0, y: 0, width: 96, height: 64))
        guard let device = view.device else { throw VeilRenderError.unavailable("No test GPU") }
        precondition(view.isPaused && view.enableSetNeedsDisplay && view.framebufferOnly,
                     "Live views must use demand drawing with optimized display-only drawables")
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 96, height: 64, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
        guard let target = device.makeTexture(descriptor: descriptor) else { throw VeilRenderError.unavailable("No test target") }
        let waiting = VeilMetalView(frame: NSRect(x: 0, y: 0, width: 96, height: 64))
        waiting.setEffect(left: 0, right: 1, blurPoints: 32, feather: 0.12, opaque: false, shield: false)
        await drainMainActor()
        precondition(waiting.renderPendingOffscreen(to: target), "Waiting for first capture draws its placeholder once")
        await drainMainActor()
        let waitingRequests = waiting.redrawRequestCount
        precondition(!waiting.renderPendingOffscreen(to: target) && waiting.gaussianPassCount == 0,
                     "Missing first capture must not repeatedly submit a shield or unused blur")
        await drainMainActor()
        precondition(waiting.redrawRequestCount == waitingRequests, "No-first-frame placeholder must remain dormant")
        waiting.releaseCapturedResources()
        let initialRequests = view.redrawRequestCount
        let mailbox = VeilFrameMailbox()
        view.frameMailbox = mailbox
        let red = try solidCaptureBuffer(width: 96, height: 64, bgra: 0xFFFF0000)
        let blue = try solidCaptureBuffer(width: 96, height: 64, bgra: 0xFF0000FF)
        var firstFrames = 0
        view.onFirstFrame = { firstFrames += 1 }
        for _ in 0..<20 { mailbox.put(red); mailbox.put(blue) }
        await drainMainActor()
        precondition(view.redrawRequestCount == initialRequests + 1, "Burst capture arrival must coalesce to one redraw invalidation")
        precondition(view.renderPendingOffscreen(to: target), "A fresh neutral capture must present its first clear frame")
        precondition(firstFrames == 0, "First-frame success must wait for GPU completion")
        await drainMainActor()
        precondition(firstFrames == 1, "Neutral first-frame GPU completion must still establish capture readiness")
        precondition(view.sourceBlitCount == 0 && view.gaussianPassCount == 0,
                     "Neutral live frames must avoid source copying and Gaussian work")
        let requests = view.redrawRequestCount
        for _ in 0..<40 { mailbox.put(red); mailbox.put(blue) }
        await drainMainActor()
        precondition(view.redrawRequestCount == requests && !view.renderPendingOffscreen(to: target),
                     "Changing pixels under an unchanged transparent overlay must not request or submit redraws")
        view.setEffect(left: 0, right: 1, blurPoints: 32, feather: 0.12, opaque: false, shield: false)
        await drainMainActor()
        precondition(view.renderPendingOffscreen(to: target), "An effect change must awaken a demand-rendered view")
        await drainMainActor()
        precondition(view.sourceBlitCount == 1 && view.gaussianPassCount == 3,
                     "Visible blur must process only the newest deferred source once")
        var rendered = [UInt8](repeating: 0, count: 96*64*4)
        target.getBytes(&rendered, bytesPerRow: 96*4, from: MTLRegionMake2D(0,0,96,64), mipmapLevel: 0)
        precondition(pixel(rendered,96,90,32) == [255,0,0,255], "Resuming from neutral must display latest source, not old pixels")
        precondition(firstFrames == 1 && !view.renderPendingOffscreen(to: target), "Idle output must stay dormant after one readiness signal")
        view.setEffect(left: 0, right: 0.5, blurPoints: 32, feather: 0.12, opaque: false, shield: false)
        precondition(view.renderPendingOffscreen(to: target), "Head motion changes must redraw cached blur")
        await drainMainActor()
        precondition(view.gaussianPassCount == 3 && view.sourceBlitCount == 1, "Head-only updates must reuse source and cached blur")

        view.renderingEnabled = false
        mailbox.put(red)
        view.setEffect(left: 1, right: 0, blurPoints: 32, feather: 0.12, opaque: false, shield: false)
        await drainMainActor()
        let hiddenRequests = view.redrawRequestCount
        precondition(!view.renderPendingOffscreen(to: target), "Hidden preview work must not submit")
        mailbox.put(blue)
        await drainMainActor()
        precondition(view.redrawRequestCount == hiddenRequests, "Hidden view must not invalidate display on incoming frames")
        view.renderingEnabled = true
        await drainMainActor()
        precondition(view.renderPendingOffscreen(to: target), "Revealing the view must redraw latest pending state")
        await drainMainActor()

        // Hold two real commands behind an event; the third update cannot
        // submit yet. Releasing the event must request that update again.
        guard let event = device.makeSharedEvent() else { throw VeilRenderError.unavailable("No test GPU event") }
        defer { event.signaledValue = 1 }
        view.setEffect(left: 0.7, right: 0, blurPoints: 32, feather: 0.12, opaque: false, shield: false)
        precondition(view.renderPendingOffscreen(to: target, waitingFor: event), "First blocked GPU submission")
        view.setEffect(left: 0.6, right: 0, blurPoints: 32, feather: 0.12, opaque: false, shield: false)
        precondition(view.renderPendingOffscreen(to: target, waitingFor: event), "Second blocked GPU submission")
        view.setEffect(left: 0.5, right: 0, blurPoints: 32, feather: 0.12, opaque: false, shield: false)
        precondition(!view.renderPendingOffscreen(to: target), "Two in-flight commands must bound GPU queue work")
        await drainMainActor()
        precondition(!view.renderPendingOffscreen(to: target), "A scheduled redraw while GPU is busy must preserve dirty state")
        let blockedRequests = view.redrawRequestCount
        event.signaledValue = 1
        for _ in 0..<25 {
            await drainMainActor()
            if view.redrawRequestCount > blockedRequests { break }
        }
        precondition(view.redrawRequestCount > blockedRequests, "Completion must request the update deferred by GPU backpressure")
        precondition(view.renderPendingOffscreen(to: target), "Newest deferred effect must submit after a slot becomes free")
        await drainMainActor()

        for opaque in [false, true] {
            view.setEffect(left: 0, right: 1, blurPoints: 32, feather: 0.12, opaque: opaque, shield: !opaque, wholeScreen: true)
            mailbox.put(red)
            let blits = view.sourceBlitCount, passes = view.gaussianPassCount
            precondition(view.renderPendingOffscreen(to: target), "Solid output must redraw on transition")
            await drainMainActor()
            precondition(view.sourceBlitCount == blits && view.gaussianPassCount == passes,
                         "Full shield and full opaque sweep must skip unused source and blur work")
        }
        // Late notifications and first-frame completions from a released
        // generation must not revive it or claim readiness for its successor.
        let late = VeilFrameMailbox()
        view.frameMailbox = late
        late.put(red)
        precondition(view.renderPendingOffscreen(to: target), "Queue first frame immediately before release")
        view.releaseCapturedResources()
        let releasedRequests = view.redrawRequestCount
        late.put(blue)
        await drainMainActor()
        precondition(firstFrames == 1 && view.redrawRequestCount == releasedRequests && !view.renderPendingOffscreen(to: target),
                     "Release must reject queued notifications, GPU readiness callbacks, and pending draws")
        precondition(!late.hasPending && view.frameMailbox == nil, "Release must discard retained deferred source")
        print("PASS demand renderer: coalesced frames, neutral/solid bypass, first-frame completion, latest-source reveal, hidden suspension, cached blur, bounded GPU retry, stale-generation release")
    }
    static func solidCaptureBuffer(width: Int, height: Int, bgra: UInt32) throws -> CVPixelBuffer {
        var image: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any], kCVPixelBufferMetalCompatibilityKey: true]
        guard CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_32BGRA,attributes as CFDictionary,&image) == kCVReturnSuccess,
              let image else { throw VeilRenderError.unavailable("Cannot create synthetic capture buffer") }
        CVPixelBufferLockBaseAddress(image, [])
        defer { CVPixelBufferUnlockBaseAddress(image, []) }
        let base = CVPixelBufferGetBaseAddress(image)!
        let rowBytes = CVPixelBufferGetBytesPerRow(image)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt32.self)
            for x in 0..<width { row[x] = bgra }
        }
        return image
    }
    static func bytes(_ image: CGImage) -> [UInt8] { Array(image.dataProvider!.data! as Data) }
    static func pixel(_ bytes: [UInt8], _ width: Int, _ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * width + x) * 4
        return Array(bytes[i..<i+4])
    }
    static func synthetic(width: Int, height: Int, inverted: Bool) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: inverted ? 0 : 1, alpha: 1)); context.fill(CGRect(x:0,y:0,width:width,height:height))
        let scale = CGFloat(width)/640
        context.scaleBy(x: scale, y: scale)
        for y in stride(from: 0, to: 400, by: 8) {
            for x in stride(from: 0, to: 640, by: 8) where ((x+y)/8).isMultiple(of: 2) {
                context.setFillColor(CGColor(gray: inverted ? 0.92 : 0.12, alpha: 1))
                context.fill(CGRect(x:x,y:y,width:8,height:8))
            }
        }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x:0,y:368,width:32,height:32))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x:0,y:0,width:32,height:32))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x:50,y:80,width:540,height:245))
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        ("AIRVEIL • LOCAL PREVIEW" as NSString).draw(at: NSPoint(x:65,y:270), withAttributes: [.font:NSFont.boldSystemFont(ofSize:25), .foregroundColor:NSColor.black])
        for i in 0..<9 { ("Small text 0123456789 — smooth directional obscuration" as NSString).draw(at:NSPoint(x:65,y:240-i*16),withAttributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:NSColor.black]) }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }
    static func save(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw VeilRenderError.unavailable("Cannot create PNG") }
        CGImageDestinationAddImage(destination,image,nil)
        if !CGImageDestinationFinalize(destination) { throw VeilRenderError.unavailable("Cannot write PNG") }
    }
}
