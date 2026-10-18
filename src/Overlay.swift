import Cocoa
import SwiftUI

/// The little floating pill at the bottom of the screen.
final class OverlayModel: ObservableObject {
    enum Badge: Equatable { case fixed, learned, command }

    enum Phase: Equatable {
        case hidden
        case listening(handsFree: Bool)
        case listeningCommand          // fn+Control held: speaking an instruction for the selected text
        case processing
        case working(String)           // dots + a short label, e.g. "Rewriting…"
        case message(String)
        case badge(Badge, String)   // small icon + text: "✓ Fixed …", "✨ Learned …"
    }
    @Published var phase: Phase = .hidden
    @Published var levels: [CGFloat] = Array(repeating: 0.05, count: 10)
    /// False until your voice is first heard in this recording: the pill shows a calm line of dots until then,
    /// and bars from then on (like Wispr Flow's pill).
    @Published var heardVoice = false
    /// Your voice level, smoothed (0...1). The wave reads it every screen frame and glides toward it.
    var level: CGFloat = 0
    /// Drives the fade in and out (the panel itself stays put until the fade-out finishes).
    @Published var visible = false

    /// Smoothed so the bars breathe with your voice instead of jumping between flat and full: they rise at
    /// 35% and fall at 15% of the gap per update and top out at 70% height.
    private var smoothed: CGFloat = 0
    private var loudUpdates = 0

    /// Above this (about -43 dB, the recorder's 0...1 scale) for two updates in a row counts as your voice.
    static let voiceLevel: Float = 0.3

    func push(_ level: Float) {
        if !heardVoice {
            loudUpdates = level > Self.voiceLevel ? loudUpdates + 1 : 0
            if loudUpdates >= 2 { heardVoice = true }
        }
        let target = CGFloat(level)
        smoothed += (target - smoothed) * (target > smoothed ? 0.35 : 0.15)
        self.level = smoothed
        var l = levels
        l.removeFirst()
        l.append(max(0.05, smoothed * 0.7))
        levels = l
    }

    func resetLevels() {
        smoothed = 0; loudUpdates = 0; heardVoice = false; level = 0
        levels = Array(repeating: 0.05, count: levels.count)
    }
}

final class OverlayController {
    let model = OverlayModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?
    private let size = NSSize(width: 340, height: 40)   // transparent canvas; the pill hugs its content

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: OverlayView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
    }

    func show(_ phase: OverlayModel.Phase) {
        hideWork?.cancel()
        let startsListening: Bool
        switch phase {
        case .listening, .listeningCommand: startsListening = true
        default: startsListening = false
        }
        if startsListening, model.phase == .hidden || model.phase == .processing { model.resetLevels() }
        let wasHidden = !model.visible
        model.phase = phase
        if wasHidden { position() }
        panel.orderFrontRegardless()
        if wasHidden {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) { model.visible = true }
        }
    }

    /// Fades out over 0.16 s, then removes the panel (unless something was shown again meanwhile).
    func hide() {
        hideWork?.cancel()
        guard model.visible else { model.phase = .hidden; panel.orderOut(nil); return }
        withAnimation(.easeIn(duration: 0.16)) { model.visible = false }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.model.visible else { return }
            self.model.phase = .hidden
            self.panel.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    func flash(_ text: String, seconds: Double = 1.8) {
        flash(.message(text), seconds: seconds)
    }

    func flash(_ phase: OverlayModel.Phase, seconds: Double) {
        show(phase)
        let work = DispatchWorkItem { [weak self] in self?.hide() }   // hide() then fades out
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 10))
    }
}

extension OverlayController {
    /// Renders the pill for a phase to an image, off screen (used by `--renderpill`).
    @MainActor static func renderPreview(_ phase: OverlayModel.Phase, heardVoice: Bool = true, scale: CGFloat = 2) -> NSImage? {
        PillWave.freezeForPreview = true
        defer { PillWave.freezeForPreview = false }
        let model = OverlayModel()
        model.phase = phase
        model.visible = true
        model.level = 0.55
        if case .listening = phase { model.levels = [0.2, 0.5, 0.8, 0.6, 0.9, 0.4, 0.7, 0.3, 0.6, 0.2]; model.heardVoice = heardVoice }
        let renderer = ImageRenderer(content: OverlayView(model: model).frame(width: 340, height: 40)
            .background(Color(white: 0.93)))
        renderer.scale = scale
        return renderer.nsImage
    }
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        content
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(Color.black.opacity(0.88)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
            .scaleEffect(model.visible ? 1 : 0.9)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(model.visible ? 1 : 0)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .hidden:
            EmptyView()
        case .listening(let handsFree):
            HStack(spacing: 6) {
                if handsFree {
                    Circle().fill(Color.red).frame(width: 5, height: 5)
                }
                PillWave(model: model, working: false)
            }
        case .listeningCommand:
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(red: 0.75, green: 0.62, blue: 1.0))
                PillWave(model: model, working: false)
            }
        case .processing:
            // Same pill, same shapes: the bars settle back into dots and a small spinner fades in on the right.
            PillWave(model: model, working: true)
        case .working(let label):
            HStack(spacing: 7) {
                Spinner()
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
            }
        case .message(let text):
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
        case .badge(let kind, let text):
            HStack(spacing: 5) {
                Image(systemName: kind == .fixed ? "checkmark.circle.fill" : kind == .learned ? "sparkles" : "wand.and.stars")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(kind == .fixed ? Color(red: 0.35, green: 0.85, blue: 0.5)
                                                    : Color(red: 0.75, green: 0.62, blue: 1.0))
                Text(kind == .fixed ? "Fixed" : kind == .learned ? "Learned" : "Done")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                Text(text)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}


/// One row of 11 shapes that are dots at rest and bars when you speak, so nothing ever swaps: dots grow into
/// bars, bars settle back into dots. Every screen frame each shape glides toward its target height
/// (exponential easing, faster up than down). Bars are tallest in the middle with a slight sway, rather than
/// scrolling sideways. While working, the right-hand dots fade out as a spinner fades in.
struct PillWave: View {
    @ObservedObject var model: OverlayModel
    let working: Bool
    @State private var state = WaveMotion()

    static let count = 11
    static let width: CGFloat = 44   // 11 shapes, 2 pt gaps
    /// Previews render one still frame, so they show the final pose instead of easing toward it.
    nonisolated(unsafe) static var freezeForPreview = false
    static let dot: CGFloat = 2, tallest: CGFloat = 14

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let h = state.step(t: t, level: model.heardVoice && !working ? model.level : 0, freeze: PillWave.freezeForPreview)
            ZStack(alignment: .trailing) {
                HStack(spacing: 2) {
                    ForEach(0..<Self.count, id: \.self) { i in
                        let grown = min(1, (h[i] - Self.dot) / 5)
                        Capsule()
                            .fill(Color.white.opacity((working ? 0.35 : 0.6) + 0.32 * grown))
                            .frame(width: Self.dot + 0.5 * grown, height: h[i])
                            .opacity(working && i >= Self.count - 3 ? 0 : 1)
                    }
                }
                Spinner().opacity(working ? 1 : 0)
            }
            .frame(width: PillWave.width, height: Self.tallest)
            .animation(.easeOut(duration: 0.2), value: working)
        }
    }
}

/// Per-frame state for PillWave (a class, so updating it doesn't redraw the view by itself).
final class WaveMotion {
    private var heights = [CGFloat](repeating: PillWave.dot, count: PillWave.count)
    private var lastT: TimeInterval = 0

    func step(t: TimeInterval, level: CGFloat, freeze: Bool) -> [CGFloat] {
        let dt = lastT == 0 ? 1.0 / 60 : min(0.1, t - lastT)
        lastT = t
        let mid = CGFloat(PillWave.count - 1) / 2
        for i in 0..<PillWave.count {
            let distance = abs(CGFloat(i) - mid) / mid                       // 0 middle … 1 edge
            let envelope = 0.35 + 0.65 * cos(distance * .pi / 2)             // tallest in the middle
            let sway = 0.78 + 0.22 * CGFloat(sin(t * 7.0 + Double(i) * 1.9)) // gentle, never still
            let target = level <= 0.02 ? PillWave.dot
                : PillWave.dot + (PillWave.tallest - PillWave.dot) * min(1, level * 1.35) * envelope * sway
            if freeze { heights[i] = target; continue }                     // previews: final pose
            let rate: Double = target > heights[i] ? 22 : 9                 // rise quickly, fall gently
            heights[i] += (target - heights[i]) * CGFloat(1 - exp(-dt * rate))
        }
        return heights
    }
}



/// A small turning arc, shown while the text is being written.
private struct Spinner: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: 9, height: 9)
                .rotationEffect(.degrees((t * 360).truncatingRemainder(dividingBy: 360)))
        }
        .frame(width: 10, height: 10)
    }
}


// MARK: - Still frames for the README animation

/// One still frame of the pill, drawn from explicit values instead of the live clock, so an animation can be
/// exported frame by frame (`Verbaline --rendershowcase`). Uses the same sizes and colors as the real pill.
struct PillFrame: View {
    var heights: [CGFloat]          // 11 shape heights (2 = dot)
    var working = false
    var spinnerDegrees: Double = 0
    var visibility: Double = 1      // 0…1, the fade and slight grow

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 2) {
                ForEach(0..<PillWave.count, id: \.self) { i in
                    let grown = min(1, (heights[i] - PillWave.dot) / 5)
                    Capsule()
                        .fill(Color.white.opacity((working ? 0.35 : 0.6) + 0.32 * grown))
                        .frame(width: PillWave.dot + 0.5 * grown, height: heights[i])
                        .opacity(working && i >= PillWave.count - 3 ? 0 : 1)
                }
            }
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: 9, height: 9)
                .rotationEffect(.degrees(spinnerDegrees))
                .frame(width: 10, height: 10)
                .opacity(working ? 1 : 0)
        }
        .frame(width: PillWave.width, height: PillWave.tallest)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(Color.black.opacity(0.88)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
        .scaleEffect(0.9 + 0.1 * visibility)
        .opacity(visibility)
    }
}
