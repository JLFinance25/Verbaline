import Cocoa
import AVFoundation
import ApplicationServices

// Self-test: `Verbaline --selftest a.wav [b.wav …]` runs the full speech → text → cleanup
// pipeline on audio files and prints the results, without the UI or any hotkeys.
#if VERBALINE_TESTING   // self-test modes exist only in test builds (VERBALINE_TESTING=1 ./build.sh)
let args = CommandLine.arguments
if args.count > 2, args[1] == "--selftest" {
    func loadMono16k(_ path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate,
                                   channels: 1, interleaved: false)!
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: input)
        let converter = AVAudioConverter(from: file.processingFormat, to: target)!
        let ratio = target.sampleRate / file.processingFormat.sampleRate
        let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024)!
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    let transcriber = AppleTranscriber()
    let cleaner = TextCleaner()
    let dictionary = PersonalDictionary(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("verbaline-selftest-dictionary.txt"))
    let snippets = Snippets(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("verbaline-selftest-snippets.txt"))
    transcriber.vocabulary = dictionary.terms
    var finished = false
    Task.detached {
        do {
            try await transcriber.prepare()
            cleaner.prewarm()
            print("AI cleanup available: \(cleaner.llmAvailable)")
            for path in args.dropFirst(2) {
                let samples = try loadMono16k(path)
                let t0 = Date()
                let gate = SpeechGate.process(samples, sampleRate: AudioRecorder.sampleRate)
                let t1 = Date()
                let name = (path as NSString).lastPathComponent
                guard gate.hasSpeech else {
                    print("── \(name): no speech detected (gate \(String(format: "%.3f", t1.timeIntervalSince(t0)))s) — nothing typed")
                    continue
                }
                let raw = try await transcriber.transcribe(samples: gate.samples, sampleRate: AudioRecorder.sampleRate)
                let t2 = Date()
                let result = await TextPipeline.finish(raw, useAI: true, cleaner: cleaner,
                                                       dictionary: dictionary, snippets: snippets)
                let cleaned = result.text + (result.fixes.isEmpty ? "" : "   [fixed: "
                    + result.fixes.map { "\($0.from) → \($0.to)" }.joined(separator: ", ") + "]")
                let t3 = Date()
                print("""
                ── \(name)  (audio \(String(format: "%.1f", gate.originalSeconds))s → \(String(format: "%.1f", gate.outputSeconds))s after gate)
                gate    [\(String(format: "%.3f", t1.timeIntervalSince(t0)))s]
                speech  [\(String(format: "%.2f", t2.timeIntervalSince(t1)))s]: \(raw)
                cleaned [\(String(format: "%.2f", t3.timeIntervalSince(t2)))s]: \(cleaned)   (\(cleaner.lastDiagnostic))
                total   [\(String(format: "%.2f", t3.timeIntervalSince(t0)))s]
                """)
            }
        } catch {
            print("SELFTEST ERROR: \(error)")
        }
        finished = true
    }
    while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(0)
}

// Mic test: `open -n Verbaline.app --args --mictest out.json [builtin|default]` records 3 s and writes what arrived.
if args.count > 2, args[1] == "--mictest" {
    let recorder = AudioRecorder()
    recorder.noiseReduction = false
    recorder.preferBuiltInMic = args.count < 4 || args[3] != "default"
    var report: [String: Any] = [:]
    do {
        let t0 = Date()
        try recorder.start()
        let startCallMs = Date().timeIntervalSince(t0) * 1000
        while recorder.buffersReceived == 0, Date().timeIntervalSince(t0) < 1.5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        let firstBufferMs = Date().timeIntervalSince(t0) * 1000
        RunLoop.main.run(until: t0.addingTimeInterval(3))
        let samples = recorder.stop()
        report["startCallMs"] = startCallMs
        report["firstBufferMs"] = firstBufferMs
        // A second recording in the same session, like the next dictation.
        let t1 = Date()
        try recorder.start()
        while recorder.buffersReceived == 0, Date().timeIntervalSince(t1) < 1.5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        report["secondFirstBufferMs"] = Date().timeIntervalSince(t1) * 1000
        _ = recorder.stop()
        let peak = samples.map { abs($0) }.max() ?? 0
        let rms = samples.isEmpty ? 0 : (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        report.merge(["samples": samples.count, "seconds": Double(samples.count) / AudioRecorder.sampleRate,
                  "peak": peak, "rmsDb": 20 * log10(max(rms, 1e-9)), "buffers": recorder.buffersReceived,
                  "usingBuiltInMic": recorder.usingBuiltInMic, "format": recorder.lastInputFormat]) { $1 }
    } catch {
        report = ["error": "\(error)"]
    }
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: args[2]))
    }
    exit(0)
}

// Pill preview: `Verbaline --renderpill dir` writes PNGs of the pill's states (no window is shown).
if args.count > 2, args[1] == "--renderpill" {
    let dir = URL(fileURLWithPath: args[2], isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let phases: [(String, OverlayModel.Phase)] = [
        ("listening", .listening(handsFree: true)),
        ("fixed", .badge(.fixed, "Helllock → HELOC")),
        ("learned", .badge(.learned, "Fanny May → Fannie Mae")),
    ]
    for (name, phase) in phases {
        if let image = MainActor.assumeIsolated({ OverlayController.renderPreview(phase) }),
           let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }
    exit(0)
}

// Accessibility probe: `open -n Verbaline.app --args --axprobe out.json [delay]` reports what the focused
// text box exposes (role, whether its text is readable, its length — never the text itself).
if args.count > 2, args[1] == "--axprobe" {
    let delay = Double(args.count > 3 ? args[3] : "0") ?? 0
    RunLoop.main.run(until: Date().addingTimeInterval(delay))
    func attr(_ e: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(e, name as CFString, &ref)
        return (err, ref)
    }
    var report: [String: Any] = ["frontmost": NSWorkspace.shared.frontmostApplication?.localizedName ?? "?",
                                 "trusted": AXIsProcessTrusted()]
    func describe(_ label: String) {
        let system = AXUIElementCreateSystemWide()
        let (appErr, appRef) = attr(system, kAXFocusedApplicationAttribute)
        report["\(label).focusedAppError"] = appErr.rawValue
        let (err, ref) = attr(system, kAXFocusedUIElementAttribute)
        report["\(label).focusedElementError"] = err.rawValue
        if let appRef, CFGetTypeID(appRef) == AXUIElementGetTypeID() {
            var pid: pid_t = 0
            AXUIElementGetPid(appRef as! AXUIElement, &pid)
            report["\(label).focusedApp"] = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        }
        guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return }
        let el = ref as! AXUIElement
        report["\(label).role"] = attr(el, kAXRoleAttribute).1 as? String ?? "?"
        report["\(label).subrole"] = attr(el, kAXSubroleAttribute).1 as? String ?? "-"
        let (vErr, v) = attr(el, kAXValueAttribute)
        report["\(label).valueError"] = vErr.rawValue
        report["\(label).valueLength"] = (v as? String)?.count ?? -1
        report["\(label).hasSelectedRange"] = attr(el, kAXSelectedTextRangeAttribute).0 == .success
    }
    describe("plain")
    // Same question asked of one app directly (the frontmost, or one named on the command line),
    // before and after asking it to turn on its full accessibility tree (Electron/Chromium).
    let target = args.count > 4
        ? NSWorkspace.shared.runningApplications.first { $0.localizedName == args[4] }
        : NSWorkspace.shared.frontmostApplication
    func probeApp(_ front: NSRunningApplication, _ label: String) {
        let appEl = AXUIElementCreateApplication(front.processIdentifier)
        let (err, ref) = attr(appEl, kAXFocusedUIElementAttribute)
        report["\(label).app"] = front.localizedName ?? "?"
        report["\(label).focusedElementError"] = err.rawValue
        if let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            let el = ref as! AXUIElement
            report["\(label).role"] = attr(el, kAXRoleAttribute).1 as? String ?? "?"
            let (vErr, v) = attr(el, kAXValueAttribute)
            report["\(label).valueError"] = vErr.rawValue
            report["\(label).valueLength"] = (v as? String)?.count ?? -1
            report["\(label).hasSelectedRange"] = attr(el, kAXSelectedTextRangeAttribute).0 == .success
        }
    }
    if let target {
        probeApp(target, "direct")
        let appEl = AXUIElementCreateApplication(target.processIdentifier)
        report["setManualAccessibility"] = AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue).rawValue
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        probeApp(target, "afterManual")
        report["setEnhanced"] = AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue).rawValue
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        probeApp(target, "afterEnhanced")
        // Walk the focused window looking for the focused element and any text boxes.
        let (wErr, wRef) = attr(appEl, kAXFocusedWindowAttribute)
        report["focusedWindowError"] = wErr.rawValue
        if let wRef, CFGetTypeID(wRef) == AXUIElementGetTypeID() {
            var queue: [AXUIElement] = [wRef as! AXUIElement]
            var visited = 0, textBoxes = 0
            var focusedFound: [String] = []
            while !queue.isEmpty, visited < 4000 {
                let el = queue.removeFirst(); visited += 1
                let role = attr(el, kAXRoleAttribute).1 as? String ?? "?"
                if role == "AXTextArea" || role == "AXTextField" { textBoxes += 1 }
                if (attr(el, kAXFocusedAttribute).1 as? Bool) == true {
                    let len = (attr(el, kAXValueAttribute).1 as? String)?.count ?? -1
                    focusedFound.append("\(role) len=\(len)")
                }
                if let kids = attr(el, kAXChildrenAttribute).1 as? [AXUIElement] { queue.append(contentsOf: kids) }
            }
            report["walk.visited"] = visited
            report["walk.textBoxes"] = textBoxes
            report["walk.focused"] = focusedFound
        }
    }
    if false, let front = NSWorkspace.shared.frontmostApplication {
        let appEl = AXUIElementCreateApplication(front.processIdentifier)
        let (err, ref) = attr(appEl, kAXFocusedUIElementAttribute)
        report["direct.app"] = front.localizedName ?? "?"
        report["direct.focusedElementError"] = err.rawValue
        if let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            let el = ref as! AXUIElement
            report["direct.role"] = attr(el, kAXRoleAttribute).1 as? String ?? "?"
            let (vErr, v) = attr(el, kAXValueAttribute)
            report["direct.valueError"] = vErr.rawValue
            report["direct.valueLength"] = (v as? String)?.count ?? -1
        }
    }
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: args[2]))
    }
    exit(0)
}

// Edit-learning test, run like real use — one process shows a text box, another Verbaline process watches it:
// `open -n Verbaline.app --args --watchtest out.json`. The host window appears for ~9 s, "fixes" two words
// after 2.5 s, and the watcher records what it saw and what would be learned.
let selfTestPasted = "We can do a Helllock through Fanny May."
if args.count > 1, args[1] == "--edithost" {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 520, height: 160),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "Verbaline self-test — closes by itself"
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 160))
    textView.font = .systemFont(ofSize: 15)
    window.contentView = textView
    textView.string = "Hi Sarah. " + selfTestPasted
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(textView)
    textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { textView.string = "Hi Sarah. We can do a HELOC through Fannie Mae." }
    DispatchQueue.main.asyncAfter(deadline: .now() + 9) { exit(0) }
    app.run()
}
// Command Mode test, like real use: one process shows a text box with a selection, another reads the
// selection through Accessibility and runs the on-device rewrite. Nothing is pasted anywhere.
// `open -n Verbaline.app --args --commandtest out.json`
let selectionSample = "hey just checking in, the rate is 6.5% and your payment would be about $2,450 a month"
if args.count > 1, args[1] == "--selecthost" {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 560, height: 160),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "Verbaline self-test — closes by itself"
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 160))
    textView.font = .systemFont(ofSize: 15)
    window.contentView = textView
    textView.string = "Draft: " + selectionSample
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(textView)
    textView.setSelectedRange(NSRange(location: 7, length: (selectionSample as NSString).length))
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { exit(0) }
    app.run()
}
if args.count > 2, args[1] == "--commandtest" {
    var report: [String: Any] = [:]
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = true
    config.arguments = ["--selecthost"]
    config.activates = false
    var hostPid: pid_t = 0
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { app, _ in hostPid = app?.processIdentifier ?? 0 }
    let t0 = Date()
    while hostPid == 0, Date().timeIntervalSince(t0) < 5 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    var selection: String?
    switch AXText.selection(in: hostPid) {
    case .text(let t): selection = t; report["selectionRead"] = "via Accessibility"
    case .nothingSelected: report["selectionRead"] = "nothing selected"
    case .unknown: report["selectionRead"] = "unknown (would fall back to copy)"
    }
    report["selectionMatches"] = selection == selectionSample
    var done = false
    Task.detached {
        let started = Date()
        let outcome = await CommandMode.run(instruction: "make this more professional", selection: selection)
        switch outcome {
        case .text(let t): report["result"] = t
        case .failed(let why): report["failed"] = why
        }
        report["seconds"] = (Date().timeIntervalSince(started) * 100).rounded() / 100
        done = true
    }
    while !done, Date().timeIntervalSince(t0) < 30 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: args[2]))
    }
    exit(0)
}
/// The host window isn't the active app (so the tests never take focus from you). An inactive app gets ⌘V
/// as a plain keyDown instead of through its Edit menu, and NSTextView ignores that — so paste here,
/// as the frontmost app's Edit menu would.
final class PasteHostTextView: NSTextView {
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "v" { paste(nil); return }
        super.keyDown(with: event)
    }
}
// Typing test: `open -n Verbaline.app --args --typetest out.json` — a host window opens, Verbaline types into that
// process only (never the app you're using), then reads back what arrived.
let typeSample = "Hi Sarah, café 👋\nLine two: rate 6.5% & $2,450."
if args.count > 1, args[1] == "--typehost" {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 560, height: 160),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "Verbaline self-test — closes by itself"
    let textView = PasteHostTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 160))
    textView.font = .systemFont(ofSize: 15)
    window.contentView = textView
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(textView)
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { exit(0) }
    app.run()
}
if args.count > 2, args[1] == "--typetest" {
    var report: [String: Any] = ["expected": typeSample]
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = true
    config.arguments = ["--typehost"]
    config.activates = false
    var hostPid: pid_t = 0
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { app, _ in hostPid = app?.processIdentifier ?? 0 }
    let t0 = Date()
    while hostPid == 0, Date().timeIntervalSince(t0) < 5 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    let typer = TextTyper()
    var done = false
    let started = Date()
    typer.type(typeSample, speed: .fast, post: { TextTyper.post($0, toPid: hostPid) }) { finished in
        report["finished"] = finished
        report["seconds"] = (Date().timeIntervalSince(started) * 100).rounded() / 100
        done = true
    }
    while !done, Date().timeIntervalSince(t0) < 15 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    let box = AXText.textElement(containing: "Line two", in: hostPid) ?? AXText.focusedElement(in: hostPid)
    let got = box.flatMap { AXText.string($0, kAXValueAttribute) }
    report["got"] = got ?? "(couldn't read)"
    report["matches"] = got == typeSample
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: args[2]))
    }
    exit(0)
}
// "press enter" test: text already in a host window (that process only), then Return the way the app
// presses it for a spoken "press enter"; check the text is intact before the line break. `open -n Verbaline.app --args --entertest out.json`
if args.count > 2, args[1] == "--entertest" {
    let sample = "Sounds good, see you at three."
    var report: [String: Any] = ["expected": sample + "\n", "returnDelay": AppDelegate.returnDelay]
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = true
    config.arguments = ["--typehost"]
    config.activates = false
    var hostPid: pid_t = 0
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { app, _ in hostPid = app?.processIdentifier ?? 0 }
    let t0 = Date()
    while hostPid == 0, Date().timeIntervalSince(t0) < 5 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    TextInserter.paste(sample, into: .general, press: {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let v = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down)
            v?.flags = .maskCommand
            v?.postToPid(hostPid)
        }
    })
    DispatchQueue.main.asyncAfter(deadline: .now() + AppDelegate.returnDelay) { TextInserter.pressReturn(toPid: hostPid) }
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))   // also lets the clipboard restore (0.6 s) finish
    let box = AXText.textElement(containing: "three", in: hostPid) ?? AXText.focusedElement(in: hostPid)
    let got = box.flatMap { AXText.string($0, kAXValueAttribute) }
    report["got"] = got ?? "(couldn't read)"
    report["matches"] = got == sample + "\n"
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: args[2]))
    }
    exit(0)
}
if args.count > 2, args[1] == "--watchtest" {
    var report: [String: Any] = ["statuses": [String]()]
    let bundle = Bundle.main.bundleURL
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = true
    config.arguments = ["--edithost"]
    config.activates = false
    var hostPid: pid_t = 0
    NSWorkspace.shared.openApplication(at: bundle, configuration: config) { app, _ in hostPid = app?.processIdentifier ?? 0 }
    let t0 = Date()
    while hostPid == 0, Date().timeIntervalSince(t0) < 5 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    report["hostStarted"] = hostPid != 0
    var finished = false
    let watcher = EditWatcher()
    watcher.onStatus = { line in report["statuses"] = (report["statuses"] as! [String]) + [line] }
    watcher.onEdited = { pasted, edited in
        report["pasted"] = pasted
        report["edited"] = edited
        report["learned"] = EditLearner.corrections(pasted: pasted, edited: edited).map { "\($0.heard) -> \($0.written)" }
        finished = true
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))   // let the host window come up
    watcher.watch(pasted: selfTestPasted, in: hostPid)
    DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { watcher.finishNow() }  // "next dictation" ~4 s after the fix
    while !finished, Date().timeIntervalSince(t0) < 14 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: args[2]))
    }
    exit(0)
}

#endif

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
app.run()
