// The VoxDesk logo, drawn in code so it stays sharp at every size: a shell prompt chevron followed by
// voice bars, "speech into the terminal", on an indigo-to-coral tile.
import AppKit

enum Logo {
    static let barHeights: [CGFloat] = [0.30, 0.62, 0.95, 0.55, 0.78, 0.36]

    /// The glyph alone, filling `rect`, in `color`.
    static func drawGlyph(in rect: NSRect, color: NSColor, bars: [CGFloat] = barHeights, chevron: Bool = true) {
        let s = min(rect.width, rect.height)
        let ox = rect.minX + (rect.width - s) / 2, oy = rect.minY + (rect.height - s) / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * s, y: oy + y * s) }
        color.setStroke(); color.setFill()

        var x: CGFloat = 0.08
        if chevron {
            let c = NSBezierPath()
            c.lineWidth = 0.085 * s
            c.lineCapStyle = .round
            c.lineJoinStyle = .round
            c.move(to: p(0.08, 0.68)); c.line(to: p(0.25, 0.50)); c.line(to: p(0.08, 0.32))
            c.stroke()
            x = 0.38
        }
        let barWidth: CGFloat = 0.072
        let gap = (0.94 - x - barWidth * CGFloat(bars.count)) / CGFloat(max(bars.count - 1, 1))
        for h in bars {
            let height = max(h, 0.1) * 0.78
            let r = NSRect(x: ox + x * s, y: oy + (0.5 - height / 2) * s, width: barWidth * s, height: height * s)
            NSBezierPath(roundedRect: r, xRadius: barWidth * s / 2, yRadius: barWidth * s / 2).fill()
            x += barWidth + gap
        }
    }

    /// The full app icon tile at `size` points.
    static func appIcon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            // macOS icon grid: the tile is about 80% of the canvas, with a soft shadow.
            let inset = r.width * 0.1
            let tile = r.insetBy(dx: inset, dy: inset)
            let radius = tile.width * 0.225
            let path = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowOffset = NSSize(width: 0, height: -r.width * 0.012)
            shadow.shadowBlurRadius = r.width * 0.03
            shadow.set()
            NSColor.black.setFill(); path.fill()
            NSGraphicsContext.restoreGraphicsState()

            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.16, blue: 0.55, alpha: 1),
                                NSColor(srgbRed: 0.55, green: 0.24, blue: 0.80, alpha: 1),
                                NSColor(srgbRed: 1.00, green: 0.45, blue: 0.47, alpha: 1)])!
                .draw(in: tile, angle: -35)
            NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
                .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
            NSGraphicsContext.restoreGraphicsState()

            drawGlyph(in: tile.insetBy(dx: tile.width * 0.14, dy: tile.height * 0.14), color: .white)
            return true
        }
    }

    /// A template image for the menu bar, so macOS tints it for light and dark. While listening the bars stand
    /// taller and a dot appears, so the state reads at a glance.
    static func menuBarIcon(listening: Bool = false) -> NSImage {
        let img = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { _ in
            let bars: [CGFloat] = listening ? [0.55, 0.95, 0.7, 1.0, 0.6] : [0.35, 0.7, 1.0, 0.6, 0.4]
            drawGlyph(in: NSRect(x: 0, y: -2.5, width: 21, height: 21), color: .black, bars: bars)
            if listening {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 18, y: 11.5, width: 4, height: 4)).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
