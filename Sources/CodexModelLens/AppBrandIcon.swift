import SwiftUI
import AppKit

/// One full-color brand asset for every application surface.
struct AppBrandIcon: View {
    var size: CGFloat = 32
    private static let image = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        .flatMap(NSImage.init(contentsOf:)) ?? NSApp.applicationIconImage!
    var body: some View {
        Image(nsImage: Self.image).resizable().scaledToFit()
            .frame(width: size, height: size).accessibilityLabel("Codex Model Lens")
    }
}

/// The same robot/lens motif, reduced to a crisp native menu-bar template.
@MainActor enum MenuBarBrandIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.white.setStroke()
            func stroke(_ path: NSBezierPath, width: CGFloat = 1.25) {
                path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
            }
            func line(_ from: NSPoint, _ to: NSPoint, width: CGFloat = 1.25) {
                let path = NSBezierPath(); path.move(to: from); path.line(to: to); stroke(path, width: width)
            }
            stroke(NSBezierPath(ovalIn: NSRect(x: 5.4, y: 6.0, width: 11, height: 11)), width: 1.45)
            line(NSPoint(x: 14.8, y: 7.7), NSPoint(x: 18.6, y: 3.9), width: 1.65)
            stroke(NSBezierPath(roundedRect: NSRect(x: 8.0, y: 9.0, width: 5.8, height: 4.6), xRadius: 1.6, yRadius: 1.6))
            line(NSPoint(x: 10.9, y: 13.6), NSPoint(x: 10.9, y: 14.6))
            line(NSPoint(x: 9.8, y: 10.6), NSPoint(x: 9.8, y: 11.7), width: 1.0)
            line(NSPoint(x: 12.0, y: 10.6), NSPoint(x: 12.0, y: 11.7), width: 1.0)
            for y: CGFloat in [7.0, 11.4, 15.8] { line(NSPoint(x: 1.4, y: y), NSPoint(x: 3.4, y: y)) }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Codex Model Lens"
        return image
    }()
}
