import Cocoa
import SwiftUI

// MenuPanel
// ---------
// The panel that opens when you left-click the menu bar icon: status, how to talk, today's numbers,
// the last dictation (copy / paste again), quick toggles, and shortcuts. Everything else lives in the
// full settings menu (right-click the icon, or the gear here).
//
// The app owns a PanelModel, fills it in `refresh`, and handles the callbacks. The view only draws it.

final class PanelModel: ObservableObject {
    enum Status { case loading, ready, listening, working, needsSetup }

    struct Warning: Identifiable { let id: String; let text: String; let fix: () -> Void }
    struct Toggle: Identifiable { let id: String; let label: String; let icon: String; var on: Bool }

    @Published var status: Status = .loading
    @Published var statusText = "Loading"
    @Published var warnings: [Warning] = []
    @Published var wordsToday = 0
    @Published var lastSpeed: Double?          // seconds from releasing fn to the text appearing
    @Published var lastText: String?
    @Published var lastDate: Date?
    @Published var recent: [String] = []
    @Published var showHistory = false
    @Published var toggles: [Toggle] = []
    @Published var copiedFlash = false

    var onToggle: (String) -> Void = { _ in }
    var onCopyLast: () -> Void = {}
    var onPasteLast: () -> Void = {}
    var onCopyRecent: (String) -> Void = { _ in }
    var onWords: () -> Void = {}
    var onSnippets: () -> Void = {}
    var onSettings: () -> Void = {}
    var onQuit: () -> Void = {}
    var onHistory: () -> Void = {}
    var onNotes: () -> Void = {}
    @Published var notesEnabled = false
}

/// A borderless floating window placed right under the menu bar icon and kept on screen.
/// (NSPopover was replaced: with this SwiftUI content it opened upward over the menu bar.)
/// It never takes focus from the app you're typing in, so "paste again" lands there.
final class PanelWindow {
    private let window: NSPanel
    private let host: NSHostingView<AnyView>
    private var anchor: NSRect = .zero
    private var outsideClick: Any?
    var onClose: () -> Void = {}
    /// Off only in the self-test, so the tester's own clicks elsewhere can't close it mid-test.
    var closesOnOutsideClick = true

    init(model: PanelModel) {
        host = NSHostingView(rootView: AnyView(PanelView(model: model)))
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isFloatingPanel = true
        window.level = .popUpMenu
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.contentView = host
    }

    var isShown: Bool { window.isVisible }
    var windowNumber: Int { window.windowNumber }
    var frame: NSRect { window.frame }

    /// `iconFrame` is the status item button's frame in screen coordinates.
    func show(below iconFrame: NSRect) {
        anchor = iconFrame
        removeOutsideClick()
        fit()
        window.orderFrontRegardless()
        guard closesOnOutsideClick else { return }
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    func close() {
        removeOutsideClick()   // even if the window was already hidden some other way
        guard window.isVisible else { return }
        window.orderOut(nil)
        onClose()
    }

    private func removeOutsideClick() {
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        outsideClick = nil
    }

    /// Sizes the window to its content and puts its top 6 pt under the icon, nudged sideways to stay on screen.
    func fit() {
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let top = min(anchor.minY - 6, visible.maxY)
        let y = max(top - size.height, visible.minY + 8)
        window.setFrame(NSRect(x: x, y: y, width: size.width, height: min(size.height, top - visible.minY - 8)), display: true)
    }
}

struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            header
            ForEach(model.warnings) { w in warningRow(w) }
            HStack(spacing: Theme.gap) {
                stat("Today", model.wordsToday.formatted(), "words")
                stat("Speed", model.lastSpeed.map { String(format: "%.1f s", $0) } ?? "—", "to paste")
            }
            lastCard
            if model.showHistory { historyCard }
            chips
            Divider().overlay(Theme.line).padding(.top, 2)
            footer
        }
        .padding(Theme.pad)
        .frame(width: 330)
        .background(Theme.page)
        .clipShape(RoundedRectangle(cornerRadius: Theme.windowRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.windowRadius).strokeBorder(Theme.line, lineWidth: 1))
        .foregroundStyle(Theme.text)
    }

    // MARK: pieces

    private var header: some View {
        HStack {
            LogoMark(size: 24)
            Text("Verbaline").font(Theme.title(22))
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(model.statusText).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(statusBackground, in: Capsule())
            .foregroundStyle(statusText)
        }
        .padding(.horizontal, 4).padding(.bottom, 2)
    }

    private var statusColor: Color {
        switch model.status {
        case .ready: return Theme.teal
        case .listening: return Theme.red
        case .working, .loading: return Theme.amber
        case .needsSetup: return Theme.red
        }
    }

    private var statusBackground: Color {
        model.status == .ready ? Theme.tealSoft : statusColor.opacity(0.16)
    }

    private var statusText: Color {
        model.status == .ready ? Theme.tealOnSoft : statusColor
    }

    private func warningRow(_ w: PanelModel.Warning) -> some View {
        Button(action: w.fix) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.red)
                Text(w.text).font(.system(size: 12)).multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.dim)
            }
            .padding(12)
            .background(Theme.red.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func stat(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).themeCaption()
            Text(value).font(Theme.number(32)).monospacedDigit()
            Text(unit).font(.system(size: 12)).foregroundStyle(Theme.teal)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
    }

    private var lastCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(lastLabel).themeCaption()
                Spacer()
                if model.lastText != nil {
                    iconButton(model.copiedFlash ? "checkmark" : "doc.on.doc", help: "Copy", action: model.onCopyLast)
                    iconButton("arrow.uturn.left.circle", help: "Paste again (⌃⌘V)", action: model.onPasteLast)
                }
            }
            Text(model.lastText ?? "Your dictations will show up here.")
                .font(.system(size: 14)).lineLimit(3)
                .foregroundStyle(model.lastText == nil ? Theme.faint : Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
    }

    private var lastLabel: String {
        guard let d = model.lastDate else { return "Last dictation" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return "Last dictation · " + f.localizedString(for: d, relativeTo: Date())
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent — click to copy").themeCaption().padding(.bottom, 6)
            if model.recent.isEmpty {
                Text("Nothing yet").font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
            ForEach(Array(model.recent.enumerated()), id: \.offset) { _, text in
                Button { model.onCopyRecent(text) } label: {
                    Text(text).font(.system(size: 12)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
    }

    private var chips: some View {
        // Two rows of two: wraps cleanly at this width without a flow layout.
        let rows = stride(from: 0, to: model.toggles.count, by: 2).map { Array(model.toggles[$0..<min($0 + 2, model.toggles.count)]) }
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 8) {
                    ForEach(rows[r]) { t in chip(t) }
                }
            }
        }
    }

    private func chip(_ t: PanelModel.Toggle) -> some View {
        Button { model.onToggle(t.id) } label: {
            HStack(spacing: 5) {
                Image(systemName: t.icon).font(.system(size: 11))
                Text(t.label).font(.system(size: 12))
                Spacer(minLength: 0)
                if t.on { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(t.on ? Theme.violetSoft : Theme.card, in: Capsule())
            .foregroundStyle(t.on ? Theme.violetOnSoft : Theme.dim)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(t.on ? "\(t.label) is on — click to turn off" : "\(t.label) is off — click to turn on")
    }

    private var footer: some View {
        HStack(spacing: 0) {   // tight so six buttons (with Notes) still fit on one line each
            footerButton("character.book.closed", "Words", model.onWords)
            footerButton("bolt", "Snippets", model.onSnippets)
            footerButton("clock.arrow.circlepath", "History", model.onHistory)
            // Meeting notes on: Notes (meetings + Insights). Off: Insights only.
            if model.notesEnabled { footerButton("note.text", "Notes", model.onNotes) }
            else { footerButton("chart.bar", "Insights", model.onNotes) }
            footerButton("gearshape", "Settings", model.onSettings)
            footerButton("power", "Quit", model.onQuit)
        }
    }

    private func footerButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 15))
                Text(label).font(.system(size: 10.5)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(Theme.dim)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Theme.dim).frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

extension PanelView {
    /// Renders the panel to an image (self-test / screenshots), with no window on screen.
    @MainActor static func render(_ model: PanelModel, scale: CGFloat = 2, scheme: ColorScheme = .light) -> NSImage? {
        let renderer = ImageRenderer(content: PanelView(model: model).environment(\.colorScheme, scheme))
        renderer.scale = scale
        return renderer.nsImage
    }
}
