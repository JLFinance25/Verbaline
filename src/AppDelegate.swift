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
    private let transcriber = AppleTranscriber()
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
    private var mode: Mode = .idle {
        didSet {
            updateStatusIcon()
            fn.swallowEscape = [.pressed, .awaitingSecondTap, .pushToTalk, .handsFree].contains(mode)
        }
    }
    private var fnDownAt: TimeInterval = 0
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
        set { defaults.set(newValue, forKey: "noiseFilter"); recorder.noiseReduction = newValue }
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
    private var typeOut: Bool {
        get { defaults.object(forKey: "typeOut") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "typeOut") }
    }
    private var typingSpeed: TextTyper.Speed {
        get { TextTyper.Speed(rawValue: defaults.string(forKey: "typingSpeed") ?? "") ?? .steady }
        set { defaults.set(newValue.rawValue, forKey: "typingSpeed") }
    }
    private var soundsOn: Bool {
        get { defaults.object(forKey: "sounds") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "sounds") }
    }

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        recorder.onLevel = { [weak self] level in self?.overlay.model.push(level) }
        recorder.noiseReduction = noiseFilter
        recorder.preferBuiltInMic = useBuiltInMic
        transcriber.vocabulary = dictionary.terms
        _ = snippets   // create (and seed) on the main thread before any background dictation reads it
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

        // ⌃⌘V pastes the last transcript, ⌃⌘C copies it.
        hotKeys = [
            GlobalHotKey(keyCode: kVK_ANSI_V, modifiers: cmdKey | controlKey, id: 1) { [weak self] in self?.pasteLastNow() },
            GlobalHotKey(keyCode: kVK_ANSI_C, modifiers: cmdKey | controlKey, id: 2) { [weak self] in self?.copyLast() },
        ]

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transcriber.prepare()
                await MainActor.run { self.engineStatus = "Ready" }
            } catch {
                await MainActor.run { self.engineStatus = "Speech model error: \(error.localizedDescription)" }
            }
        }
        cleaner.prewarm()
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
            guard beginRecording() else { return }
            mode = .pressed
            fnDownAt = ProcessInfo.processInfo.systemUptime
            holdTimer = Timer.scheduledTimer(withTimeInterval: tapMax, repeats: false) { [weak self] _ in
                guard let self, self.mode == .pressed else { return }
                self.mode = .pushToTalk
                self.announceListening(handsFree: false)
            }
        case .awaitingSecondTap:
            // Second tap: keep the mic rolling and switch to hands-free.
            tapTimer?.invalidate()
            mode = .handsFree
            swallowNextFnUp = true
            announceListening(handsFree: true)
        case .handsFree:
            swallowNextFnUp = true
            finishRecording()
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
            finishRecording()
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

    private func beginRecording() -> Bool {
        editWatcher.finishNow()   // a new dictation means the user is done fixing the last one
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
            try recorder.start()
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
        if mode == .pushToTalk { overlay.show(.listeningCommand) }   // already announced as dictation; switch the pill
    }

    private func announceListening(handsFree: Bool) {
        overlay.show(commandMode ? .listeningCommand : .listening(handsFree: handsFree))
        play("Tink")
        if aiCleanup { cleaner.prewarm() }   // the on-device model unloads when idle; wake it while you talk
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
        mode = .idle
        swallowNextFnUp = false
        if showMessage { overlay.flash("Cancelled", seconds: 0.9) } else { overlay.hide() }
    }

    private func finishRecording() {
        invalidateTimers()
        let samples = recorder.stop()
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
            runCommand(samples: samples)
            return
        }
        overlay.show(.processing)

        let useAI = aiCleanup
        let filter = noiseFilter
        Task { [weak self] in
            guard let self else { return }
            let started = Date()
            do {
                // 1. Keep only the voiced parts: drops chip clicks / fidget noise and shrinks long pauses.
                var audio = samples
                var timings: [String: Double] = [:]
                if filter {
                    let gate = SpeechGate.process(samples, sampleRate: AudioRecorder.sampleRate)
                    timings["gate"] = Date().timeIntervalSince(started)
                    timings["audioIn"] = gate.originalSeconds
                    timings["audioOut"] = gate.outputSeconds
                    guard gate.hasSpeech else {
                        let stats = timings
                        await MainActor.run { self.deliver(raw: "", text: "", fixes: [], seconds: seconds, timings: stats) }
                        return
                    }
                    audio = gate.samples
                }
                // 2. Speech → text, biased toward the personal dictionary.
                self.transcriber.vocabulary = self.dictionary.terms
                let t1 = Date()
                let raw = try await self.transcriber.transcribe(samples: audio, sampleRate: AudioRecorder.sampleRate)
                timings["speech"] = Date().timeIntervalSince(t1)
                // 3. Cleanup (skips the AI when there's nothing for it to fix), then dictionary spellings.
                let t2 = Date()
                let result = await TextPipeline.finish(raw, useAI: useAI, cleaner: self.cleaner,
                                                       dictionary: self.dictionary, snippets: self.snippets)
                timings["cleanup"] = Date().timeIntervalSince(t2)
                timings["total"] = Date().timeIntervalSince(started)
                let stats = timings
                await MainActor.run {
                    self.deliver(raw: raw, text: result.text, fixes: result.fixes, seconds: seconds, timings: stats)
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
    private func runCommand(samples: [Float]) {
        overlay.show(.working("Thinking…"))
        pendingNotice = nil
        let filter = noiseFilter
        readSelection { [weak self] selection in
            guard let self else { return }
            Task { [weak self] in
                guard let self else { return }
                var audio = samples
                if filter {
                    let gate = SpeechGate.process(samples, sampleRate: AudioRecorder.sampleRate)
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
            if TextInserter.insert(pasted, smartSpace: selection == nil) {
                overlay.flash(.badge(.command, selection == nil ? "Wrote it — ⌘Z to undo" : "Rewrote it — ⌘Z to undo"), seconds: 2.2)
                play("Purr")
            } else {
                overlay.flash("Copied — turn on Accessibility for Verbaline to auto-paste", seconds: 3)
            }
            history.add(HistoryEntry(date: Date(), raw: "[command] " + instruction, text: result, seconds: 0))
        case .failed(let reason):
            play("Basso")
            overlay.flash(reason.isEmpty ? "Command didn't work — try again" : reason, seconds: 3)
        }
    }

    private func deliver(raw: String, text: String, fixes: [(from: String, to: String)],
                         seconds: Double, timings: [String: Double]) {
        mode = .idle
        if timings["speech"] != nil { engineStatus = "Ready" }   // a launch-time model error has since recovered
        defer { writeStatus() }
        let notice = pendingNotice
        pendingNotice = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            overlay.flash("No speech detected", seconds: 1.2)
            return
        }
        // Dictating into a password field is allowed, but nothing about it is saved or watched.
        let secureField = TextInserter.focusedFieldIsSecure()
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
            if let notice {
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
        if typeOut, AXIsProcessTrusted() {
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
            typer.type(TextInserter.leadingSpaceIfNeeded() + trimmed, speed: typingSpeed) { [weak self] finished in
                NSWorkspace.shared.notificationCenter.removeObserver(switchWatch)
                self?.mode = .idle
                afterInsert(true, !finished)
            }
        } else {
            afterInsert(TextInserter.insert(trimmed), false)
        }
        let rounded = timings.mapValues { ($0 * 1000).rounded() / 1000 }
        if !secureField {
            history.add(HistoryEntry(date: Date(), raw: raw, text: trimmed, seconds: seconds, timings: rounded))
        }
    }

    private func play(_ name: String) {
        guard soundsOn, let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 0.4
        sound.play()
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        let symbol: String
        switch mode {
        case .pushToTalk, .handsFree: symbol = "mic.fill"
        case .processing: symbol = "ellipsis.circle"
        default: symbol = "waveform"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Verbaline")
        image?.isTemplate = true
        statusItem?.button?.image = image
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

        let modeName: String
        switch AVCaptureDevice.preferredMicrophoneMode {
        case .voiceIsolation: modeName = "Voice Isolation ✓"
        case .wideSpectrum: modeName = "Wide Spectrum"
        default: modeName = "Standard"
        }
        let builtIn = NSMenuItem(title: "Use MacBook Microphone (keeps AirPods music quality)",
                                 action: #selector(toggleBuiltInMic), keyEquivalent: "")
        builtIn.target = self
        builtIn.state = useBuiltInMic ? .on : .off
        menu.addItem(builtIn)

        let micMode = NSMenuItem(title: "Mic Mode: \(modeName) — choose Voice Isolation to ignore music…",
                                 action: #selector(chooseMicMode), keyEquivalent: "")
        micMode.target = self
        micMode.isEnabled = noiseFilter   // the mode only applies with Apple voice processing on
        menu.addItem(micMode)

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
        if !TextInserter.insert(text) {
            overlay.flash("Copied — turn on Accessibility for Verbaline to auto-paste", seconds: 3)
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
    @objc private func toggleAI() { aiCleanup.toggle() }
    @objc private func toggleSounds() { soundsOn.toggle() }
    @objc private func toggleTypeOut() { typeOut.toggle() }
    @objc private func setTypingSpeed(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let speed = TextTyper.Speed(rawValue: raw) { typingSpeed = speed }
    }
    @objc private func toggleNoise() { noiseFilter.toggle() }
    @objc private func toggleBuiltInMic() { useBuiltInMic.toggle() }
    /// Apple's own picker (Standard / Voice Isolation / Wide Spectrum). Apps can't set it directly.
    @objc private func chooseMicMode() { AVCaptureDevice.showSystemUserInterface(.microphoneModes) }
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
