import AppKit

let size = 1024
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)!

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

let tile = NSBezierPath(roundedRect: NSRect(x: 96, y: 96, width: 832, height: 832),
                        xRadius: 185, yRadius: 185)
NSGradient(starting: color(0x8159bd), ending: color(0x4a2d79))!.draw(in: tile, angle: -55)
let inset = NSBezierPath(roundedRect: NSRect(x: 113, y: 113, width: 798, height: 798),
                         xRadius: 168, yRadius: 168)
NSColor.white.withAlphaComponent(0.18).setStroke()
inset.lineWidth = 4
inset.stroke()

let page = NSBezierPath()
page.move(to: NSPoint(x: 365, y: 770))
page.line(to: NSPoint(x: 594, y: 770))
page.line(to: NSPoint(x: 715, y: 650))
page.line(to: NSPoint(x: 715, y: 310))
page.curve(to: NSPoint(x: 674, y: 269), controlPoint1: NSPoint(x: 715, y: 285),
           controlPoint2: NSPoint(x: 699, y: 269))
page.line(to: NSPoint(x: 365, y: 269))
page.curve(to: NSPoint(x: 324, y: 310), controlPoint1: NSPoint(x: 340, y: 269),
           controlPoint2: NSPoint(x: 324, y: 285))
page.line(to: NSPoint(x: 324, y: 729))
page.curve(to: NSPoint(x: 365, y: 770), controlPoint1: NSPoint(x: 324, y: 754),
           controlPoint2: NSPoint(x: 340, y: 770))
page.close()
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = color(0x2b164c).withAlphaComponent(0.4)
shadow.shadowOffset = NSSize(width: 0, height: -18)
shadow.shadowBlurRadius = 34
shadow.set()
color(0xfaf5ff).setFill()
page.fill()
NSGraphicsContext.restoreGraphicsState()

let fold = NSBezierPath()
fold.move(to: NSPoint(x: 594, y: 770))
fold.line(to: NSPoint(x: 715, y: 650))
fold.line(to: NSPoint(x: 617, y: 650))
fold.curve(to: NSPoint(x: 594, y: 673), controlPoint1: NSPoint(x: 604, y: 650),
           controlPoint2: NSPoint(x: 594, y: 660))
fold.close()
color(0xdcc9f4).setFill()
fold.fill()

for (y, width, hex) in [(565.0, 201.0, 0x7950b6 as UInt32),
                        (480.0, 235.0, 0x258879 as UInt32),
                        (395.0, 153.0, 0xaf5a35 as UInt32)] {
    color(hex).setFill()
    NSBezierPath(roundedRect: NSRect(x: 400, y: y, width: width, height: 31),
                 xRadius: 15.5, yRadius: 15.5).fill()
}
NSGraphicsContext.restoreGraphicsState()

func iconChunk(_ type: String, _ payload: Data) -> Data {
    var result = Data(type.utf8)
    var length = UInt32(payload.count + 8).bigEndian
    withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
    result.append(payload)
    return result
}

let fullSize = bitmap.cgImage!
var variants = Data()
for (type, pixels) in [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128),
                       ("ic08", 256), ("ic09", 512), ("ic10", 1024)] {
    let canvas = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                           bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    canvas.interpolationQuality = .high
    canvas.draw(fullSize, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let rep = NSBitmapImageRep(cgImage: canvas.makeImage()!)
    variants.append(iconChunk(type, rep.representation(using: .png, properties: [:])!))
}
try iconChunk("icns", variants).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
