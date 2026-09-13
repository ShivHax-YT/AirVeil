import AppKit
import ImageIO
import UniformTypeIdentifiers

let output = CommandLine.arguments[1]
let size = 1024
let context = CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:size*4,
                        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(red:0.15,green:0.39,blue:0.89,alpha:1))
context.addPath(CGPath(roundedRect:CGRect(x:70,y:70,width:884,height:884),cornerWidth:200,cornerHeight:200,transform:nil))
context.fillPath()
context.setStrokeColor(CGColor(gray:1,alpha:1)); context.setLineWidth(42)
context.strokeEllipse(in:CGRect(x:268,y:268,width:488,height:488))
context.saveGState()
context.addEllipse(in:CGRect(x:268,y:268,width:488,height:488)); context.clip()
context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:230,y:230,width:282,height:564))
context.restoreGState()
let image = context.makeImage()!
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath:output) as CFURL,UTType.png.identifier as CFString,1,nil)!
CGImageDestinationAddImage(destination,image,nil)
if !CGImageDestinationFinalize(destination) { exit(1) }
