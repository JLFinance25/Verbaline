import Cocoa
import SwiftUI

// MeetingNotes
// ------------
// Connects the notetaker's pieces: MeetingDetector notices a meeting -> MeetingPopup asks -> MeetingRecorder records
// You and Them -> MeetingTranscriber writes live lines into the NotesModel -> on stop, MeetingSummarizer writes the
// note and MeetingStore saves it to ~/Documents/Verbaline Notes. Audio is never written to disk.
//
//     MeetingNotes(transcribe:)   transcribe = the app's Whisper engine
//     start()                     begin watching for meetings (the pop-up)
//     openWindow()                show the Notes window
//     toggleRecording()           start notes now / stop them (the ⌃⌘N shortcut)
//     saveIfRecording()           on quit: keep the transcript even though there's no time to summarise
//     askWhenMeetingStarts        settings: show the pop-up (default on)
//     loanDetails                 settings: include the Loan details section (default on)

final class MeetingNotes {
    let model = NotesModel()
    private lazy var window = NotesWindowController(model: model)
    private let popup = MeetingPopup()
    private let detector = MeetingDetector()
    private let summarizer = MeetingSummarizer()
    private let store = MeetingStore()
    private let transcribe: MeetingTranscriber.Transcribe

    private var recorder: MeetingRecorder?
    private var transcriber: MeetingTranscriber?
    private var pump: Timer?
    private var clock: Timer?
    private var app: MeetingApp?
    private var startedAt = Date()
    private var startedUptime: TimeInterval = 0
    private var onSpeakers = false        // no headphones: the mic also hears Them, so echoes are removed
    private var pumping = false
    private var dismissedApp: String?     // "Not now" for this meeting: don't ask again until it ends

    /// Called with a short message for the menu bar pill ("Notes started", "Couldn't start notes: …").
    var onNotice: (String) -> Void = { _ in }

    private let defaults = UserDefaults.standard
    var askWhenMeetingStarts: Bool {
        get { defaults.object(forKey: "meetingAskOnStart") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "meetingAskOnStart") }
    }
    var loanDetails: Bool {
        get { defaults.object(forKey: "meetingLoanDetails") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "meetingLoanDetails") }
    }
    var isRecording: Bool { recorder != nil }

    init(transcribe: @escaping MeetingTranscriber.Transcribe) {
        self.transcribe = transcribe
        NotesWindow.insightsView = AnyView(InsightsView())
        model.onStart = { [weak self] in self?.startRecording(app: nil) }
        model.onStop = { [weak self] in self?.stopRecording() }
        model.onAsk = { [weak self] q in
            guard let self else { return "" }
            let lines = await MainActor.run { self.model.lines }
            return await self.summarizer.answer(q, from: lines)
        }
        reloadPastNotes()
    }

    func start() {
        detector.onStart = { [weak self] app in self?.meetingStarted(app) }
        detector.onEnd = { [weak self] in self?.meetingEnded() }
        detector.start()
    }

    func openWindow() {
        reloadPastNotes()
        window.show()
    }

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording(app: nil); window.show() }
    }

    // MARK: detector

    private func meetingStarted(_ app: MeetingApp) {
        guard !isRecording, askWhenMeetingStarts, dismissedApp != app.name else { return }
        popup.show(appName: app.name,
                   onTakeNotes: { [weak self] in self?.startRecording(app: app); self?.window.show() },
                   onNotNow: { [weak self] in self?.dismissedApp = app.name })
    }

    private func meetingEnded() {
        popup.hide()
        dismissedApp = nil
        // Only stop by itself when it was following a meeting app; a manual "Mac" recording stops by hand.
        if isRecording, app?.name != Self.wholeMac { stopRecording() }
    }

    // MARK: recording

    static let wholeMac = "Mac"

    /// Which app to record when started by hand: the meeting app if there is one, else everything playing sound.
    private func appToRecord() -> MeetingApp {
        if let current = detector.current ?? MeetingDetector.appsUsingMic().first { return current }
        let playing = MeetingDetector.apps(from: AudioProcess.all(), usingMicOnly: false)
        return MeetingApp(name: Self.wholeMac, bundleID: nil, pids: playing.flatMap(\.pids))
    }

    private func startRecording(app requested: MeetingApp?) {
        guard !isRecording else { return }
        popup.hide()
        let app = requested ?? appToRecord()
        let rec = MeetingRecorder()
        rec.onHearingThemChanged = { [weak self] on in
            if !on { self?.onNotice("Can't hear the other side right now — retrying") }
        }
        do {
            try rec.start(app: app)
        } catch {
            onNotice("Couldn't start notes: \(error.localizedDescription)")
            model.statusText = "Couldn't start notes: \(error.localizedDescription)"
            window.show()
            return
        }
        self.app = app
        recorder = rec
        transcriber = MeetingTranscriber(transcribe: transcribe)
        onSpeakers = AudioRecorder.defaultOutputIsBuiltIn()
        startedAt = Date()
        startedUptime = ProcessInfo.processInfo.systemUptime
        model.lines = []
        model.exchanges = []
        model.elapsed = 0
        model.statusText = nil
        model.isRecording = true
        model.tab = .live
        onNotice("Taking notes")
        pump = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.pumpAudio() }
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.model.elapsed = ProcessInfo.processInfo.systemUptime - self.startedUptime
        }
    }

    /// Every few seconds: hand new audio to the transcriber and show any new lines.
    private func pumpAudio() {
        guard !pumping, let recorder, let transcriber else { return }
        let audio = recorder.takeNew()
        guard !audio.you.isEmpty || !audio.them.isEmpty else { return }
        pumping = true
        Task { @MainActor [weak self] in
            let new = await transcriber.add(you: audio.you, them: audio.them)
            guard let self else { return }
            self.pumping = false
            self.show(new)
        }
    }

    private func show(_ new: [TranscriptLine]) {
        guard !new.isEmpty else { return }
        var lines = (model.lines + new).sorted { $0.start < $1.start }
        if onSpeakers { lines = MeetingTranscriber.removeEchoes(lines) }
        model.lines = lines
    }

    func stopRecording() {
        guard let recorder, let transcriber else { return }
        pump?.invalidate(); pump = nil
        clock?.invalidate(); clock = nil
        pumping = false
        let last = recorder.takeNew()
        recorder.stop()
        self.recorder = nil
        self.transcriber = nil
        model.isRecording = false
        model.statusText = "Meeting ended. Writing your notes…"
        popup.showEnded()
        let appName = app?.name ?? Self.wholeMac
        let date = startedAt
        let duration = ProcessInfo.processInfo.systemUptime - startedUptime
        let loan = loanDetails
        Task { [weak self] in
            guard let self else { return }
            let tail = await transcriber.add(you: last.you, them: last.them)
            let rest = tail + (await transcriber.finish())
            let lines = await MainActor.run { () -> [TranscriptLine] in
                self.show(rest)
                return self.model.lines
            }
            let note = await self.summarizer.summarize(lines, appName: appName, date: date, duration: duration, loanDetails: loan)
            let gaps = self.summarizer.lastGaps
            await MainActor.run { self.finished(note, gaps: gaps) }
        }
    }

    /// The note is written: save it, put it at the top of Past meetings, and clear the Live tab for the next meeting.
    private func finished(_ note: MeetingNote, gaps: MeetingSummarizer.Gaps) {
        let saved: Bool
        do {
            _ = try store.save(note, gaps: gaps)
            model.statusText = nil
            saved = true
        } catch {
            model.statusText = "Couldn't save the note: \(error.localizedDescription). It's open under Past meetings; copy it somewhere safe."
            saved = false
        }
        model.pastNotes.removeAll { $0.date == note.date }
        model.pastNotes.insert(note, at: 0)
        model.openNote = note
        model.tab = .past
        // A fresh start for the next meeting (only if one hasn't already begun while this note was being written).
        if !isRecording { model.lines = []; model.exchanges = []; model.elapsed = 0 }
        popup.showReady(title: saved ? "Your notes are ready" : "Couldn't save your notes",
                        detail: saved ? note.title : "They're open in the notes window; copy them somewhere safe.",
                        onOpen: { [weak self] in self?.window.show() })
    }

    /// Quitting mid-meeting: there's no time to summarise, so save the transcript so far.
    func saveIfRecording() {
        guard let recorder else { return }
        pump?.invalidate(); clock?.invalidate()
        recorder.stop()
        self.recorder = nil
        guard !model.lines.isEmpty else { return }
        let note = MeetingNote(title: "Meeting notes (unfinished)", date: startedAt,
                               duration: ProcessInfo.processInfo.systemUptime - startedUptime, appName: app?.name ?? Self.wholeMac,
                               overview: "Verbaline quit before this meeting ended, so there's no overview. The transcript so far is below.",
                               todos: [], loanDetails: [], transcript: model.lines)
        _ = try? store.save(note, gaps: [])
    }

    private func reloadPastNotes() {
        model.pastNotes = store.list().compactMap { store.load($0) }
    }
}
