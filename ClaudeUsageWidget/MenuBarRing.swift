import AppKit

/// The menu bar's color ring: a small circle that fills with usage (or with what's left) in the limit's color.
/// It is drawn as a regular image rather than a template, so macOS keeps its color in the menu bar.
enum MenuBarRing {
    static func image(fraction: Double, tint: RGB?, size: CGFloat = 16) -> NSImage {
        let color = tint.map { NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1) } ?? NSColor.systemGray
        let amount = CGFloat(min(max(fraction, 0), 1))
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let lineWidth: CGFloat = 2.6
            let circle = rect.insetBy(dx: lineWidth / 2 + 1, dy: lineWidth / 2 + 1)
            let track = NSBezierPath(ovalIn: circle)
            track.lineWidth = lineWidth
            // A gray that shows on both light and dark menu bars.
            NSColor(white: 0.5, alpha: 0.45).setStroke()
            track.stroke()
            if amount > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: circle.midX, y: circle.midY), radius: circle.width / 2,
                              startAngle: 90, endAngle: 90 - 360 * amount, clockwise: true)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                color.setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
