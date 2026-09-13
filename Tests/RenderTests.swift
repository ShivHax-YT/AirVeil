import AppKit
import ImageIO
import UniformTypeIdentifiers

@main struct RenderTests {
    @MainActor static func main() throws {
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
            let neutral = try view.renderOffscreen(width: width, height: height)
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
            let shieldBytes = bytes(try view.renderOffscreen(width: width, height: height))
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
            print("PASS \(scale)x: transparent neutral, mirrored/monotonic feather, premultiplied alpha, opaque independence, full shield, image orientation")
        }
        print("Synthetic render artifacts: \(output.path)")
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
