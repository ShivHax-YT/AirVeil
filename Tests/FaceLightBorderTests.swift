import AppKit

@main @MainActor struct FaceLightBorderTests {
    static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for size in [CGSize(width: 1440, height: 900), CGSize(width: 900, height: 600)] {
            let rect = CGRect(origin: .zero, size: size)
            let geometry = FaceLightGeometry(bounds: rect)
            let ring = geometry.path
            precondition(!ring.contains(CGPoint(x: rect.midX, y: rect.midY)))
            precondition(!ring.contains(.zero))
            let band = (geometry.outer.maxY + geometry.inner.maxY) / 2
            precondition(ring.contains(CGPoint(x: rect.midX, y: band)))
            precondition(abs((geometry.outerRadius - geometry.innerRadius) - (geometry.inner.minX - geometry.outer.minX)) < 0.01)
            let view = FaceLightBorder(frame: rect)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            view.draw(rect)
            NSGraphicsContext.restoreGraphicsState()
            let center = bitmap.colorAt(x: Int(size.width/2), y: Int(size.height/2))!
            precondition(center.alphaComponent < 0.01, "Center must stay transparent")
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("edge-light-\(Int(size.width)).png"))
        }
        print("PASS: Rounded light frame, concentric corners, transparent center, and two native renders; no display illumination")
    }
}
