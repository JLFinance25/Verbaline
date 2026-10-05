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
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 10)

    func push(_ level: Float) {
        var l = levels
        l.removeFirst()
        l.append(CGFloat(level))
        levels = l
    }

    func resetLevels() { levels = Array(repeating: 0, count: levels.count) }
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
        model.phase = phase
        position()
        panel.orderFrontRegardless()
    }

    func hide() {
        hideWork?.cancel()
        model.phase = .hidden
        panel.orderOut(nil)
    }

    func flash(_ text: String, seconds: Double = 1.8) {
        flash(.message(text), seconds: seconds)
    }

    func flash(_ phase: OverlayModel.Phase, seconds: Double) {
        show(phase)
        let work = DispatchWorkItem { [weak self] in self?.hide() }
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
    @MainActor static func renderPreview(_ phase: OverlayModel.Phase, scale: CGFloat = 2) -> NSImage? {
        let model = OverlayModel()
        model.phase = phase
        if case .listening = phase { model.levels = [0.2, 0.5, 0.8, 0.6, 0.9, 0.4, 0.7, 0.3, 0.6, 0.2] }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(model.phase == .hidden ? 0 : 1)
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
                LevelBars(levels: model.levels)
            }
        case .listeningCommand:
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(red: 0.75, green: 0.62, blue: 1.0))
                LevelBars(levels: model.levels)
            }
        case .processing:
            ProcessingDots()
        case .working(let label):
            HStack(spacing: 7) {
                ProcessingDots()
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

private struct LevelBars: View {
    let levels: [CGFloat]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 2.5, height: 2.5 + min(1, levels[i]) * 11)
            }
        }
        .frame(height: 14)
        .animation(.linear(duration: 0.08), value: levels)
    }
}

private struct ProcessingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.white)
                        .frame(width: 4, height: 4)
                        .opacity(0.25 + 0.75 * (0.5 + 0.5 * sin(t * 7 - Double(i) * 0.9)))
                }
            }
        }
    }
}
