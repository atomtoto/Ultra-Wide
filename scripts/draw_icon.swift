import AppKit

// Code-native app mark: overlapping photographic frames and an expanded horizon.
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                              bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(srgbRed: 0.035, green: 0.065, blue: 0.068, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()
let mint = NSColor(srgbRed: 0.73, green: 0.94, blue: 0.77, alpha: 1)
for (index, x) in [220.0, 350.0, 480.0].enumerated() {
    let rect = NSRect(x: x, y: 315, width: 324, height: 410)
    let p = NSBezierPath(roundedRect: rect, xRadius: 46, yRadius: 46)
    mint.withAlphaComponent(CGFloat(index + 1) / 3).setStroke(); p.lineWidth = 13; p.stroke()
}
let horizon = NSBezierPath(); horizon.move(to: NSPoint(x: 162, y: 463))
horizon.line(to: NSPoint(x: 357, y: 463)); horizon.line(to: NSPoint(x: 445, y: 553))
horizon.line(to: NSPoint(x: 545, y: 412)); horizon.line(to: NSPoint(x: 636, y: 495))
horizon.line(to: NSPoint(x: 862, y: 495)); horizon.lineWidth = 21; horizon.lineJoinStyle = .round
mint.setStroke(); horizon.stroke()
mint.setFill(); NSBezierPath(ovalIn: NSRect(x: 612, y: 610, width: 39, height: 39)).fill()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
