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

// MARK: - Logo ↔ pill morph (README animation)

extension Logo {
    /// One frame of the V turning into the dictation pill. `u` 0 = the logo, 1 = the pill showing dots.
    /// `wave` (11 heights in pill points, 2 = dot) makes the pill "talk" once it has formed.
    /// The trick: a thick line with round ends is a pill, so the V's corners slide flat into a line, the line
    /// thickens into the pill and turns from green to black, and the three bars glide down into the middle of
    /// the pill's eleven while the other eight grow in from the center out.
    /// `scale` 1 draws the pill 2.5x its on-screen size (README); 0.4 draws it at its real size (app start).
    /// `background` false leaves the rest see-through.
    static func morphImage(u rawU: CGFloat, wave: [CGFloat]? = nil, size: NSSize = NSSize(width: 240, height: 150),
                           scale: CGFloat = 1, background: Bool = true) -> NSImage {
        func clamp(_ x: CGFloat) -> CGFloat { min(1, max(0, x)) }
        func ease(_ x: CGFloat) -> CGFloat { let x = clamp(x); return x * x * (3 - 2 * x) }   // smoothstep
        func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
        func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
            let a = a.usingColorSpace(.sRGB)!, b = b.usingColorSpace(.sRGB)!
            return NSColor(srgbRed: lerp(a.redComponent, b.redComponent, t), green: lerp(a.greenComponent, b.greenComponent, t),
                           blue: lerp(a.blueComponent, b.blueComponent, t), alpha: lerp(a.alphaComponent, b.alphaComponent, t))
        }
        let u = clamp(rawU)
        return NSImage(size: size, flipped: true) { rect in
            if background { Theme.logoPage.setFill(); rect.fill() }
            let m = full, s: CGFloat = 1.6 * scale, k: CGFloat = 2.5 * scale   // logo scale, pill scale
            let cx = rect.midX, cy = rect.midY
            func logoPt(_ p: CGPoint) -> CGPoint { CGPoint(x: cx + (p.x - 48) * s, y: cy + (p.y - 49) * s) }

            // 1. The V flattens into a line, then thickens into the pill and turns black.
            let flat = ease(u / 0.6), thick = ease((u - 0.35) / 0.65)
            let half = (64 - 24) / 2 * k                               // pill: 64 x 24 points
            let lineEnds = [CGPoint(x: cx - half, y: cy), CGPoint(x: cx, y: cy), CGPoint(x: cx + half, y: cy)]
            let path = NSBezierPath()
            for i in 0..<3 {
                let a = logoPt(m.v[i]), b = lineEnds[i]
                let p = CGPoint(x: lerp(a.x, b.x, flat), y: lerp(a.y, b.y, flat))
                i == 0 ? path.move(to: p) : path.line(to: p)
            }
            path.lineWidth = lerp(m.vWidth * s, 24 * k, thick)
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            mix(Theme.logoV, NSColor(white: 0.07, alpha: 1), thick).setStroke()
            path.stroke()

            // 2. Bars: the logo's three become the pill's middle three; the other eight grow in.
            let mapped: [Int: Int] = [5: 0, 4: 1, 6: 2]              // pill bar → logo bar
            for i in 0..<11 {
                let px = cx + CGFloat(i - 5) * 4 * k                  // pill bar x (2 pt bar + 2 pt gap)
                var h = (wave?[i] ?? 2) * k
                let grown = min(1, ((wave?[i] ?? 2) - 2) / 5)
                var w = (2 + 0.5 * grown) * k
                var x = px, y = cy
                var color = NSColor(white: 1, alpha: 0.6 + 0.32 * grown)
                var alpha: CGFloat = 1
                if let j = mapped[i] {
                    let b = m.bars[j], move = ease((u - 0.15) / 0.7)
                    let lx = cx + (b.x - 48) * s, ly = cy + ((b.top + b.bottom) / 2 - 49) * s
                    x = lerp(lx, px, move); y = lerp(ly, cy, move)
                    w = lerp(m.barWidth * s, w, move); h = lerp((b.bottom - b.top) * s, h, move)
                    color = mix(Theme.logoBars, color, move)
                } else {
                    let grow = ease((u - 0.55 - 0.05 * CGFloat(abs(i - 5))) / 0.3)
                    w *= grow; h *= grow; alpha = grow
                }
                guard alpha > 0.01, w > 0.1 else { continue }
                color.withAlphaComponent(color.alphaComponent * alpha).setFill()
                let r = CGRect(x: x - w / 2, y: y - h / 2, width: w, height: max(h, w))
                NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2).fill()
            }
            return true
        }
    }
}

/// Plays the logo → pill morph once, where the dictation pill appears (bottom center of the screen with the
/// mouse), then fades away: Verbaline's "I'm on" moment at launch. About 1.5 s. Main thread only.
final class LaunchMorph {
    private var panel: NSPanel?
    private var timer: Timer?
    private let size = NSSize(width: 110, height: 70)

    func play() {
        let mouse = NSEvent.mouseLocation
        guard let screen = (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main) else { return }
        let f = screen.visibleFrame
        // Same spot as the pill: its center sits 30 pt above the bottom of the usable screen.
        let p = NSPanel(contentRect: NSRect(x: f.midX - size.width / 2, y: f.minY + 30 - size.height / 2,
                                            width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true; p.level = .statusBar
        p.backgroundColor = .clear; p.isOpaque = false; p.hasShadow = false
        p.ignoresMouseEvents = true; p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSImageView(frame: NSRect(origin: .zero, size: size))
        view.imageScaling = .scaleNone
        p.contentView = view
        panel = p
        let start = CACurrentMediaTime()
        let draw: (CGFloat) -> Void = { [size] u in
            view.image = Logo.morphImage(u: u, size: size, scale: 0.4, background: false)
        }
        draw(0)
        p.alphaValue = 0
        p.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            let e = CACurrentMediaTime() - start
            switch e {
            case ..<0.15:  p.alphaValue = CGFloat(e / 0.15)                 // fade the logo in
            case ..<0.45:  p.alphaValue = 1                                 // show the logo
            case ..<1.35:  draw(CGFloat((e - 0.45) / 0.9))                  // V → pill
            case ..<1.65:  draw(1)                                          // pill with its dots
            case ..<1.95:  p.alphaValue = CGFloat(1 - (e - 1.65) / 0.3)     // fade away
            default:
                t.invalidate()
                p.orderOut(nil)
                self?.panel = nil
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
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
