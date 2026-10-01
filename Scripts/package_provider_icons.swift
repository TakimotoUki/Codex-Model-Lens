import AppKit
import Foundation
let resources = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("ProviderIcons")
for provider in ["codex", "antigravity", "opencodego", "deepseek", "workbuddy"] {
    guard let image = NSImage(contentsOf: resources.appendingPathComponent(provider + ".svg")),
          let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("Missing provider glyph: " + provider) }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    let size = image.size; let scale = 112 / max(size.width, size.height)
    let width = size.width * scale, height = size.height * scale
    image.draw(in: NSRect(x: (128-width)/2, y: (128-height)/2, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: resources.appendingPathComponent(provider + ".png"))
}
