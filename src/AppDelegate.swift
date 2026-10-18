import SwiftUI
import Cocoa
import AVFoundation
import ApplicationServices
import ServiceManagement
import Carbon

/// Hotkey gestures:
///   • Hold fn            → push-to-talk; release to transcribe.
///   • Double-tap fn      → hands-free; tap fn again to transcribe.
///   • Esc while recording → cancel.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Mode { case idle, pressed, awaitingSecondTap, pushToTalk, handsFree, processing }

    private let fn = FnKeyMonitor()
    private let recorder = AudioRecorder()
    private let transcriber = WhisperEngine()
    private let cleaner = TextCleaner()
    private let history = History()
    private lazy var dictionary = PersonalDictionary(
        fileURL: history.fileURL.deletingLastPathComponent().appendingPathComponent("dictionary.txt"))
    private lazy var snippets = Snippets(
        fileURL: history.fileURL.deletingLastPathComponent().appendingPathComponent("snippets.txt"))
    private let overlay = OverlayController()
    private let editWatcher = EditWatcher()
    private let typer = TextTyper()
    private var typingStoppedBySwitch = false
    private var lastLearned: [EditLearner.Correction] = []
    private var lastEditWatch = "not used yet"

    private var statusItem: NSStatusItem!
    private let panel = PanelModel()
    /// The meeting notetaker (MeetingNotes.swift). Uses the same Whisper engine as dictation.
    private lazy var meetings = MeetingNotes { [transcriber] samples in
        try await transcriber.transcribe(samples: samples, sampleRate: AudioRecorder.sampleRate)
    }
    private var panelWindow: PanelWindow?
    private var panelTimer: Timer?
    private let settingsMenu = NSMenu()
    private let ducker = MusicDucker()
    /// Sound was playing on the Mac's speakers when this recording started: use the stricter music gate.
    private var musicDuringRecording = false
    private var mode: Mode = .idle {
        didSet {
            updateStatusIcon()
            fn.swallowEscape = [.pressed, .awaitingSecondTap, .pushToTalk, .handsFree].contains(mode)
        }
    }
    private var fnDownAt: TimeInterval = 0
    // Latency timings for the current recording (system uptime / seconds), saved with it in history.
    private var recordingKeyAt: TimeInterval = 0   // when the fn press that started it reached Verbaline
    private var micStartCall: TimeInterval = 0     // how long starting the mic blocked the main thread
    private var swallowNextFnUp = false
    private var holdTimer: Timer?
    private var tapTimer: Timer?
    private var maxTimer: Timer?
    private var micWatchdog: Timer?
    /// A message to show after the current dictation is pasted (instead of just hiding the pill).
    private var pendingNotice: String?
    /// The current recording is a Command Mode instruction (fn+Control), not dictation.
    private var commandMode = false
    private var permissionTimer: Timer?
    private var hotKeys: [GlobalHotKey] = []
    private var engineStatus = "Loading speech model…"
    private var micAuthorized = false
    private var lastStatus: Data?
    private var lastStatusWrite = Date.distantPast

    // Tunables
    private let tapMax: TimeInterval = 0.40           // press shorter than this = a tap
    private let doubleTapWindow: TimeInterval = 0.50  // time allowed between the two taps
    private let comboGrace: TimeInterval = 1.0        // fn+key within this long of pressing fn = a shortcut, not dictation
    private let maxRecording: TimeInterval = 1200     // hard stop at 20 minutes

    private let defaults = UserDefaults.standard
    private var aiCleanup: Bool {
        get { defaults.object(forKey: "aiCleanup") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "aiCleanup") }
    }
    /// Apple voice processing on the mic + the speech-only gate that drops clicks and shrinks pauses.
    private var noiseFilter: Bool {
        get { defaults.object(forKey: "noiseFilter") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "noiseFilter") }
    }
    /// Record from the Mac's own mic so AirPods stay in full-quality music mode.
    private var useBuiltInMic: Bool {
        get { defaults.object(forKey: "useBuiltInMic") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "useBuiltInMic"); recorder.preferBuiltInMic = newValue }
    }
    /// Learn "heard → written" fixes from the user's own edits to pasted text.
    private var learnFromEdits: Bool {
        get { defaults.object(forKey: "learnFromEdits") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "learnFromEdits") }
    }
    /// Type dictation out as keystrokes instead of pasting (Command Mode results always paste).
    /// Saying just "press enter" presses Return. Never combined with pasting, so nothing is sent unchecked.
    private var pressEnterCommand: Bool {
        get { defaults.object(forKey: "pressEnterCommand") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "pressEnterCommand") }
    }
    private var typeOut: Bool {
        get { defaults.object(forKey: "typeOut") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "typeOut") }
    }
    private var typingSpeed: TextTyper.Speed {
        get { TextTyper.Speed(rawValue: defaults.string(forKey: "typingSpeed") ?? "") ?? .steady }
        set { defaults.set(newValue.rawValue, forKey: "typingSpeed") }
    }
    /// Keep what the Mac is playing (videos, music) out of dictation: turn speaker sound down while you talk,
    /// cancel it from the recording, and use the stricter music gate. Off = type whatever the mic hears,
    /// e.g. to transcribe a video playing out loud.
    private var ignoreMacAudio: Bool {
        get { defaults.object(forKey: "ignoreMacAudio") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "ignoreMacAudio") }
    }
    /// How far speaker sound is turned down while you talk (fraction of your volume; 0 = mute).
    private var duckLevel: Float {
        get { defaults.object(forKey: "duckLevel") as? Float ?? 0.5 }
        set { defaults.set(newValue, forKey: "duckLevel"); ducker.level = newValue }
    }
    /// End a dictation with "make this prompt better" to get it rewritten as a clearer AI prompt.
    private var promptCommand: Bool {
        get { defaults.object(forKey: "promptCommand") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "promptCommand") }
    }
    /// Meeting notes are off unless turned on: they haven't been tried on enough real calls yet, and
    /// recording calls can need everyone's consent. Turn on with:
    ///   defaults write <bundle id> meetingNotesEnabled -bool true
    /// Off = no meeting detection, no ⌃⌘N, no Notes button, no meeting settings.
    private var meetingNotesEnabled: Bool { defaults.bool(forKey: "meetingNotesEnabled") }
    private var soundsOn: Bool {
        get { defaults.object(forKey: "sounds") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "sounds") }
    }

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        VerbalinePaths.importOldSettings()   // before the dictionary and snippets files are first read
        setupStatusItem()

        recorder.onLevel = { [weak self] level in self?.overlay.model.push(level) }
        // No Apple echo cancellation: on a Mac it reprocesses everything playing on the speakers, which made
        // music sound thin. Speaker music is turned down while you talk instead (MusicDucker + music gate).
        recorder.noiseReduction = false
        ducker.level = duckLevel
        ducker.recoverAfterCrash()
        recorder.preferBuiltInMic = useBuiltInMic
        transcriber.vocabulary = dictionary.terms
        _ = snippets   // create (and seed) on the main thread before any background dictation reads it
        Stats.shared.backfill(from: history.items)   // first run only: Insights starts from saved history
        editWatcher.onEdited = { [weak self] pasted, edited in self?.learnFromEdit(pasted: pasted, edited: edited) }
        editWatcher.onStatus = { [weak self] line in
            self?.lastEditWatch = line
            self?.writeStatus()
        }
        fn.onFnDown = { [weak self] in self?.handleFnDown() }
        fn.onFnUp = { [weak self] in self?.handleFnUp() }
        fn.onKeyWhileFnHeld = { [weak self] in self?.handleKeyWhileFnHeld() }
        fn.onEscape = { [weak self] in self?.handleEscape() }
        fn.onControlWithFn = { [weak self] in self?.handleControlWithFn() }

        requestPermissions()
        startKeyMonitorWhenAllowed()
        writeStatus()
        let statusTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.writeStatus() }
        statusTimer.tolerance = 5
        // Confirm it's on: soft chime + tiny pill.
        play("Glass")
        overlay.flash("Verbaline on", seconds: 1.5)
        meetings.onNotice = { [weak self] text in self?.overlay.flash(text, seconds: 2) }
        if meetingNotesEnabled { meetings.start() }   // watches for meetings; asks before recording anything

        // ⌃⌘V pastes the last transcript, ⌃⌘C copies it.
        hotKeys = [
            GlobalHotKey(keyCode: kVK_ANSI_V, modifiers: cmdKey | controlKey, id: 1) { [weak self] in self?.pasteLastNow() },
            GlobalHotKey(keyCode: kVK_ANSI_C, modifiers: cmdKey | controlKey, id: 2) { [weak self] in self?.copyLast() },
            // ⌃⌘N starts or stops meeting notes.
            GlobalHotKey(keyCode: kVK_ANSI_N, modifiers: cmdKey | controlKey, id: 3) { [weak self] in if self?.meetingNotesEnabled == true { self?.meetings.toggleRecording() } },
        ]

        if ModelDownloader.isInstalled {
            loadSpeechModel()
        } else {
            engineStatus = Self.modelMissing   // the panel offers the download
        }
        cleaner.prewarm()
#if VERBALINE_TESTING
        if let i = CommandLine.arguments.firstIndex(of: "--paneltest"), i + 1 < CommandLine.arguments.count {
            runPanelTest(report: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }
#endif
    }

#if VERBALINE_TESTING
    /// `open -n Verbaline.app --args --paneltest out.json`: opens the real panel from the real status item,
    /// presses its toggle, history and close paths, and writes what happened. Settings are put back.
    private func runPanelTest(report: URL) {
        var r: [String: Any] = [:]
        panelWindow?.closesOnOutsideClick = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            togglePanel()
            r["shownAfterClick"] = panelWindow?.isShown ?? false
            r["windowNumber"] = panelWindow?.windowNumber ?? -1
            if let f = panelWindow?.frame, let b = statusItem.button, let bw = b.window {
                let icon = bw.convertToScreen(b.convert(b.bounds, to: nil))
                let visible = (NSScreen.screens.first { $0.frame.intersects(icon) } ?? NSScreen.main!).visibleFrame
                r["panelSize"] = "\(Int(f.width))x\(Int(f.height))"
                r["topIsBelowIcon"] = f.maxY <= icon.minY
                r["fullyOnScreen"] = visible.contains(f)
            }
            r["statusText"] = panel.statusText
            r["toggleCount"] = panel.toggles.count
            let before = soundsOn
            panel.onToggle("sounds")
            r["soundsToggleFlips"] = soundsOn != before && panel.toggles.first { $0.id == "sounds" }?.on == soundsOn
            panel.onToggle("sounds")
            r["soundsRestored"] = soundsOn == before
            let shortHeight = panelWindow?.frame.height ?? 0
            panel.onHistory()
            r["recentCount"] = panel.recent.count
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in   // time for a screenshot
                r["stillShownAfter1s"] = panelWindow?.isShown ?? false
                if let f = panelWindow?.frame, let b = statusItem.button, let bw = b.window {
                    let icon = bw.convertToScreen(b.convert(b.bounds, to: nil))
                    r["historyMakesItTaller"] = f.height > shortHeight
                    r["historyStillBelowIcon"] = f.maxY <= icon.minY
                    r["historyFullyOnScreen"] = (NSScreen.screens.first { $0.frame.intersects(icon) } ?? NSScreen.main!).visibleFrame.contains(f)
                }
                togglePanel()
                r["closedBySecondClick"] = !(panelWindow?.isShown ?? true)
                togglePanel(); togglePanel()
                r["reopenAndCloseWorks"] = !(panelWindow?.isShown ?? true)
                if let data = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: report)
                }
                NSApp.terminate(nil)
            }
        }
    }
#endif

    func applicationWillTerminate(_ notification: Notification) {
        ducker.restoreNow()    // first: never leave your music turned down, even if unloading is slow
        meetings.saveIfRecording()   // keep the transcript of a meeting that was still going
        transcriber.unload()   // Whisper's GPU code asserts if the model is still loaded at exit
    }

    /// Writes ~/Library/Application Support/Verbaline/status.json so setup problems can be diagnosed from outside the app.
    private func writeStatus() {
        var status: [String: Any] = [
            "fnKeyMonitorRunning": fn.isRunning,
            "accessibility": AXIsProcessTrusted(),
            "inputMonitoring": CGPreflightListenEventAccess(),
            "microphone": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            "lastRecordingUsedBuiltInMic": recorder.usingBuiltInMic,
            "lastRecordingUsedEchoCancellation": recorder.noiseReductionActive,
            "soundGoingToMacSpeakers": AudioRecorder.defaultOutputIsBuiltIn(),
            "speechEngine": engineStatus,
            "lastEditWatch": lastEditWatch,
            "aiCleanupAvailable": cleaner.llmAvailable,
        ]
        // Skip the disk write unless something changed (or a minute passed, to refresh "updated").
        let fingerprint = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys])
        guard fingerprint != lastStatus || Date().timeIntervalSince(lastStatusWrite) >= 60 else { return }
        lastStatus = fingerprint
        lastStatusWrite = Date()
        status["updated"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: history.fileURL.deletingLastPathComponent().appendingPathComponent("status.json"), options: .atomic)
    }

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// The event tap can only be created once Input Monitoring is granted, so keep retrying.
    private func startKeyMonitorWhenAllowed() {
        if fn.start() { NSLog("Verbaline: fn monitor started"); return }
        NSLog("Verbaline: waiting for Input Monitoring permission")
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.fn.start() {
                timer.invalidate()
                NSLog("Verbaline: fn monitor started")
                self.play("Glass")
                self.overlay.flash("fn key ready", seconds: 1.5)
            }
        }
    }

    // MARK: - fn gestures

    private func handleFnDown() {
        switch mode {
        case .idle:
            guard beginRecording(pressedAt: fn.lastFnEventAt) else { return }
            mode = .pressed
            fnDownAt = ProcessInfo.processInfo.systemUptime
            // Pill and chime right away: the mic is already recording, so you can start talking at once.
            // (A tap or an fn+key shortcut turns out not to be dictation later and just hides the pill.)
            announceListening(handsFree: false)
            holdTimer = Timer.scheduledTimer(withTimeInterval: tapMax, repeats: false) { [weak self] _ in
                guard let self, self.mode == .pressed else { return }
                self.mode = .pushToTalk
            }
        case .awaitingSecondTap:
            // Second tap: keep the mic rolling and switch to hands-free.
            tapTimer?.invalidate()
            mode = .handsFree
            swallowNextFnUp = true
            announceListening(handsFree: true)
        case .handsFree:
            swallowNextFnUp = true
            finishRecording(releasedAt: fn.lastFnEventAt)
        case .processing:
            play("Bottle")   // still finishing the last dictation — audible "busy" instead of silently ignoring
        case .pressed, .pushToTalk:
            break
        }
    }

    private func handleFnUp() {
        if swallowNextFnUp { swallowNextFnUp = false; return }
        let held = ProcessInfo.processInfo.systemUptime - fnDownAt
        switch mode {
        case .pressed where held < tapMax && commandMode:
            cancelRecording(showMessage: false)   // a quick fn+Control tap: nothing to do
        case .pressed where held < tapMax:
            holdTimer?.invalidate()
            mode = .awaitingSecondTap
            tapTimer = Timer.scheduledTimer(withTimeInterval: doubleTapWindow, repeats: false) { [weak self] _ in
                guard let self, self.mode == .awaitingSecondTap else { return }
                self.cancelRecording(showMessage: false)   // just a single tap — ignore it
            }
        case .pressed, .pushToTalk:
            finishRecording(releasedAt: fn.lastFnEventAt)
        default:
            break
        }
    }

    private func handleKeyWhileFnHeld() {
        // fn+arrow, fn+delete, etc. — the user wanted a shortcut, not dictation.
        let held = ProcessInfo.processInfo.systemUptime - fnDownAt
        if mode == .pressed || (mode == .pushToTalk && held < comboGrace) { cancelRecording(showMessage: false) }
    }

    private func handleEscape() {
        if typer.isTyping { typer.cancel(); return }
        switch mode {
        case .pressed, .pushToTalk, .handsFree, .awaitingSecondTap:
            cancelRecording(showMessage: true)
        default:
            break
        }
    }

    // MARK: - Recording lifecycle

    /// The user fixed some pasted text: learn the fixes that look like mishearings.
    private func learnFromEdit(pasted: String, edited: String) {
        guard learnFromEdits else { return }
        let learned = EditLearner.corrections(pasted: pasted, edited: edited)
            .filter { dictionary.learn(heard: $0.heard, written: $0.written) }
        guard let first = learned.first else { return }
        lastLearned = learned
        NSLog("Verbaline: learned %d correction(s) from an edit", learned.count)
        guard !isRecording, mode != .processing else { return }   // don't cover the live pill
        let more = learned.count > 1 ? "  +\(learned.count - 1)" : ""
        overlay.flash(.badge(.learned, "\(Self.short(first.heard)) → \(Self.short(first.written))\(more)"), seconds: 2.5)
        play("Purr")
    }

    /// Keeps a word short enough for the pill.
    private static func short(_ s: String) -> String {
        s.count <= 22 ? s : String(s.prefix(21)) + "…"
    }

    /// `pressedAt`: when the fn press reached Verbaline (now, if started from the menu).
    // MARK: - Speech model (first launch: download)

    static let modelMissing = "Speech model not downloaded"
    static let copiedNoBox = "Copied — no text box selected. Press ⌘V to paste"
    private let downloader = ModelDownloader()

    private func loadSpeechModel() {
        engineStatus = "Loading speech model…"
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transcriber.prepare()
                await MainActor.run { self.engineStatus = "Ready" }
            } catch {
                await MainActor.run { self.engineStatus = "Speech model error: \(error.localizedDescription)" }
            }
        }
    }

    private func downloadSpeechModel() {
        guard !downloader.isRunning else { return }
        engineStatus = "Downloading speech model… 0%"
        refreshPanel()
        downloader.start(progress: { [weak self] fraction in
            self?.engineStatus = "Downloading speech model… \(Int(fraction * 100))%"
            if self?.panelWindow?.isShown == true { self?.refreshPanel() }
        }, completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.play("Glass")
                self.overlay.flash("Speech model ready", seconds: 1.5)
                self.loadSpeechModel()
            case .failure(let error):
                self.engineStatus = Self.modelMissing
                self.overlay.flash(error.localizedDescription, seconds: 4)
            }
            if self.panelWindow?.isShown == true { self.refreshPanel() }
        })
    }

    private func beginRecording(pressedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        editWatcher.finishNow()   // a new dictation means the user is done fixing the last one
        if !ModelDownloader.isInstalled {
            overlay.flash(downloader.isRunning ? "The speech model is still downloading" :
                          "Download the speech model first: click the Verbaline icon in the menu bar", seconds: 3)
            return false
        }
        if !micAuthorized {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                micAuthorized = true   // checking costs ~13 ms right before the mic starts; once granted, skip it
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
                return false
            default:
                overlay.flash("Microphone access is off — see menu bar")
                return false
            }
        }
        do {
            let callStarted = ProcessInfo.processInfo.systemUptime
            try recorder.start()
            micStartCall = ProcessInfo.processInfo.systemUptime - callStarted
            recordingKeyAt = pressedAt
            return true
        } catch {
            overlay.flash("Mic error: \(error.localizedDescription)")
            return false
        }
    }

    /// Control joined the fn hold: this recording is a spoken instruction for the selected text.
    private func handleControlWithFn() {
        guard mode == .pressed || mode == .pushToTalk else { return }
        commandMode = true
        CommandMode.prewarm()
        overlay.show(.listeningCommand)   // already announced as dictation; switch the pill
    }

    private func announceListening(handsFree: Bool) {
        overlay.show(commandMode ? .listeningCommand : .listening(handsFree: handsFree))
        // Check before the chime: our own chime would make the speakers count as "playing".
        if ignoreMacAudio, MusicDucker.speakersArePlaying() { musicDuringRecording = true }
        play("Tink")
        // Turn speaker music down once this is really dictation (not a quick tap), after the chime.
        DispatchQueue.main.asyncAfter(deadline: .now() + tapMax + 0.02) { [weak self] in
            guard let self, self.ignoreMacAudio, self.mode == .pushToTalk || self.mode == .handsFree else { return }
            self.ducker.duck()
        }
        if aiCleanup { cleaner.prewarm() }   // the on-device model unloads when idle; wake it while you talk
        transcriber.prewarm()                 // same for Whisper: the Mac may have moved it out of memory
        startMicWatchdog()
        maxTimer?.invalidate()
        maxTimer = Timer.scheduledTimer(withTimeInterval: maxRecording, repeats: false) { [weak self] _ in
            guard let self, self.mode == .pushToTalk || self.mode == .handsFree else { return }
            self.finishRecording()
        }
    }

    private func invalidateTimers() {
        holdTimer?.invalidate(); tapTimer?.invalidate(); maxTimer?.invalidate(); micWatchdog?.invalidate()
    }

    /// Never fail silently: checks every second that audio is still arriving. If the mic never started,
    /// cancel and say so; if it died mid-recording (AirPods connected, USB mic unplugged), keep what was
    /// heard. Either way the audio engine is rebuilt for the next dictation.
    private func startMicWatchdog() {
        micWatchdog?.invalidate()
        var lastCount = -1
        let timer = Timer(fire: Date().addingTimeInterval(0.7), interval: 1.0, repeats: true) { [weak self] timer in
            guard let self, self.mode == .pushToTalk || self.mode == .handsFree else { timer.invalidate(); return }
            let count = self.recorder.buffersReceived
            defer { lastCount = count }
            guard count == 0 || count == lastCount else { return }
            timer.invalidate()
            self.recorder.invalidateEngine()
            self.play("Basso")
            if count == 0 {
                self.cancelRecording(showMessage: false)
                self.overlay.flash("Mic isn't sending sound — try again or switch mic in the menu", seconds: 3)
            } else {
                self.pendingNotice = "Mic stopped — typed what I heard"
                self.finishRecording()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        micWatchdog = timer
    }

    private func cancelRecording(showMessage: Bool) {
        invalidateTimers()
        pendingNotice = nil
        commandMode = false
        recorder.stop()
        ducker.restore()
        musicDuringRecording = false
        mode = .idle
        swallowNextFnUp = false
        if showMessage { overlay.flash("Cancelled", seconds: 0.9) } else { overlay.hide() }
    }

    /// `releasedAt`: when the fn press/release that ended the recording reached Verbaline (now, if a timer ended it).
    private func finishRecording(releasedAt: TimeInterval? = nil) {
        invalidateTimers()
        let releaseAt = releasedAt ?? ProcessInfo.processInfo.systemUptime
        var recordStats: [String: Double] = ["micStartCall": micStartCall]
        if let first = recorder.firstBufferAt { recordStats["keyToMic"] = first - recordingKeyAt }
        let stopStarted = ProcessInfo.processInfo.systemUptime
        let samples = recorder.stop()
        ducker.restore()
        let music = musicDuringRecording
        musicDuringRecording = false
        recordStats["stop"] = ProcessInfo.processInfo.systemUptime - stopStarted
        if music { recordStats["music"] = 1 }
        let seconds = Double(samples.count) / AudioRecorder.sampleRate
        let isCommand = commandMode
        commandMode = false
        guard seconds >= 0.3 else {
            mode = .idle
            if pendingNotice != nil {
                pendingNotice = nil
                overlay.flash("Mic stopped — try again", seconds: 2.5)
            } else {
                overlay.hide()
            }
            return
        }
        mode = .processing
        play("Pop")
        if isCommand {
            runCommand(samples: samples, music: music)
            return
        }
        overlay.show(.processing)

        let useAI = aiCleanup
        let filter = noiseFilter
        let sendCommand = pressEnterCommand
        let improveCommand = promptCommand
        Task { [weak self] in
            guard let self else { return }
            let started = Date()
            do {
                // 1. Keep only the voiced parts: drops chip clicks / fidget noise and shrinks long pauses.
                var audio = samples
                var timings = recordStats
                if filter || music {
                    let gate = music ? SpeechGate.process(samples, sampleRate: AudioRecorder.sampleRate, params: SpeechGate.musicParams)
                                     : SpeechGate.process(samples, sampleRate: AudioRecorder.sampleRate)
                    timings["voiceDb"] = SpeechGate.loudLevelDB(gate.samples)
                    timings["gate"] = Date().timeIntervalSince(started)
                    timings["audioIn"] = gate.originalSeconds
                    timings["audioOut"] = gate.outputSeconds
                    guard gate.hasSpeech else {
                        let stats = timings
                        await MainActor.run { self.deliver(raw: "", text: "", fixes: [], seconds: seconds, timings: stats, releasedAt: releaseAt) }
                        return
                    }
                    audio = gate.samples
                }
                // 2. Speech → text, biased toward the personal dictionary.
                self.transcriber.vocabulary = self.dictionary.terms
                let t1 = Date()
                let raw = try await self.transcriber.transcribe(samples: audio, sampleRate: AudioRecorder.sampleRate)
                timings["speech"] = Date().timeIntervalSince(t1)
                if let w = self.transcriber.lastPrewarmSeconds { timings["prewarm"] = w }
                // 3. Cleanup (skips the AI when there's nothing for it to fix), then dictionary spellings.
                let t2 = Date()
                let result = await TextPipeline.finish(raw, useAI: useAI, cleaner: self.cleaner,
                                                       dictionary: self.dictionary, snippets: self.snippets,
                                                       pressEnterCommand: sendCommand, promptCommand: improveCommand)
                timings["cleanup"] = Date().timeIntervalSince(t2)
                // 4. "…make this prompt better": rewrite it as a clearer AI prompt (or keep it as said).
                var text = result.text
                var promptResult: PromptResult?
                if result.improvePrompt {
                    if text.isEmpty {
                        await MainActor.run {
                            self.mode = .idle
                            self.overlay.flash("Say your prompt first, then “make this prompt better”", seconds: 2.5)
                        }
                        return
                    }
                    await MainActor.run { self.overlay.show(.working("Improving prompt…")) }
                    let t3 = Date()
                    switch await PromptBoost.improve(text) {
                    case .improved(let better): text = better; promptResult = .improved
                    case .keptAsSaid(let why): promptResult = .keptAsSaid(why)
                    }
                    timings["promptBoost"] = Date().timeIntervalSince(t3)
                }
                timings["total"] = Date().timeIntervalSince(started)
                let stats = timings
                let finalText = text
                let prompt = promptResult
                await MainActor.run {
                    self.deliver(raw: raw, text: finalText, fixes: result.fixes, seconds: seconds, timings: stats,
                                 releasedAt: releaseAt, pressEnter: result.pressEnter, prompt: prompt)
                }
            } catch {
                await MainActor.run {
                    self.mode = .idle
                    self.pendingNotice = nil
                    self.play("Basso")
                    self.overlay.flash("Transcription failed: \(error.localizedDescription)", seconds: 3)
                }
            }
        }
    }

    private var isRecording: Bool { [.pressed, .awaitingSecondTap, .pushToTalk, .handsFree].contains(mode) }

    // MARK: - Command Mode

    /// fn+Control was released: read the selection, transcribe the instruction, let the on-device AI
    /// rewrite (or draft), and paste the result over the selection.
    private func runCommand(samples: [Float], music: Bool = false) {
        overlay.show(.working("Thinking…"))
        pendingNotice = nil
        let filter = noiseFilter
        readSelection { [weak self] selection in
            guard let self else { return }
            Task { [weak self] in
                guard let self else { return }
                var audio = samples
                if filter || music {
                    let gate = music ? SpeechGate.process(samples, sampleRate: AudioRecorder.sampleRate, params: SpeechGate.musicParams)
                                     : SpeechGate.process(samples, sampleRate: AudioRecorder.sampleRate)
                    guard gate.hasSpeech else {
                        await MainActor.run { self.deliverCommand(.failed("Didn't hear an instruction"), instruction: "", selection: selection) }
                        return
                    }
                    audio = gate.samples
                }
                do {
                    let raw = try await self.transcriber.transcribe(samples: audio, sampleRate: AudioRecorder.sampleRate)
                    let instruction = await self.cleaner.clean(raw, useLLM: false)
                    guard !instruction.isEmpty else {
                        await MainActor.run { self.deliverCommand(.failed("Didn't hear an instruction"), instruction: "", selection: selection) }
                        return
                    }
                    await MainActor.run {
                        self.overlay.show(.working(selection == nil ? "Writing…" : "Rewriting…"))
                    }
                    let outcome = await CommandMode.run(instruction: instruction, selection: selection)
                    await MainActor.run { self.deliverCommand(outcome, instruction: instruction, selection: selection) }
                } catch {
                    await MainActor.run { self.deliverCommand(.failed("Couldn't transcribe the instruction"), instruction: "", selection: selection) }
                }
            }
        }
    }

    /// The selected text in the front app: asked directly where the app shares it, otherwise copied with ⌘C
    /// (clipboard restored). nil means nothing is selected → Command Mode drafts new text instead.
    private func readSelection(_ completion: @escaping (String?) -> Void) {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return completion(nil) }
        switch AXText.selection(in: pid) {
        case .text(let text): completion(text)
        case .nothingSelected: completion(nil)
        case .unknown:
            TextInserter.copySelection { copied in
                let trimmed = copied?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                completion(trimmed.isEmpty ? nil : copied)
            }
        }
    }

    private func deliverCommand(_ outcome: CommandMode.Outcome, instruction: String, selection: String?) {
        mode = .idle
        defer { writeStatus() }
        switch outcome {
        case .text(let text):
            let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty else {
                play("Basso")
                overlay.flash("Command didn't work — try again", seconds: 3)
                return
            }
            // Replacing a selection: keep the spaces/line breaks it started and ended with, and add no extra space.
            var pasted = result
            if let selection {
                let lead = String(selection.prefix(while: { $0.isWhitespace }))
                let trail = String(selection.reversed().prefix(while: { $0.isWhitespace }).reversed())
                pasted = lead + result + trail
            }
            let outcome = TextInserter.insertReporting(pasted, smartSpace: selection == nil)
            if outcome == .pasted {
                overlay.flash(.badge(.command, selection == nil ? "Wrote it — ⌘Z to undo" : "Rewrote it — ⌘Z to undo"), seconds: 2.2)
                play("Purr")
            } else if outcome == .copiedNoTextBox {
                overlay.flash(Self.copiedNoBox, seconds: 2.5)
            } else {
                overlay.flash("Copied — turn on Accessibility for Verbaline to auto-paste", seconds: 3)
            }
            history.add(HistoryEntry(date: Date(), raw: "[command] " + instruction, text: result, seconds: 0))
        case .failed(let reason):
            play("Basso")
            overlay.flash(reason.isEmpty ? "Command didn't work — try again" : reason, seconds: 3)
        }
    }

    enum PromptResult { case improved, keptAsSaid(String) }

    /// `prompt`: set when the dictation ended with "make this prompt better". An improved prompt is AI-written,
    /// so it's always pasted (never typed out) and isn't watched for learning.
    private func deliver(raw: String, text: String, fixes: [(from: String, to: String)],
                         seconds: Double, timings: [String: Double], releasedAt: TimeInterval, pressEnter: Bool = false,
                         prompt: PromptResult? = nil) {
        var timings = timings
        mode = .idle
        if timings["speech"] != nil { engineStatus = "Ready" }   // a launch-time model error has since recovered
        defer { writeStatus() }
        let notice = pendingNotice
        pendingNotice = nil
        // Writing style for the app it's going into (formal email, casual texts…). Rules only, so the words and
        // numbers never change; an AI-improved prompt is left exactly as written.
        let styledText: String = {
            guard prompt == nil else { return text }
            let front = NSWorkspace.shared.frontmostApplication
            let category = AppStyles.category(bundleID: front?.bundleIdentifier,
                                              windowTitle: front.map { Self.frontWindowTitle($0.processIdentifier) } ?? nil)
            return AppStyles.apply(style(for: category), to: text, category: category)
        }()
        let trimmed = styledText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if pressEnter, AXIsProcessTrusted() {   // said only "press enter"
                pressReturnSoon()
                overlay.flash("↵ Enter", seconds: 0.9)
            } else {
                overlay.flash("No speech detected", seconds: 1.2)
            }
            return
        }
        // Dictating into a password field is allowed, but nothing about it is saved or watched.
        let checkStarted = ProcessInfo.processInfo.systemUptime
        let secureField = TextInserter.focusedFieldIsSecure()
        timings["fieldCheck"] = ProcessInfo.processInfo.systemUptime - checkStarted
        // After the text is in: confirmations, then watch for the user's fixes.
        let afterInsert: (_ inserted: Bool, _ stoppedEarly: Bool) -> Void = { [weak self] inserted, stoppedEarly in
            guard let self else { return }
            guard inserted else {
                self.overlay.flash("Copied — turn on Accessibility for Verbaline to auto-paste", seconds: 3)
                return
            }
            if stoppedEarly {
                self.overlay.flash(self.typingStoppedBySwitch ? "Stopped typing — you switched apps" : "Stopped typing", seconds: 1.5)
                return   // only part of the text went in: nothing to watch
            }
            if case .improved = prompt {
                self.overlay.flash(.badge(.command, "Prompt improved — ⌘Z to undo"), seconds: 2.5)
                self.play("Purr")
                return   // AI-written: nothing to learn from your edits
            } else if case .keptAsSaid(let why) = prompt {
                self.overlay.flash("Pasted as you said it — \(why)", seconds: 3)
            } else if let notice {
                self.overlay.flash(notice, seconds: 2.5)
            } else if let fix = fixes.first {
                // A learned (or hand-added) "heard -> written" line just changed a word: show it.
                let more = fixes.count > 1 ? "  +\(fixes.count - 1)" : ""
                self.overlay.flash(.badge(.fixed, "\(Self.short(fix.from)) → \(Self.short(fix.to))\(more)"), seconds: 2.2)
                self.play("Purr")
            } else {
                self.overlay.hide()
            }
            if self.learnFromEdits, !secureField, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                self.editWatcher.watch(pasted: trimmed, in: pid)
            }
        }
        let aiWritten: Bool = { if case .improved = prompt { return true }; return false }()
        // Type It Out needs a text box too; with none, fall through to paste, which keeps the words on the clipboard.
        let noTextBox = NSWorkspace.shared.frontmostApplication.map { AXText.focusAcceptsText(in: $0.processIdentifier) == false } ?? false
        if typeOut, AXIsProcessTrusted(), !aiWritten, !noTextBox {
            // Type it out: busy until done (fn gives the busy sound, Esc stops), clipboard untouched.
            mode = .processing
            fn.swallowEscape = true
            overlay.show(.working("Typing…  Esc to stop"))
            // Keystrokes go to whatever app is in front, so stop if the user switches apps mid-way.
            let targetPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            typingStoppedBySwitch = false
            let switchWatch = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let self, self.typer.isTyping, app?.processIdentifier != targetPid else { return }
                self.typingStoppedBySwitch = true
                self.typer.cancel()
            }
            timings["releaseToTypeStart"] = ProcessInfo.processInfo.systemUptime - releasedAt
            typer.type(TextInserter.leadingSpaceIfNeeded() + trimmed, speed: typingSpeed) { [weak self] finished in
                NSWorkspace.shared.notificationCenter.removeObserver(switchWatch)
                self?.mode = .idle
                afterInsert(true, !finished)
            }
        } else {
            let pasteStarted = ProcessInfo.processInfo.systemUptime
            let outcome = TextInserter.insertReporting(trimmed)
            let pasted = ProcessInfo.processInfo.systemUptime
            timings["paste"] = pasted - pasteStarted
            timings["releaseToPaste"] = pasted - releasedAt
            if outcome == .copiedNoTextBox {
                // Nowhere to paste: the words wait on the clipboard instead of disappearing.
                overlay.flash(Self.copiedNoBox, seconds: 2.5)
                play("Pop")
            } else {
                afterInsert(outcome == .pasted, false)
            }
        }
        let rounded = timings.mapValues { ($0 * 1000).rounded() / 1000 }
        if !secureField {
            history.add(HistoryEntry(date: Date(), raw: raw, text: trimmed, seconds: seconds, timings: rounded))
            Stats.shared.record(text: trimmed, seconds: seconds)   // counts only, for Insights
        }
    }

    /// "press enter": Return goes to the app that got the text, a moment after it, so slower apps
    /// (Electron, web) have taken the paste in before the message is sent.
    private func pressReturnSoon() {
        let target = NSWorkspace.shared.frontmostApplication?.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.returnDelay) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target else { return }
            TextInserter.pressReturn()
        }
    }
    static let returnDelay: TimeInterval = 0.12

    private func play(_ name: String) {
        guard soundsOn, let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 0.4
        sound.play()
    }

    // MARK: - Menu bar

    /// Left-click the icon: the panel. Right-click (or the panel's gear): the full settings menu.
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        settingsMenu.delegate = self
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        setupPanel()
        updateStatusIcon()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showSettingsMenu()
        } else {
            togglePanel()
        }
    }

    private func showSettingsMenu() {
        closePanel()
        statusItem.menu = settingsMenu          // attach just long enough to open it under the icon
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Panel

    private func setupPanel() {
        panel.onToggle = { [weak self] id in
            guard let self else { return }
            switch id {
            case "ai": self.aiCleanup.toggle()
            case "sounds": self.soundsOn.toggle()
            case "typeOut": self.typeOut.toggle()
            case "enter": self.pressEnterCommand.toggle()
            case "macAudio": self.ignoreMacAudio.toggle()
            default: break
            }
            self.refreshPanel()
        }
        panel.onCopyLast = { [weak self] in
            guard let self, let text = self.history.last?.text else { return }
            TextInserter.copyToClipboard(text)
            self.panel.copiedFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.panel.copiedFlash = false }
        }
        panel.onPasteLast = { [weak self] in
            guard let self else { return }
            self.closePanel()   // the panel never took focus, so this pastes into the app you were in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.pasteLastNow() }
        }
        panel.onCopyRecent = { [weak self] text in
            TextInserter.copyToClipboard(text)
            self?.closePanel()
            self?.overlay.flash("Copied", seconds: 0.8)
        }
        panel.onWords = { [weak self] in self?.closePanel(); self?.openDictionary() }
        panel.onSnippets = { [weak self] in self?.closePanel(); self?.openSnippets() }
        panel.onSettings = { [weak self] in self?.showSettingsMenu() }
        panel.onNotes = { [weak self] in
            guard let self else { return }
            self.closePanel()
            if self.meetingNotesEnabled { self.meetings.openWindow() } else { self.meetings.openInsights() }
        }
        panel.onQuit = { NSApp.terminate(nil) }

        panel.onHistory = { [weak self] in
            guard let self else { return }
            self.panel.showHistory.toggle()
            DispatchQueue.main.async { self.panelWindow?.fit() }   // after SwiftUI lays out the new height
        }
        let win = PanelWindow(model: panel)
        win.onClose = { [weak self] in self?.panelTimer?.invalidate() }
        panelWindow = win
    }

    private func togglePanel() {
        guard let panelWindow, let button = statusItem.button, let buttonWindow = button.window else { return }
        if panelWindow.isShown { closePanel(); return }
        panel.showHistory = false
        refreshPanel()
        let icon = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        panelWindow.show(below: icon)
        // Placement log (~/Library/Application Support/Verbaline/panel-placement.txt), for multi-screen setups.
        let screens = NSScreen.screens.map { "frame \($0.frame) visible \($0.visibleFrame)" }.joined(separator: " | ")
        let line = "\(Date()) icon \(icon) panel \(panelWindow.frame) screens: \(screens)\n"
        try? line.write(to: history.fileURL.deletingLastPathComponent().appendingPathComponent("panel-placement.txt"),
                        atomically: true, encoding: .utf8)
        // Keep status and numbers live while it's open (model loading, a dictation finishing).
        panelTimer?.invalidate()
        panelTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self, self.panelWindow?.isShown == true else { timer.invalidate(); return }
            self.refreshPanel()
        }
    }

    private func closePanel() {
        panelTimer?.invalidate()
        panelWindow?.close()
    }

    private func refreshPanel() {
        panel.notesEnabled = meetingNotesEnabled
        var warnings: [PanelModel.Warning] = []
        if !fn.isRunning {
            warnings.append(.init(id: "input", text: "Allow Input Monitoring so fn works") { [weak self] in self?.openInputMonitoring() })
        }
        if !AXIsProcessTrusted() {
            warnings.append(.init(id: "ax", text: "Allow Accessibility so text can be pasted") { [weak self] in self?.openAccessibility() })
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            warnings.append(.init(id: "mic", text: "Allow the microphone") { [weak self] in self?.openMicrophone() })
        }
        if NSWorkspace.shared.runningApplications.contains(where: { ($0.bundleIdentifier ?? "").lowercased().contains("wispr") }) {
            warnings.append(.init(id: "wispr", text: "Wispr Flow is running — quit it so fn doesn't trigger both") {})
        }
        if engineStatus == Self.modelMissing {
            warnings.insert(.init(id: "model", text: "Download the speech model (1.6 GB, one time) to start dictating") {
                [weak self] in self?.downloadSpeechModel()
            }, at: 0)
        } else if engineStatus.hasPrefix("Downloading") {
            warnings.insert(.init(id: "model", text: engineStatus + " — you can keep working") {}, at: 0)
        }
        panel.warnings = warnings

        switch mode {
        case .pressed, .pushToTalk, .handsFree, .awaitingSecondTap:
            panel.status = .listening; panel.statusText = "Listening"
        case .processing:
            panel.status = .working; panel.statusText = "Working"
        default:
            if engineStatus == "Ready" {
                panel.status = warnings.contains { $0.id != "wispr" } ? .needsSetup : .ready
                panel.statusText = panel.status == .ready ? "Ready" : "Needs setup"
            } else if engineStatus.hasPrefix("Loading") || engineStatus.hasPrefix("Downloading") {
                panel.status = .loading; panel.statusText = engineStatus.hasPrefix("Loading") ? "Loading" : "Downloading"
            } else if engineStatus == Self.modelMissing {
                panel.status = .needsSetup; panel.statusText = "Needs setup"
            } else {
                panel.status = .needsSetup; panel.statusText = "Model error"
            }
        }

        let today = history.items.filter { Calendar.current.isDateInToday($0.date) }
        panel.wordsToday = today.reduce(0) { $0 + $1.text.split(whereSeparator: { $0.isWhitespace }).count }
        panel.lastSpeed = history.last?.timings?["releaseToPaste"]
        panel.lastText = history.last?.text
        panel.lastDate = history.last?.date
        panel.recent = history.items.prefix(6).map { $0.text }
        panel.toggles = [
            .init(id: "ai", label: "AI cleanup", icon: "sparkles", on: aiCleanup),
            .init(id: "sounds", label: "Sounds", icon: "speaker.wave.2", on: soundsOn),
            .init(id: "typeOut", label: "Type it out", icon: "keyboard", on: typeOut),
            .init(id: "enter", label: "Press enter", icon: "return", on: pressEnterCommand),
            .init(id: "macAudio", label: "Ignore Mac audio", icon: "speaker.slash", on: ignoreMacAudio),
        ]
    }

    private func updateStatusIcon() {
        let symbol: String
        switch mode {
        case .pushToTalk, .handsFree: symbol = "mic.fill"
        case .processing: symbol = "ellipsis.circle"
        default: symbol = "waveform"
        }
        let image: NSImage? = symbol == "waveform" ? Logo.menuBarImage()
                                                   : NSImage(systemSymbolName: symbol, accessibilityDescription: "Verbaline")
        image?.isTemplate = true
        image?.accessibilityDescription = "Murmur"
        statusItem?.button?.image = image
        if panelWindow?.isShown == true { refreshPanel() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(disabled("Verbaline — \(engineStatus)"))
        menu.addItem(disabled("Hold fn to talk · Double-tap fn for hands-free"))
        menu.addItem(disabled(CommandMode.isAvailable
            ? "Select text + hold fn+Control: rewrite it by voice"
            : "Command Mode needs Apple Intelligence (System Settings)"))

        // Warnings for things that silently break the fn key
        if !fn.isRunning { menu.addItem(warning("Needs Input Monitoring permission", action: #selector(openInputMonitoring))) }
        if !AXIsProcessTrusted() { menu.addItem(warning("Needs Accessibility permission (fn key + paste)", action: #selector(openAccessibility))) }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            menu.addItem(warning("Needs Microphone permission", action: #selector(openMicrophone)))
        }
        if NSWorkspace.shared.runningApplications.contains(where: { ($0.bundleIdentifier ?? "").lowercased().contains("wispr") }) {
            menu.addItem(disabled("⚠︎ Wispr Flow is running — quit it so fn doesn't trigger both"))
        }
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: mode == .handsFree ? "Stop Dictation" : "Start Dictation (hands-free)",
                                action: #selector(toggleDictation), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        if history.last != nil {
            let paste = NSMenuItem(title: "Paste Last Transcript  (⌃⌘V)", action: #selector(pasteLast), keyEquivalent: "")
            paste.target = self
            menu.addItem(paste)
        }

        let recent = NSMenuItem(title: "Recent (click to copy)", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if history.items.isEmpty { sub.addItem(disabled("Nothing yet")) }
        for item in history.items.prefix(12) {
            let title = item.text.count > 60 ? String(item.text.prefix(60)) + "…" : item.text
            let mi = NSMenuItem(title: title, action: #selector(copyRecent(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = item.text
            mi.toolTip = item.text
            sub.addItem(mi)
        }
        sub.addItem(.separator())
        let open = NSMenuItem(title: "Open History File", action: #selector(openHistory), keyEquivalent: "")
        open.target = self
        sub.addItem(open)
        let clear = NSMenuItem(title: "Clear History…", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        sub.addItem(clear)
        recent.submenu = sub
        menu.addItem(recent)
        menu.addItem(.separator())

        let ai = NSMenuItem(title: cleaner.llmAvailable ? "AI Cleanup (Apple Intelligence)" : "AI Cleanup (Apple Intelligence unavailable — basic cleanup only)",
                            action: #selector(toggleAI), keyEquivalent: "")
        ai.target = self
        ai.state = aiCleanup ? .on : .off
        menu.addItem(ai)

        let noise = NSMenuItem(title: "Noise Filter (ignore clicks, shrink pauses)", action: #selector(toggleNoise), keyEquivalent: "")
        noise.target = self
        noise.state = noiseFilter ? .on : .off
        menu.addItem(noise)

        let builtIn = NSMenuItem(title: "Use MacBook Microphone (keeps AirPods music quality)",
                                 action: #selector(toggleBuiltInMic), keyEquivalent: "")
        builtIn.target = self
        builtIn.state = useBuiltInMic ? .on : .off
        menu.addItem(builtIn)


        let dict = NSMenuItem(title: "Edit Personal Dictionary…", action: #selector(openDictionary), keyEquivalent: "")
        dict.target = self
        menu.addItem(dict)

        let snip = NSMenuItem(title: "Edit Snippets…  (say a phrase, paste saved text)", action: #selector(openSnippets), keyEquivalent: "")
        snip.target = self
        menu.addItem(snip)

        let learn = NSMenuItem(title: "Learn From My Edits (fix a word once, it remembers)", action: #selector(toggleLearn), keyEquivalent: "")
        learn.target = self
        learn.state = learnFromEdits ? .on : .off
        menu.addItem(learn)
        if !lastLearned.isEmpty {
            let names = lastLearned.map { "“\($0.heard)” → “\($0.written)”" }.joined(separator: ", ")
            let forget = NSMenuItem(title: "Forget Last Learned: \(names)", action: #selector(forgetLastLearned), keyEquivalent: "")
            forget.target = self
            menu.addItem(forget)
        }

        let enter = NSMenuItem(title: "Press Enter Command (say just “press enter” to send)", action: #selector(togglePressEnter), keyEquivalent: "")
        enter.target = self
        enter.state = pressEnterCommand ? .on : .off
        menu.addItem(enter)

        let type = NSMenuItem(title: "Type It Out Instead of Pasting (your dictation only)", action: #selector(toggleTypeOut), keyEquivalent: "")
        type.target = self
        type.state = typeOut ? .on : .off
        menu.addItem(type)
        let speedItem = NSMenuItem(title: "Typing Speed", action: nil, keyEquivalent: "")
        let speedMenu = NSMenu()
        for speed in TextTyper.Speed.allCases {
            let item = NSMenuItem(title: speed.label, action: #selector(setTypingSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = speed.rawValue
            item.state = speed == typingSpeed ? .on : .off
            speedMenu.addItem(item)
        }
        speedItem.submenu = speedMenu
        speedItem.isEnabled = typeOut
        menu.addItem(speedItem)

        let macAudio = NSMenuItem(title: "Ignore Mac Audio (keep videos and music out of dictation)",
                                  action: #selector(toggleIgnoreMacAudio), keyEquivalent: "")
        macAudio.target = self
        macAudio.state = ignoreMacAudio ? .on : .off
        menu.addItem(macAudio)

        let duckItem = NSMenuItem(title: "Turn Speaker Sound Down To", action: nil, keyEquivalent: "")
        let duckMenu = NSMenu()
        for (label, value) in [("50%", Float(0.5)), ("25%", 0.25), ("10%", 0.1), ("Mute", 0)] {
            let item = NSMenuItem(title: label, action: #selector(setDuckLevel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = abs(duckLevel - value) < 0.01 ? .on : .off
            duckMenu.addItem(item)
        }
        duckItem.submenu = duckMenu
        duckItem.isEnabled = ignoreMacAudio
        menu.addItem(duckItem)

        let promptItem = NSMenuItem(title: "“Make This Prompt Better” (say it at the end to rewrite your dictation as an AI prompt)",
                                    action: #selector(togglePromptCommand), keyEquivalent: "")
        promptItem.target = self
        promptItem.state = promptCommand ? .on : .off
        menu.addItem(promptItem)

        if meetingNotesEnabled {
        menu.addItem(.separator())
        let notesItem = NSMenuItem(title: meetings.isRecording ? "Stop Meeting Notes  (⌃⌘N)" : "Open Meeting Notes  (⌃⌘N starts notes)",
                                   action: #selector(openMeetingNotes), keyEquivalent: "")
        notesItem.target = self
        menu.addItem(notesItem)
        let askItem = NSMenuItem(title: "Ask to Take Notes When a Meeting Starts", action: #selector(toggleMeetingAsk), keyEquivalent: "")
        askItem.target = self
        askItem.state = meetings.askWhenMeetingStarts ? .on : .off
        menu.addItem(askItem)
        let loanItem = NSMenuItem(title: "Loan Details in Meeting Notes", action: #selector(toggleMeetingLoanDetails), keyEquivalent: "")
        loanItem.target = self
        loanItem.state = meetings.loanDetails ? .on : .off
        menu.addItem(loanItem)
        }
        menu.addItem(.separator())

        let styleItem = NSMenuItem(title: "Writing Style", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        for category in AppStyles.Category.allCases {
            let current = style(for: category)
            let catItem = NSMenuItem(title: "\(category.label): \(current.label)", action: nil, keyEquivalent: "")
            let catMenu = NSMenu()
            for option in AppStyles.Style.allCases {
                let item = NSMenuItem(title: option.label, action: #selector(setStyle(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = [category.rawValue, option.rawValue]
                item.state = option == current ? .on : .off
                catMenu.addItem(item)
            }
            catItem.submenu = catMenu
            styleMenu.addItem(catItem)
        }
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        let sounds = NSMenuItem(title: "Sounds", action: #selector(toggleSounds), keyEquivalent: "")
        sounds.target = self
        sounds.state = soundsOn ? .on : .off
        menu.addItem(sounds)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Verbaline", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func warning(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: "⚠︎ " + title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleDictation() {
        switch mode {
        case .idle:
            guard beginRecording() else { return }
            mode = .handsFree
            announceListening(handsFree: true)
        case .handsFree:
            finishRecording()
        default:
            break
        }
    }

    @objc private func pasteLast() {
        // Give the menu a moment to close so focus returns to the previous app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.pasteLastNow() }
    }

    private func pasteLastNow() {
        guard let text = history.last?.text else { overlay.flash("No transcript yet", seconds: 1); return }
        switch TextInserter.insertReporting(text) {
        case .pasted: break
        case .copiedNoTextBox: overlay.flash(Self.copiedNoBox, seconds: 2.5)
        case .copiedNoAccessibility: overlay.flash("Copied — turn on Accessibility for Verbaline to auto-paste", seconds: 3)
        }
    }

    private func copyLast() {
        guard let text = history.last?.text else { overlay.flash("No transcript yet", seconds: 1); return }
        TextInserter.copyToClipboard(text)
        if isRecording { play("Pop") } else { overlay.flash("Copied last transcript", seconds: 0.9) }
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        TextInserter.copyToClipboard(text)
        overlay.flash("Copied", seconds: 0.8)
    }

    @objc private func openHistory() { NSWorkspace.shared.open(history.fileURL) }
    @objc private func clearHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Clear all history?"
        alert.informativeText = "This deletes every saved dictation and Command Mode result. Your dictionary and snippets stay."
        alert.addButton(withTitle: "Clear History").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        history.clear()
        overlay.flash("History cleared", seconds: 1.2)
    }
    @objc private func toggleAI() { aiCleanup.toggle() }
    @objc private func toggleSounds() { soundsOn.toggle() }

    // MARK: - Writing styles

    private func style(for category: AppStyles.Category) -> AppStyles.Style {
        AppStyles.Style(rawValue: defaults.string(forKey: "style.\(category.rawValue)") ?? "") ?? category.defaultStyle
    }

    @objc private func setStyle(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        defaults.set(pair[1], forKey: "style.\(pair[0])")
    }

    /// Title of the front app's focused window (a browser's tab title, e.g. "Inbox - Gmail"). nil if unknown.
    private static func frontWindowTitle(_ pid: pid_t) -> String? {
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXText.app(pid), kAXFocusedWindowAttribute as CFString, &win) == .success,
              let win, CFGetTypeID(win) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }
    @objc private func togglePromptCommand() { promptCommand.toggle() }
    @objc private func toggleIgnoreMacAudio() { ignoreMacAudio.toggle() }
    @objc private func openMeetingNotes() { if meetings.isRecording { meetings.stopRecording() } else { meetings.openWindow() } }
    @objc private func toggleMeetingAsk() { meetings.askWhenMeetingStarts.toggle() }
    @objc private func toggleMeetingLoanDetails() { meetings.loanDetails.toggle() }
    @objc private func setDuckLevel(_ sender: NSMenuItem) { if let v = sender.representedObject as? Float { duckLevel = v } }
    @objc private func toggleTypeOut() { typeOut.toggle() }
    @objc private func togglePressEnter() { pressEnterCommand.toggle() }
    @objc private func setTypingSpeed(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let speed = TextTyper.Speed(rawValue: raw) { typingSpeed = speed }
    }
    @objc private func toggleNoise() { noiseFilter.toggle() }
    @objc private func toggleBuiltInMic() { useBuiltInMic.toggle() }
    /// Apple's own picker (Standard / Voice Isolation / Wide Spectrum). Apps can't set it directly.
    @objc private func openSnippets() { NSWorkspace.shared.open(snippets.fileURL) }
    @objc private func toggleLearn() { learnFromEdits.toggle() }
    @objc private func forgetLastLearned() {
        let forgotten = lastLearned.filter { dictionary.forget(heard: $0.heard, written: $0.written) }
        lastLearned = []
        overlay.flash(forgotten.isEmpty ? "Already removed" : "Forgot \(forgotten.count) learned fix\(forgotten.count == 1 ? "" : "es")", seconds: 1.5)
    }

    @objc private func openDictionary() {
        _ = dictionary.terms   // makes sure the file exists
        NSWorkspace.shared.open(dictionary.fileURL)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            overlay.flash("Launch at login failed: \(error.localizedDescription)", seconds: 3)
        }
    }

    @objc private func openInputMonitoring() { openSettings("Privacy_ListenEvent") }
    @objc private func openAccessibility() { openSettings("Privacy_Accessibility") }
    @objc private func openMicrophone() { openSettings("Privacy_Microphone") }

    private func openSettings(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}
