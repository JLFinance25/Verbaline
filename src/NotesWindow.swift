import Cocoa
import SwiftUI
import Combine

// NotesWindow
// -----------
// The meeting notetaker's window and its pop-up. No audio or AI code lives here: everything on screen comes from
// a NotesModel, and the buttons call closures the model was given (onStart, onStop, onAsk, onNotNow).
//
//     NotesModel               what the window shows (recording or not, live lines, time, past notes, answers)
//     NotesWindow.insightsView the Insights tab; another session supplies it, a placeholder until then
//     NotesWindowController    the window itself (show / close)
//     MeetingPopup             the small "Take notes for this meeting?" panel; goes away by itself after ~20 s
//
// Every colour, font and corner comes from Theme (see docs/design-system.md).

// MARK: - Model

final class NotesModel: ObservableObject {
    enum Tab: String, CaseIterable { case live = "Live meeting", past = "Past meetings", insights = "Insights" }

    struct Exchange: Identifiable {
        let id = UUID()
        let question: String
        var answer: String?          // nil while Verbaline is still working it out
    }

    /// Light / dark choice for the notes window and pop-up. "Auto" follows the Mac. Remembered between launches.
    enum Look: String, CaseIterable {
        case auto = "Auto", light = "Light", dark = "Dark"
        var appearance: NSAppearance? {
            switch self { case .auto: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) }
        }
        static let key = "notesWindowLook"
        static var saved: Look { Look(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .auto }
    }

    @Published var look: Look = Look.saved {
        didSet { UserDefaults.standard.set(look.rawValue, forKey: Look.key) }
    }
    @Published var tab: Tab = .live
    @Published var isRecording = false
    @Published var lines: [TranscriptLine] = []
    @Published var elapsed: TimeInterval = 0
    @Published var pastNotes: [MeetingNote] = []      // newest first
    @Published var openNote: MeetingNote?             // the note being read on the Past meetings tab
    @Published var exchanges: [Exchange] = []
    /// A short message under the tabs: "Writing your notes…", or what went wrong. nil = nothing to say.
    @Published var statusText: String?

    /// "Take notes" on the empty state: the owner starts a meeting.
    var onStart: () -> Void = {}
    var onStop: () -> Void = {}
    /// Answers a question from the live transcript (the summarizer's `answer`).
    var onAsk: (String) async -> String = { _ in "" }

    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let ex = Exchange(question: q, answer: nil)
        exchanges.append(ex)
        Task { @MainActor in
            let a = await onAsk(q)
            if let i = exchanges.firstIndex(where: { $0.id == ex.id }) { exchanges[i].answer = a }
        }
    }
}

enum NotesWindow {
    /// The Insights tab. Replace this with the real view once it exists.
    static var insightsView: AnyView = AnyView(InsightsPlaceholder()) { didSet { insightsViewReplaced = true } }
    /// True once someone has plugged in the real Insights view (the self-test reports it).
    private(set) static var insightsViewReplaced = false
}

private struct InsightsPlaceholder: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Insights").font(Theme.title(22)).foregroundColor(Theme.text)
            Text("Your numbers will show up here soon.").font(Theme.body).foregroundColor(Theme.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Helpers

private func clock(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

private func lengthText(_ t: TimeInterval) -> String {
    let m = max(1, Int((t / 60).rounded()))
    return m >= 60 ? "\(m / 60) hr \(m % 60) min" : "\(m) min"
}

private func dateText(_ d: Date, long: Bool = false) -> String {
    let f = DateFormatter()
    f.dateFormat = long ? "EEEE, MMMM d 'at' h:mm a" : "MMM d"
    return f.string(from: d)
}

private struct Pill: ViewModifier {
    var fill: Color
    func body(content: Content) -> some View {
        content.padding(.horizontal, 14).padding(.vertical, 7)
            .background(fill, in: Capsule())
            .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
    }
}

// MARK: - Window content

struct NotesRootView: View {
    @ObservedObject var model: NotesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabs
            if let status = model.statusText {
                Text(status).font(.system(size: 13)).foregroundColor(Theme.text)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Theme.card, in: Capsule())
                    .padding(.horizontal, Theme.pad + 6).padding(.top, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Group {
                switch model.tab {
                case .live: LiveMeetingView(model: model)
                case .past: PastMeetingsView(model: model)
                case .insights: NotesWindow.insightsView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.page)
    }

    private var header: some View {
        HStack {
            Text("Notes").font(Theme.title(30)).foregroundColor(Theme.text)
            Spacer()
            lookPicker
            if model.isRecording {
                HStack(spacing: 7) {
                    Circle().fill(Theme.red).frame(width: 8, height: 8)
                    Text("Recording \(clock(model.elapsed))").font(.system(size: 13)).foregroundColor(Theme.text)
                }
                .modifier(Pill(fill: Theme.card))
                Button(action: model.onStop) {
                    Text("Stop").font(.system(size: 13, weight: .medium)).foregroundColor(Theme.text)
                        .modifier(Pill(fill: Theme.raised))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.pad + 6).padding(.top, Theme.pad + 6).padding(.bottom, 10)
    }

    private var lookPicker: some View {
        HStack(spacing: 2) {
            ForEach(NotesModel.Look.allCases, id: \.self) { l in
                Button { model.look = l } label: {
                    Text(l.rawValue).font(.system(size: 12, weight: model.look == l ? .semibold : .regular))
                        .foregroundColor(model.look == l ? Theme.text : Theme.dim)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(model.look == l ? Theme.raised : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(l.rawValue) appearance")
            }
        }
        .padding(2).background(Theme.card, in: Capsule())
    }

    private var tabs: some View {
        HStack(spacing: 22) {
            ForEach(NotesModel.Tab.allCases, id: \.self) { t in
                Button { model.tab = t } label: {
                    VStack(spacing: 6) {
                        Text(t.rawValue).font(.system(size: 14, weight: model.tab == t ? .semibold : .regular))
                            .foregroundColor(model.tab == t ? Theme.text : Theme.dim)
                        Rectangle().fill(model.tab == t ? Theme.text : Color.clear).frame(height: 2)
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.rawValue)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.pad + 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

// MARK: - Live meeting

private struct LiveMeetingView: View {
    @ObservedObject var model: NotesModel
    @State private var draft = ""

    var body: some View {
        if !model.isRecording && model.lines.isEmpty {
            VStack(spacing: 14) {
                Text("Nothing being noted right now").font(Theme.title(22)).foregroundColor(Theme.text)
                Text("When you're in a meeting, Verbaline can listen and take notes for you.\nEverything stays on this Mac.")
                    .font(Theme.body).foregroundColor(Theme.dim).multilineTextAlignment(.center)
                Button(action: model.onStart) {
                    Text("Take notes").font(.system(size: 14, weight: .medium)).foregroundColor(Theme.page)
                        .padding(.horizontal, 22).padding(.vertical, 9)
                        .background(Theme.teal, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.gap) {
                            ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                                TranscriptBubble(line: line)
                            }
                            if model.isRecording {
                                Text("Listening…").font(Theme.title(15).italic()).foregroundColor(Theme.faint)
                            }
                            ForEach(model.exchanges) { ex in ExchangeView(ex: ex) }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(.horizontal, Theme.pad + 6).padding(.top, 16).padding(.bottom, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: model.lines.count) { withAnimation { proxy.scrollTo("end") } }
                    .onChange(of: model.exchanges.count) { withAnimation { proxy.scrollTo("end") } }
                    .onAppear { proxy.scrollTo("end") }
                }
                askBox
            }
        }
    }

    private var askBox: some View {
        HStack {
            TextField("Ask anything about this meeting", text: $draft)
                .textFieldStyle(.plain).font(Theme.body).foregroundColor(Theme.text)
                .onSubmit { model.ask(draft); draft = "" }
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(Theme.raised, in: Capsule())
        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
        .padding(.horizontal, Theme.pad + 6).padding(.vertical, 14)
    }
}

private struct TranscriptBubble: View {
    let line: TranscriptLine
    var body: some View {
        let you = line.speaker == .you
        VStack(alignment: .leading, spacing: 5) {
            Text(you ? "You" : "Them").font(Theme.caption).kerning(0.9).textCase(.uppercase)
                .foregroundColor(you ? Theme.violet : Theme.teal)
            Text(line.text).font(Theme.body).foregroundColor(you ? Theme.violetOnSoft : Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(you ? Theme.violetSoft : Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .frame(maxWidth: 520, alignment: .leading)
    }
}

private struct ExchangeView: View {
    let ex: NotesModel.Exchange
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ex.question).font(.system(size: 13)).foregroundColor(Theme.dim)
            Text(ex.answer ?? "Thinking…")
                .font(ex.answer == nil ? Theme.title(15).italic() : Theme.title(16))
                .foregroundColor(ex.answer == nil ? Theme.faint : Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }
}

// MARK: - Past meetings

private struct PastMeetingsView: View {
    @ObservedObject var model: NotesModel

    var body: some View {
        if let note = model.openNote {
            NoteDetailView(note: note) { model.openNote = nil }
        } else if model.pastNotes.isEmpty {
            VStack(spacing: 8) {
                Text("No notes yet").font(Theme.title(22)).foregroundColor(Theme.text)
                Text("Your finished meetings will show up here.").font(Theme.body).foregroundColor(Theme.dim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: Theme.gap) {
                    ForEach(Array(model.pastNotes.enumerated()), id: \.offset) { _, n in
                        Button { model.openNote = n } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(n.title).font(Theme.title(18)).foregroundColor(Theme.text)
                                Text("\(dateText(n.date)) · \(lengthText(n.duration)) · \(n.appName)")
                                    .font(.system(size: 13)).foregroundColor(Theme.dim)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .themeCard()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Theme.pad + 6)
            }
        }
    }
}

private struct NoteDetailView: View {
    let note: MeetingNote
    let back: () -> Void
    @State private var showTranscript = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gap + 4) {
                Button(action: back) {
                    Text("‹ All meetings").font(.system(size: 13)).foregroundColor(Theme.teal)
                }
                .buttonStyle(.plain)

                Text(note.title).font(Theme.title(32)).foregroundColor(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(dateText(note.date, long: true)) · \(lengthText(note.duration)) · \(note.appName)")
                    .font(.system(size: 13)).foregroundColor(Theme.dim)

                let top = Array(note.loanDetails.prefix(3))
                if !top.isEmpty {
                    HStack(spacing: Theme.gap) {
                        ForEach(Array(top.enumerated()), id: \.offset) { _, d in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(d.value).font(Theme.number(28)).foregroundColor(Theme.text)
                                    .lineLimit(1).minimumScaleFactor(0.6)
                                Text(d.label).themeCaption()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .themeCard()
                        }
                    }
                }

                section("Overview") {
                    Text(note.overview).font(Theme.title(16)).foregroundColor(Theme.text)
                        .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                }

                if !note.todos.isEmpty {
                    section("To do") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(note.todos.enumerated()), id: \.offset) { _, t in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(t.owner == .you ? "You" : "Them")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(t.owner == .you ? Theme.violetOnSoft : Theme.tealOnSoft)
                                        .padding(.horizontal, 9).padding(.vertical, 3)
                                        .background(t.owner == .you ? Theme.violetSoft : Theme.tealSoft, in: Capsule())
                                    Text(t.task).font(Theme.body).foregroundColor(Theme.text)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }

                let rest = Array(note.loanDetails.dropFirst(3))
                if !rest.isEmpty {
                    section("Loan details") {
                        VStack(spacing: 8) {
                            ForEach(Array(rest.enumerated()), id: \.offset) { _, d in
                                HStack {
                                    Text(d.label).font(Theme.body).foregroundColor(Theme.dim)
                                    Spacer()
                                    Text(d.value).font(Theme.body).foregroundColor(Theme.text)
                                }
                            }
                        }
                    }
                }

                DisclosureGroup(isExpanded: $showTranscript) {
                    VStack(alignment: .leading, spacing: Theme.gap) {
                        ForEach(Array(note.transcript.enumerated()), id: \.offset) { _, l in TranscriptBubble(line: l) }
                    }
                    .padding(.top, 10)
                } label: {
                    Text("Full transcript").font(.system(size: 14, weight: .medium)).foregroundColor(Theme.text)
                }
                .padding(.top, 4)
            }
            .padding(Theme.pad + 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).themeCaption()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard(padding: 18)
    }
}

// MARK: - Window

final class NotesWindowController {
    let model: NotesModel
    private(set) var window: NSWindow?
    private var lookWatcher: Any?

    init(model: NotesModel) { self.model = model }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 560, height: 480)
            w.contentView = NSHostingView(rootView: NotesRootView(model: model))
            w.center()
            w.appearance = model.look.appearance
            lookWatcher = model.$look.dropFirst().sink { [weak w] look in w?.appearance = look.appearance }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }
}

// MARK: - Pop-up

struct MeetingPopupView: View {
    let appName: String
    let notNow: () -> Void
    let takeNotes: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Take notes for this meeting?").font(Theme.title(18)).foregroundColor(Theme.text)
            Text("Looks like you're in a \(appName) meeting.").font(.system(size: 13)).foregroundColor(Theme.dim)
            Text("Make sure everyone's OK with notes being taken.").font(.system(size: 11)).foregroundColor(Theme.faint)
            HStack(spacing: 8) {
                Spacer()
                Button(action: notNow) {
                    Text("Not now").font(.system(size: 13)).foregroundColor(Theme.text).modifier(Pill(fill: Theme.raised))
                }.buttonStyle(.plain)
                Button(action: takeNotes) {
                    Text("Take notes").font(.system(size: 13, weight: .medium)).foregroundColor(Theme.page)
                        .padding(.horizontal, 14).padding(.vertical, 7).background(Theme.teal, in: Capsule())
                }.buttonStyle(.plain)
            }
            .padding(.top, 8)
        }
        .padding(18)
        .frame(width: 340)
        .background(Theme.page, in: RoundedRectangle(cornerRadius: Theme.windowRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.windowRadius).stroke(Theme.line, lineWidth: 1))
        .padding(12)   // room for the shadow
    }
}

final class MeetingPopup {
    static let visibleSeconds: TimeInterval = 20
    private(set) var panel: NSPanel?
    private var timer: Timer?

    /// Shows the pop-up near the top right of the main screen. `onDismiss` runs after "Not now" or the 20 s timeout.
    func show(appName: String, onTakeNotes: @escaping () -> Void, onNotNow: @escaping () -> Void = {}) {
        hide()
        let view = MeetingPopupView(appName: appName,
            notNow: { [weak self] in self?.hide(); onNotNow() },
            takeNotes: { [weak self] in self?.hide(); onTakeNotes() })
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        p.appearance = NotesModel.Look.saved.appearance
        if let s = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: s.maxX - size.width - 8, y: s.maxY - size.height - 8))
        }
        p.orderFrontRegardless()
        panel = p
        timer = Timer.scheduledTimer(withTimeInterval: Self.visibleSeconds, repeats: false) { [weak self] _ in
            self?.hide(); onNotNow()
        }
    }

    func hide() {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil); panel = nil
    }
}

// MARK: - Self-test

#if VERBALINE_TESTING
/// `open -W -n Verbaline.app --args --noteswindowtest outDir`: opens the window with sample data in light and dark,
/// saves screenshots into outDir/<light|dark>/, checks the window and tabs exist, and writes outDir/report.json.
enum NotesWindowTest {
    static func sampleNote() -> MeetingNote {
        let lines = [
            TranscriptLine(speaker: .them, start: 2, text: "Thanks for jumping on. We found a house we love, and the price is four fifty."),
            TranscriptLine(speaker: .you, start: 11, text: "Congratulations! With twenty percent down, that's ninety thousand. Does that work for you?"),
            TranscriptLine(speaker: .them, start: 20, text: "Yes, we've saved a bit more than that. What rate are you seeing today?"),
            TranscriptLine(speaker: .you, start: 28, text: "I'll send you a written quote this afternoon so you can compare."),
        ]
        return MeetingNote(
            title: "Purchase pre-approval chat", date: Date().addingTimeInterval(-3600 * 5), duration: 25 * 60 + 12,
            appName: "FaceTime",
            overview: "The Parkers found a home at $450,000 and plan to put 20% down. They have saved slightly more than needed and want to compare rates before choosing a lender. Jayden will send a written quote today, and the Parkers will send recent pay stubs and two months of bank statements.",
            todos: [MeetingTodo(owner: .you, task: "Send a written rate quote this afternoon"),
                    MeetingTodo(owner: .them, task: "Send recent pay stubs and two months of bank statements")],
            loanDetails: [.init(label: "Purchase price", value: "$450k"), .init(label: "Down payment", value: "$90k"),
                          .init(label: "Loan type", value: "30-year fixed"), .init(label: "Credit score", value: "Around 740"),
                          .init(label: "Closing date", value: "Early December")],
            transcript: lines)
    }

    static func run(outDir: String) {
        var r: [String: Any] = [:]
        // The test flips the light/dark switch, which is remembered; put the user's own choice back afterwards.
        let savedLook = UserDefaults.standard.object(forKey: NotesModel.Look.key)
        let model = NotesModel()
        model.onAsk = { q in "They plan to put 20% down, which is $90,000." }
        let note = sampleNote()
        model.lines = note.transcript
        model.elapsed = 12 * 60 + 41
        model.isRecording = true
        model.exchanges = [.init(question: "How much are they putting down?", answer: "They plan to put 20% down, which is $90,000.")]
        model.pastNotes = [note, {
            var n = sampleNote(); n.title = "Refinance questions"; n.appName = "zoom.us"; n.duration = 14 * 60
            n.date = Date().addingTimeInterval(-86400 * 2); return n }()]

        let ctl = NotesWindowController(model: model)
        ctl.show()
        let w = ctl.window!
        r["windowExists"] = true
        r["tabCount"] = NotesModel.Tab.allCases.count
        r["tabNames"] = NotesModel.Tab.allCases.map { $0.rawValue }
        r["insightsViewReplaced"] = NotesWindow.insightsViewReplaced   // false until the Insights session plugs in; not a failure yet

        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.6)) }
        func snap(_ view: NSView, _ path: String) -> Bool {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return false }
            return (try? png.write(to: URL(fileURLWithPath: path))) != nil
        }

        for mode in ["light", "dark"] {
            let dir = "\(outDir)/\(mode)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            model.look = mode == "dark" ? .dark : .light   // the same switch the user presses
            let cv = w.contentView!
            model.isRecording = true; model.openNote = nil
            model.tab = .live; settle()
            r["\(mode).live"] = snap(cv, "\(dir)/live.png")
            model.isRecording = false; model.lines = []; model.exchanges = []; settle()
            r["\(mode).empty"] = snap(cv, "\(dir)/live-empty.png")
            model.lines = note.transcript; model.isRecording = true
            model.tab = .past; settle()
            r["\(mode).past"] = snap(cv, "\(dir)/past-list.png")
            model.openNote = note; settle()
            r["\(mode).note"] = snap(cv, "\(dir)/past-note.png")
            model.openNote = nil
            model.tab = .insights; settle()
            r["\(mode).insights"] = snap(cv, "\(dir)/insights.png")

            let popup = MeetingPopup()
            popup.show(appName: "FaceTime", onTakeNotes: {})
            settle()
            if let pv = popup.panel?.contentView { r["\(mode).popup"] = snap(pv, "\(dir)/popup.png") }
            r["\(mode).popupExists"] = popup.panel != nil
            popup.hide()
        }
        r["lookSwitchChangesWindow"] = w.appearance?.name == .darkAqua
        model.look = .auto
        r["autoFollowsMac"] = w.appearance == nil
        r["popupAutoDismissSeconds"] = MeetingPopup.visibleSeconds
        if let savedLook { UserDefaults.standard.set(savedLook, forKey: NotesModel.Look.key) }
        else { UserDefaults.standard.removeObject(forKey: NotesModel.Look.key) }

        if let data = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: "\(outDir)/report.json"))
        }
        exit(0)
    }
}
#endif
