import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func drawIcon(pixels: Int) -> Data {
    let image = NSImage(size: NSSize(width: 1024, height: 1024))
    image.lockFocus()
    let box = NSRect(x: 68, y: 68, width: 888, height: 888)
    let path = NSBezierPath(roundedRect: box, xRadius: 206, yRadius: 206)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.15)
    shadow.shadowBlurRadius = 38; shadow.shadowOffset = NSSize(width: 0, height: -16); shadow.set()
    NSColor.white.setFill(); path.fill()
    NSGraphicsContext.restoreGraphicsState()
    let gradient = NSGradient(colors: [NSColor(red: 0.94, green: 0.97, blue: 1.00, alpha: 1),
                                      NSColor(red: 0.66, green: 0.83, blue: 1.00, alpha: 1),
                                      NSColor(red: 0.15, green: 0.48, blue: 0.95, alpha: 1)])!
    gradient.draw(in: path, angle: -65)
    NSColor.white.withAlphaComponent(0.75).setStroke(); path.lineWidth = 6; path.stroke()
    let inset = NSBezierPath(roundedRect: NSRect(x: 188, y: 188, width: 648, height: 648), xRadius: 145, yRadius: 145)
    NSColor.white.withAlphaComponent(0.18).setFill(); inset.fill()
    NSColor.white.withAlphaComponent(0.6).setStroke(); inset.lineWidth = 3; inset.stroke()
    let ink = NSColor(red: 0.04, green: 0.21, blue: 0.48, alpha: 1)
    ink.setStroke()
    let corners = NSBezierPath(); corners.lineWidth = 31; corners.lineCapStyle = .round; corners.lineJoinStyle = .round
    for (x, y, dx, dy) in [(300.0, 300.0, 1.0, 1.0), (724, 300, -1, 1), (300, 724, 1, -1), (724, 724, -1, -1)] {
        corners.move(to: NSPoint(x: x + dx * 87, y: y))
        corners.line(to: NSPoint(x: x, y: y))
        corners.line(to: NSPoint(x: x, y: y + dy * 87))
    }
    corners.stroke()
    let lens = NSBezierPath(ovalIn: NSRect(x: 395, y: 395, width: 234, height: 234))
    NSColor.white.withAlphaComponent(0.28).setFill(); lens.fill()
    ink.setStroke(); lens.lineWidth = 23; lens.stroke()
    let focus = NSBezierPath(ovalIn: NSRect(x: 485, y: 485, width: 54, height: 54))
    ink.setFill(); focus.fill()
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try drawIcon(pixels: size).write(to: destination.appendingPathComponent("icon_\(size)x\(size).png"))
    try drawIcon(pixels: size * 2).write(to: destination.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

// ICNS is a big-endian container; its modern image elements contain PNG data.
// Write it directly so packaging does not depend on iconutil's image conversion service.
func bigEndian(_ value: UInt32) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
let elements: [(String, String)] = [
    ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"),
    ("ic12", "icon_32x32@2x.png"), ("ic13", "icon_128x128@2x.png"),
    ("ic14", "icon_256x256@2x.png")
]
var payload = Data()
for (type, filename) in elements {
    let image = try Data(contentsOf: destination.appendingPathComponent(filename))
    payload.append(Data(type.utf8)); payload.append(bigEndian(UInt32(image.count + 8))); payload.append(image)
}
var container = Data("icns".utf8)
container.append(bigEndian(UInt32(payload.count + 8))); container.append(payload)
try container.write(to: destination.deletingLastPathComponent().appendingPathComponent("AppIcon.icns"))
