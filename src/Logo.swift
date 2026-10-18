import Cocoa
import SwiftUI

// Logo
// ----
// Verbaline's mark: a wide, heavy V (teal) with sound bars standing inside it (violet).
// The app icon and the in-app mark show the V with its bars; the menu bar version has three bars
// and is a single-colour "template" image, so macOS tints it for light and dark menu bars.
// Shapes are written once, on a fixed grid, and drawn at any size.

enum Logo {
    /// One piece of the mark, on a grid `size` units wide and tall (y goes down).
    struct Mark {
        let size: CGFloat
        let v: [CGPoint]            // the V's three corner points
        let vWidth: CGFloat
        let barWidth: CGFloat
        let bars: [(x: CGFloat, top: CGFloat, bottom: CGFloat)]
    }

    /// Wide V with three bars, on a 96 grid: app icon and panel.
    static let full = Mark(size: 96, v: [CGPoint(x: 12, y: 22), CGPoint(x: 48, y: 76), CGPoint(x: 84, y: 22)],
                           vWidth: 12, barWidth: 7,
                           bars: [(48, 24, 57), (38, 24, 42), (58, 24, 42)])
    /// The same, tuned to stay readable at menu bar size, on a 28 grid.
    static let menuBar = Mark(size: 28, v: [CGPoint(x: 3, y: 6.5), CGPoint(x: 14, y: 22), CGPoint(x: 25, y: 6.5)],
                              vWidth: 3, barWidth: 3.2,
                              bars: [(14, 6, 16.3), (9.2, 6, 10), (18.8, 6, 10)])

    /// Draws a mark into `rect` (flipped coordinates, y down).
    static func draw(_ m: Mark, in rect: CGRect, vColor: NSColor, barColor: NSColor) {
        let s = rect.width / m.size
        func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: rect.minX + p.x * s, y: rect.minY + p.y * s) }
        let path = NSBezierPath()
        path.move(to: pt(m.v[0])); path.line(to: pt(m.v[1])); path.line(to: pt(m.v[2]))
        path.lineWidth = m.vWidth * s
        path.lineCapStyle = .round; path.lineJoinStyle = .round
        vColor.setStroke(); path.stroke()
        barColor.setFill()
        for b in m.bars {
            let r = CGRect(x: rect.minX + (b.x - m.barWidth / 2) * s, y: rect.minY + b.top * s,
                           width: m.barWidth * s, height: (b.bottom - b.top) * s)
            NSBezierPath(roundedRect: r, xRadius: m.barWidth * s / 2, yRadius: m.barWidth * s / 2).fill()
        }
    }

    /// The menu bar icon: one colour (black), marked as a template so macOS tints it.
    static func menuBarImage(points: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: points, height: points), flipped: true) { rect in
            draw(menuBar, in: rect, vColor: .black, barColor: .black)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The app icon at `pixels` square: cream rounded square with the mark, with the usual margin around it.
    static func appIconImage(pixels: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: pixels, height: pixels), flipped: true) { rect in
            let tile = rect.insetBy(dx: rect.width * 0.098, dy: rect.height * 0.098)
            let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.2237, yRadius: tile.width * 0.2237)
            Theme.logoPage.setFill(); shape.fill()
            Theme.logoLine.setStroke(); shape.lineWidth = max(1, rect.width / 512); shape.stroke()
            draw(full, in: tile, vColor: Theme.logoV, barColor: Theme.logoBars)
            return true
        }
        return image
    }
}

/// The mark in the panel header, in the app's own teal and violet (follows light and dark mode).
struct LogoMark: View {
    var size: CGFloat = 24
    var body: some View {
        Canvas { ctx, canvas in
            let m = Logo.full, s = canvas.width / m.size
            var v = Path()
            v.move(to: CGPoint(x: m.v[0].x * s, y: m.v[0].y * s))
            v.addLine(to: CGPoint(x: m.v[1].x * s, y: m.v[1].y * s))
            v.addLine(to: CGPoint(x: m.v[2].x * s, y: m.v[2].y * s))
            ctx.stroke(v, with: .color(Theme.teal),
                       style: StrokeStyle(lineWidth: m.vWidth * s, lineCap: .round, lineJoin: .round))
            for b in m.bars {
                let r = CGRect(x: (b.x - m.barWidth / 2) * s, y: b.top * s, width: m.barWidth * s, height: (b.bottom - b.top) * s)
                ctx.fill(Path(roundedRect: r, cornerRadius: m.barWidth * s / 2), with: .color(Theme.violet))
            }
        }
        .frame(width: size, height: size)
    }
}
