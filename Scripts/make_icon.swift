import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
guard let image = NSImage(contentsOf: destination.deletingLastPathComponent().appendingPathComponent("AppIcon.png")) else {
    fatalError("Missing generated AppIcon.png")
}

func drawIcon(pixels: Int) -> Data {
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
