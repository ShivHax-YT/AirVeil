import AppKit

@MainActor
enum PreviewArt {
    static let image: CGImage = make()
    private static func make() -> CGImage {
        let width = 1320, height = 560
        let context = CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width*4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor(calibratedRed:0.94,green:0.95,blue:0.97,alpha:1).cgColor)
        context.fill(CGRect(x:0,y:0,width:width,height:height))
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:false)
        func rect(_ r: CGRect,_ color:NSColor,_ radius:CGFloat = 0) {
            color.setFill(); NSBezierPath(roundedRect:r,xRadius:radius,yRadius:radius).fill()
        }
        func text(_ s:String,_ x:CGFloat,_ y:CGFloat,_ size:CGFloat,_ color:NSColor = .labelColor,_ weight:NSFont.Weight = .regular) {
            (s as NSString).draw(at:NSPoint(x:x,y:y),withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:color])
        }
        let ink = NSColor(calibratedWhite:0.12,alpha:1)
        rect(CGRect(x:30,y:30,width:1260,height:500),.white,22)
        for (i,c) in [NSColor.systemRed,.systemYellow,.systemGreen].enumerated() {
            rect(CGRect(x:58+i*26,y:491,width:14,height:14),c,7)
        }
        text("Workspace",564,484,19,.gray,.medium)
        rect(CGRect(x:30,y:30,width:226,height:430),NSColor(calibratedWhite:0.97,alpha:1))
        text("MY SPACE",56,420,15,.gray,.semibold)
        text("Overview",56,375,21,ink,.semibold)
        text("Documents",56,327,20,.gray)
        text("Messages",56,279,20,.gray)
        text("Your next idea",300,412,38,ink,.bold)
        text("A little focus. A little room to think.",302,373,22,.gray)
        let lines = ["Keep the details of your work close.","Plan the next chapter, shape a new idea,", "and make space for what matters today."]
        for (i,l) in lines.enumerated() { text(l,302,314-CGFloat(i)*34,20,ink) }
        rect(CGRect(x:302,y:90,width:408,height:78),NSColor(calibratedRed:0.89,green:0.94,blue:1,alpha:1),14)
        text("Today’s notes",326,130,18,ink,.semibold)
        text("Three small steps toward something new.",326,102,16,.gray)
        rect(CGRect(x:790,y:80,width:448,height:350),NSColor(calibratedRed:0.12,green:0.29,blue:0.53,alpha:1),16)
        rect(CGRect(x:822,y:116,width:384,height:196),NSColor(calibratedRed:0.23,green:0.53,blue:0.71,alpha:1),12)
        text("ROOM TO FOCUS",825,368,16,.white,.semibold)
        text("Make it yours.",824,324,30,.white,.bold)
        for i in 0..<9 {
            rect(CGRect(x:845+i*39,y:138,width:22,height:38+i*12),NSColor(calibratedWhite:1,alpha:0.75),5)
        }
        NSGraphicsContext.current = previous
        return context.makeImage()!
    }
}
