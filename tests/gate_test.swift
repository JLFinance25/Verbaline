import Foundation
import AVFoundation

// CLI harness for SpeechGate (+ the real Apple recognizer).
//
//   Compile (from the project root):
//     swiftc -swift-version 5 -O -parse-as-library src/SpeechGate.swift src/AppleTranscriber.swift \
//            tests/gate_test.swift -o build/gate_test/gate_test
//   Run:
//     build/gate_test/gate_test                 all cases, raw vs gated through the real recognizer
//
// Environment:
//   GATE_SKIP_STT=1       gate only (no recognizer): fast, for tuning
//   GATE_STRESS=N         gate only: N random seeds of chips-only / speech+chips recordings, pass/fail counts
//   GATE_DUMP=<case id>   print per-frame features for one case (see case ids in the table)
//   GATE_ONLY=a,b,c       run only these case ids
//   GATE_SEED=n           seed for the synthetic chip noise (default 7)
//
// Test audio: speech comes from macOS `say` (generated into build/gate_test/ on first run, 16 kHz).
// Chip noise is synthesized here: clicks (2-15 ms bursts of high-passed noise with fast exponential
// decay, plus "clack" and low "thud" variants as harder cases), riffles (10-30 clicks over ~0.8 s),
// and a low hiss. Every speech case also carries the clean speech track so we can measure how much
// of the real speech survived the gate (no words dropped).

let sampleRate = 16000.0
let outDir = "build/gate_test"

/// Gate parameters used by this harness; env GATE_PAUSE_MS / GATE_PAD_BEFORE_MS / GATE_PAD_AFTER_MS override them for sweeps.
let gateParams: SpeechGate.Params = {
    var p = SpeechGate.Params()
    let e = ProcessInfo.processInfo.environment
    if let v = Double(e["GATE_PAUSE_MS"] ?? "") { p.pauseMs = v }
    if let v = Double(e["GATE_PAD_BEFORE_MS"] ?? "") { p.padBeforeMs = v }
    if let v = Double(e["GATE_PAD_AFTER_MS"] ?? "") { p.padAfterMs = v }
    if let v = Int(e["GATE_EXT_GAP"] ?? "") { p.extendGapFrames = v }
    if let v = Double(e["GATE_EXT_AFTER_MS"] ?? "") { p.extendAfterMs = v }
    if let v = Double(e["GATE_EXT_BEFORE_MS"] ?? "") { p.extendBeforeMs = v }
    return p
}()

// MARK: - small utilities

struct RNG {
    var s: UInt64
    init(_ seed: UInt64) { s = seed &* 0x9E3779B97F4A7C15 &+ 0x1234567 }
    mutating func next() -> UInt64 {            // splitmix64
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * uniform() }
    mutating func gauss() -> Double {
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
}

func loadWav(_ path: String) -> [Float] {
    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return [] }
    let fmt = file.processingFormat
    guard fmt.sampleRate == 16000, fmt.channelCount == 1,
          let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length)) else {
        print("cannot read \(path) as 16 kHz mono"); return []
    }
    try? file.read(into: buf)
    guard let ch = buf.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
}

func writeWav(_ path: String, _ x: [Float]) {
    var data = Data()
    func u32(_ v: UInt32) { var l = v.littleEndian; withUnsafeBytes(of: &l) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { var l = v.littleEndian; withUnsafeBytes(of: &l) { data.append(contentsOf: $0) } }
    let bytes = x.count * 2
    data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + bytes))
    data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
    data.append(contentsOf: Array("data".utf8)); u32(UInt32(bytes))
    for v in x { u16(UInt16(bitPattern: Int16(max(-1, min(1, v)) * 32767))) }
    try? data.write(to: URL(fileURLWithPath: path))
}

/// Generate a speech clip with macOS `say` the first time, then reuse it.
func clip(_ name: String, voice: String? = nil, _ text: String) -> [Float] {
    let path = "\(outDir)/\(name).wav"
    if !FileManager.default.fileExists(atPath: path) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        var args = ["-o", path, "--file-format=WAVE", "--data-format=LEI16@16000"]
        if let v = voice { args += ["-v", v] }
        args.append(text)
        p.arguments = args
        try? p.run(); p.waitUntilExit()
    }
    return loadWav(path)
}

func peak(_ x: [Float]) -> Float { x.reduce(0) { max($0, abs($1)) } }
func rmsDB(_ x: [Float]) -> Float {
    guard !x.isEmpty else { return -120 }
    let s = x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)
    return Float(10 * log10(s + 1e-12))
}

// MARK: - chip noise synthesis

enum ClickKind { case hf, clack, thud, clink }

/// One click, normalized to `peak`.
func makeClick(_ rng: inout RNG, kind: ClickKind, peak pk: Float) -> [Float] {
    var y: [Float]
    switch kind {
    case .hf:
        // 2-15 ms burst of high-passed white noise, fast exponential decay.
        let len = Int(rng.uniform(2, 15) * 16)
        var prev = 0.0
        y = (0..<len).map { n in
            let g = rng.gauss(); defer { prev = g }
            return Float((g - 0.9 * prev) * exp(-4.0 * Double(n) / Double(len)))
        }
    case .clack:
        // Noise burst plus a ringing resonance at 1.5-4.5 kHz (a harder, more "tonal" click).
        let len = Int(rng.uniform(4, 15) * 16)
        let f = rng.uniform(1500, 4500), ph = rng.uniform(0, 6.28)
        var prev = 0.0
        y = (0..<len).map { n in
            let g = rng.gauss(); defer { prev = g }
            let env = exp(-4.5 * Double(n) / Double(len))
            return Float(((g - 0.9 * prev) * 0.5 + 1.2 * sin(2 * Double.pi * f * Double(n) / 16000 + ph)) * env)
        }
    case .clink:
        // Ringing "tink": 2-3 inharmonic partials at 1.2-5.5 kHz decaying over 8-25 ms (up to ~70 ms long).
        let tau = rng.uniform(8, 25) * 16
        let len = Int(tau * 3)
        let partials = (0..<3).map { _ in (rng.uniform(1200, 5500), rng.uniform(0, 6.28), rng.uniform(0.4, 1.0)) }
        y = (0..<len).map { n in
            let env = exp(-Double(n) / tau)
            var v = 0.0
            for (f, ph, a) in partials { v += a * sin(2 * Double.pi * f * Double(n) / 16000 + ph) }
            return Float((v + 0.15 * rng.gauss()) * env)
        }
    case .thud:
        // Low, ringing thump (250-900 Hz damped sine, up to ~30 ms): the hardest case for a voicing detector.
        let f = rng.uniform(250, 900), tau = rng.uniform(3, 8) * 16
        let len = Int(tau * 4.5)
        let ph = rng.uniform(0, 6.28)
        y = (0..<len).map { n in
            let env = exp(-Double(n) / tau)
            return Float((sin(2 * Double.pi * f * Double(n) / 16000 + ph) + 0.25 * rng.gauss()) * env)
        }
    }
    let m = max(peak(y), 1e-9)
    return y.map { $0 / m * pk }
}

func randomKind(_ rng: inout RNG, thudShare: Double = 0.2) -> ClickKind {
    let u = rng.uniform()
    if u < thudShare { return .thud }
    let v = rng.uniform()
    return v < 0.15 ? .clink : (v < 0.6 ? .hf : .clack)
}

func add(_ x: inout [Float], _ c: [Float], at pos: Int) {
    guard pos >= 0 else { return }
    for (i, v) in c.enumerated() where pos + i < x.count { x[pos + i] += v }
}

/// A rapid train of 10-30 clicks over ~0.8 s.
func addRiffle(_ x: inout [Float], _ rng: inout RNG, at pos: Int, peak pk: Float, thudShare: Double = 0.2) {
    let count = Int(rng.uniform(10, 31))
    let span = rng.uniform(0.6, 1.0) * 16000
    var t = 0.0
    for _ in 0..<count {
        let amp = pk * Float(rng.uniform(0.3, 1.0))
        add(&x, makeClick(&rng, kind: randomKind(&rng, thudShare: thudShare), peak: amp), at: pos + Int(t))
        t += span / Double(count) * rng.uniform(0.4, 1.6)
    }
}

func addHiss(_ x: inout [Float], _ rng: inout RNG, dB: Float) {
    let a = Float(pow(10, Double(dB) / 20))
    var lp = 0.0
    for i in 0..<x.count {                 // white noise with a gentle low-pass tilt, like room noise
        let g = rng.gauss()
        lp = 0.6 * lp + 0.4 * g
        x[i] += a * Float(lp * 1.6)
    }
}

func addHum(_ x: inout [Float], dB: Float) {
    let a = Float(pow(10, Double(dB) / 20)) * 1.414
    for i in 0..<x.count {
        let t = Double(i) / 16000
        x[i] += a * Float(sin(2 * Double.pi * 120 * t) + 0.5 * sin(2 * Double.pi * 240 * t + 1)) * 0.8
    }
}

// MARK: - timeline builder

struct Timeline {
    var x: [Float] = []                  // the mix
    var speech: [Float] = []             // clean speech only, same length
    var gaps: [(Int, Int)] = []          // silent stretches between clips
    var spans: [(Int, Int)] = []         // clip extents
    var text: [String] = []

    mutating func silence(_ sec: Double) {
        let n = Int(sec * 16000)
        if n > 0 { x += [Float](repeating: 0, count: n); speech += [Float](repeating: 0, count: n) }
    }
    mutating func gap(_ sec: Double) {
        let a = x.count; silence(sec); gaps.append((a, x.count))
    }
    mutating func say(_ c: [Float], _ words: String, gain: Float = 1) {
        let a = x.count
        let g = c.map { $0 * gain }
        x += g; speech += g
        spans.append((a, x.count))
        text.append(words)
    }
    var reference: String { text.joined(separator: " ") }
}

struct Case {
    let id: String
    let title: String
    let x: [Float]
    let speechOnly: [Float]?             // clean speech track (nil = no speech in this case)
    let reference: String?
    let expectSpeech: Bool
}

// Sentences carry no digits, so a transcript can be compared word-for-word.
let T1 = "Hi Sarah, thanks for reaching out about the mortgage. Your approval letter is ready."
let T2 = "The interest rate is fixed, and we can close in about a month."
let T3 = "Please send me your bank statements and your last tax returns."
let T4 = "The loan has a long term with no prepayment penalty."
let T5 = "Let me know if you have any questions about the closing costs."
let T6 = "I will send the disclosure documents over by Friday afternoon."

struct Clips {
    let s1 = clip("c_s1", T1), s2 = clip("c_s2", T2), s3 = clip("c_s3", T3), s4 = clip("c_s4", T4)
    let d1 = clip("c_d1", voice: "Daniel", T5), m1 = clip("c_m1", voice: "Samantha", T6)
    let yes = clip("c_yes", "Yes."), no = clip("c_no", "No."), okay = clip("c_okay", "Okay."),
        thanks = clip("c_thanks", "Thanks."), send = clip("c_send", "Send it.")
    let whisper = clip("c_w1", voice: "Whisper", T3)
    let junk = clip("c_junk", "Hmm.")
    var refPeak: Float { peak(s1) }
}

/// Clicks in the pauses, plus a few right next to words (inside the pad zone) and a few on top of words.
func chipify(_ tl: inout Timeline, _ rng: inout RNG, refPeak: Float, inPauses: Bool = true,
             riffles: Int = 1, nearWords: Bool = true, onWords: Int = 4, hiss: Float = -58,
             thudShare: Double = 0.2) {
    func pk() -> Float { min(0.98, refPeak * Float(rng.uniform(0.5, 1.5))) }
    if inPauses {
        for (a, b) in tl.gaps where b - a > 8000 {
            let k = Int(rng.uniform(3, 9))
            for _ in 0..<k {
                let p = a + 800 + Int(rng.uniform() * Double(b - a - 1600))
                add(&tl.x, makeClick(&rng, kind: randomKind(&rng, thudShare: thudShare), peak: pk()), at: p)
            }
        }
        var big = tl.gaps.filter { $0.1 - $0.0 > 32000 }
        for _ in 0..<riffles where !big.isEmpty {
            let g = big.removeFirst()
            addRiffle(&tl.x, &rng, at: g.0 + 8000 + Int(rng.uniform() * 8000), peak: pk(), thudShare: thudShare)
        }
    }
    if nearWords {
        for (a, b) in tl.spans {
            add(&tl.x, makeClick(&rng, kind: .hf, peak: pk()), at: a - Int(rng.uniform(80, 260) * 16))
            add(&tl.x, makeClick(&rng, kind: .clack, peak: pk()), at: b + Int(rng.uniform(80, 300) * 16))
        }
    }
    for _ in 0..<onWords where !tl.spans.isEmpty {
        let s = tl.spans[Int(rng.uniform() * Double(tl.spans.count))]
        let p = s.0 + Int(rng.uniform() * Double(s.1 - s.0))
        add(&tl.x, makeClick(&rng, kind: randomKind(&rng, thudShare: thudShare), peak: pk()), at: p)
    }
    addHiss(&tl.x, &rng, dB: hiss)
}

func buildCases(seed: UInt64) -> [Case] {
    let c = Clips()
    var rng = RNG(seed)
    var cases: [Case] = []
    let rp = c.refPeak

    func finish(_ id: String, _ title: String, _ tl: Timeline, expect: Bool = true) {
        cases.append(Case(id: id, title: title, x: tl.x, speechOnly: tl.speech, reference: tl.reference, expectSpeech: expect))
    }

    // (a) clean speech: two sentences, natural short gap, a little hiss
    do {
        var tl = Timeline()
        tl.silence(0.3); tl.say(c.s1, T1); tl.gap(0.35); tl.say(c.s2, T2); tl.silence(0.4)
        addHiss(&tl.x, &rng, dB: -62)
        finish("a", "clean speech", tl)
    }
    // (b) speech + long pauses (2.5 / 3 / 2 s)
    do {
        var tl = Timeline()
        tl.silence(0.6); tl.say(c.s1, T1); tl.gap(2.5); tl.say(c.s2, T2); tl.gap(3.0); tl.say(c.s3, T3)
        tl.gap(2.0); tl.say(c.s4, T4); tl.silence(1.0)
        addHiss(&tl.x, &rng, dB: -58)
        finish("b", "speech + long pauses", tl)
    }
    // (c) speech + pauses + chip clicks in pauses, near words, on words + a riffle
    do {
        var tl = Timeline()
        tl.silence(0.6); tl.say(c.s1, T1); tl.gap(2.5); tl.say(c.s2, T2); tl.gap(3.0); tl.say(c.s3, T3)
        tl.gap(2.0); tl.say(c.s4, T4); tl.silence(1.0)
        chipify(&tl, &rng, refPeak: rp, riffles: 2)
        finish("c", "speech + pauses + chips + riffles", tl)
    }
    // (c2) same with a male and a female voice
    do {
        var tl = Timeline()
        tl.silence(0.5); tl.say(c.d1, T5); tl.gap(2.2); tl.say(c.m1, T6); tl.gap(2.8); tl.say(c.d1, T5); tl.silence(0.8)
        chipify(&tl, &rng, refPeak: rp, riffles: 2)
        finish("c2", "male + female voice, chips", tl)
    }
    // (d) chips / riffles only
    do {
        var tl = Timeline()
        tl.gap(12)
        let (a, b) = tl.gaps[0]
        var x = tl.x
        for _ in 0..<40 { add(&x, makeClick(&rng, kind: randomKind(&rng), peak: min(0.98, rp * Float(rng.uniform(0.4, 1.6)))),
                              at: a + Int(rng.uniform() * Double(b - a - 400))) }
        for k in 0..<4 { addRiffle(&x, &rng, at: a + 16000 + k * 40000 + Int(rng.uniform() * 10000), peak: rp) }
        tl.x = x
        addHiss(&tl.x, &rng, dB: -58)
        cases.append(Case(id: "d", title: "chips + riffles only", x: tl.x, speechOnly: nil, reference: nil, expectSpeech: false))
    }
    // (d2) chips only, very dense riffling (continuous, 30 ms spacing, mostly hard thuds)
    do {
        var tl = Timeline()
        tl.gap(8)
        var x = tl.x
        for k in 0..<8 { addRiffle(&x, &rng, at: 8000 + k * 15000, peak: rp, thudShare: 0.5) }
        for t in stride(from: 4000, to: 120000, by: 480) {
            add(&x, makeClick(&rng, kind: randomKind(&rng, thudShare: 0.4), peak: rp * Float(rng.uniform(0.3, 1.0))), at: t)
        }
        tl.x = x
        addHiss(&tl.x, &rng, dB: -58)
        cases.append(Case(id: "d2", title: "chips only, continuous dense riffling", x: tl.x, speechOnly: nil, reference: nil, expectSpeech: false))
    }
    // (e) quiet speech (-20 dB) with chips that stay at normal level (so 20 dB louder than the voice)
    do {
        var tl = Timeline()
        tl.silence(0.5); tl.say(c.s1, T1, gain: 0.1); tl.gap(2.0); tl.say(c.s3, T3, gain: 0.1); tl.silence(0.8)
        chipify(&tl, &rng, refPeak: rp, riffles: 1, hiss: -64)
        finish("e", "quiet speech (-20 dB) + loud chips", tl)
    }
    // (f) silence only
    do {
        var tl = Timeline(); tl.gap(5)
        cases.append(Case(id: "f", title: "digital silence", x: tl.x, speechOnly: nil, reference: nil, expectSpeech: false))
        var h = [Float](repeating: 0, count: 80000); addHiss(&h, &rng, dB: -55)
        cases.append(Case(id: "f2", title: "hiss only", x: h, speechOnly: nil, reference: nil, expectSpeech: false))
        var hm = [Float](repeating: 0, count: 80000); addHum(&hm, dB: -48); addHiss(&hm, &rng, dB: -60)
        cases.append(Case(id: "f3", title: "mains hum + hiss only", x: hm, speechOnly: nil, reference: nil, expectSpeech: false))
    }
    // (g) single short words with chips around them
    for (id, w, txt) in [("g1", c.yes, "Yes."), ("g2", c.no, "No."), ("g3", c.okay, "Okay."),
                         ("g4", c.thanks, "Thanks."), ("g5", c.send, "Send it.")] {
        var tl = Timeline()
        tl.silence(1.0); tl.say(w, txt); tl.gap(1.5)
        chipify(&tl, &rng, refPeak: rp, riffles: 0, onWords: 0)
        finish(id, "single word '\(txt)' + chips", tl)
    }
    // (h) whispered speech (Whisper voice): a known weak spot for any voicing-based gate
    do {
        var tl = Timeline()
        tl.silence(0.5); tl.say(c.whisper, T3); tl.silence(0.8)
        addHiss(&tl.x, &rng, dB: -62)
        finish("h", "whispered speech (Whisper voice)", tl)
    }
    // (i) heavy chips ON the words (every ~150 ms during speech): informational, the gate cannot remove these
    do {
        var tl = Timeline()
        tl.silence(0.6); tl.say(c.s1, T1); tl.gap(1.5); tl.say(c.s2, T2); tl.silence(0.6)
        let spans = tl.spans
        for (a, b) in spans {
            var t = a
            while t < b { add(&tl.x, makeClick(&rng, kind: randomKind(&rng), peak: rp * Float(rng.uniform(0.4, 1.2))), at: t); t += Int(rng.uniform(1600, 3200)) }
        }
        addHiss(&tl.x, &rng, dB: -58)
        finish("i", "chips ON the words (every ~150 ms)", tl)
    }
    // (j) noisy room (-45 dB hiss) with pauses + chips
    do {
        var tl = Timeline()
        tl.silence(0.6); tl.say(c.s1, T1); tl.gap(2.5); tl.say(c.s2, T2); tl.gap(2.0); tl.say(c.s3, T3); tl.silence(0.8)
        chipify(&tl, &rng, refPeak: rp, riffles: 1, hiss: -45)
        finish("j", "noisy room (-45 dB) + pauses + chips", tl)
    }
    // (m) mains hum (-45 dB) under speech, pauses and chips
    do {
        var tl = Timeline()
        tl.silence(0.6); tl.say(c.s1, T1); tl.gap(2.5); tl.say(c.s2, T2); tl.gap(2.0); tl.say(c.s3, T3); tl.silence(0.8)
        chipify(&tl, &rng, refPeak: rp, riffles: 1, hiss: -62)
        addHum(&tl.x, dB: -45)
        finish("m", "mains hum (-45 dB) + pauses + chips", tl)
    }
    // (k) 60 s of dictation with pauses and chips (timing test)
    do {
        var tl = Timeline()
        let sentences: [([Float], String)] = [(c.s1, T1), (c.s2, T2), (c.s3, T3), (c.s4, T4), (c.d1, T5), (c.m1, T6)]
        tl.silence(0.5)
        var k = 0
        while Double(tl.x.count) / 16000 < 58 {
            let s = sentences[k % sentences.count]; k += 1
            tl.say(s.0, s.1); tl.gap(rng.uniform(1.0, 3.0))
        }
        chipify(&tl, &rng, refPeak: rp, riffles: 6, onWords: 10)
        finish("k", "60 s dictation, pauses + chips", tl)
    }
    return cases
}

// MARK: - scoring

func normalizeWords(_ s: String) -> [String] {
    let cleaned = s.lowercased().map { ($0.isLetter || $0.isNumber || $0 == "'") ? $0 : " " }
    return String(cleaned).split(separator: " ").map(String.init)
}

/// Word error rate and inserted-word count (junk words) against the reference.
func score(_ ref: [String], _ hyp: [String]) -> (wer: Double, ins: Int, del: Int, sub: Int) {
    let n = ref.count, m = hyp.count
    var D = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
    for i in 0...n { D[i][0] = i }
    for j in 0...m { D[0][j] = j }
    if n > 0 && m > 0 {
        for i in 1...n { for j in 1...m {
            D[i][j] = min(D[i-1][j] + 1, D[i][j-1] + 1, D[i-1][j-1] + (ref[i-1] == hyp[j-1] ? 0 : 1))
        } }
    }
    var i = n, j = m, ins = 0, del = 0, sub = 0
    while i > 0 || j > 0 {
        if i > 0 && j > 0 && D[i][j] == D[i-1][j-1] + (ref[i-1] == hyp[j-1] ? 0 : 1) {
            if ref[i-1] != hyp[j-1] { sub += 1 }; i -= 1; j -= 1
        } else if j > 0 && D[i][j] == D[i][j-1] + 1 { ins += 1; j -= 1 }
        else { del += 1; i -= 1 }
    }
    return (n == 0 ? (m == 0 ? 0 : 1) : Double(D[n][m]) / Double(n), ins, del, sub)
}

/// Fraction of the clean speech's 20 ms frames (those within 40 dB of the loudest) that fall inside kept segments.
func speechCoverage(_ speech: [Float], segments: [(start: Int, end: Int)]) -> (frames: Double, weakest: Double) {
    let f = 320
    var peakMS: Float = 0
    var levels: [Float] = []
    var i = 0
    while i + f <= speech.count {
        var s: Float = 0
        for k in 0..<f { s += speech[i + k] * speech[i + k] }
        levels.append(s / Float(f)); peakMS = max(peakMS, s / Float(f)); i += f
    }
    var kept = 0, total = 0, keptWeak = 0, totalWeak = 0
    for (idx, ms) in levels.enumerated() where ms >= peakMS * 1e-4 {          // within 40 dB of the loudest frame
        let a = idx * f, b = a + f
        // a frame counts as kept if at least 90% of it lies inside a kept segment
        var inside = 0
        for s in segments { inside += max(0, min(b, s.end) - max(a, s.start)) }
        let isKept = Double(inside) / Double(f) >= 0.9
        total += 1; if isKept { kept += 1 }
        if ms < peakMS * 1e-3 { totalWeak += 1; if isKept { keptWeak += 1 } }     // weak frames (< -30 dB re peak): consonants, tails
    }
    return (total == 0 ? 1 : Double(kept) / Double(total), totalWeak == 0 ? 1 : Double(keptWeak) / Double(totalWeak))
}

func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }

func fmt(_ v: Double, _ d: Int = 1) -> String { String(format: "%.\(d)f", v) }

// MARK: - main

@main
struct GateTest {
    static func main() async {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        let seed = UInt64(env["GATE_SEED"] ?? "") ?? 7

        if let n = Int(env["GATE_STRESS"] ?? "") { stress(seeds: n); return }
        if env["GATE_FUZZ"] != nil { fuzz(seed: seed); return }
        if env["GATE_LEVELS"] != nil { await levels(seed: seed); return }
        if env["GATE_PERF"] != nil { perf(seed: seed); return }
        if let v = env["GATE_EXP"] { await experiment(voice: v, seed: seed); return }
        if let n = Int(env["GATE_JUNK"] ?? "") { await junkStudy(runs: n); return }
        if env["GATE_VOICES"] != nil { await voices(skipSTT: env["GATE_SKIP_STT"] != nil, seed: seed); return }

        var cases = buildCases(seed: seed)
        if let only = env["GATE_ONLY"] { let ids = Set(only.split(separator: ",").map(String.init)); cases = cases.filter { ids.contains($0.id) } }

        if let id = env["GATE_DUMP"], let c = cases.first(where: { $0.id == id }) { dump(c); return }

        // ---- gate only: timing + detection + coverage
        print("== SpeechGate ==")
        print("case  expect  hasSpeech  in(s)  out(s)  gate(ms)  speechFramesKept  weakFramesKept")
        var gated: [String: SpeechGate.Result] = [:]
        var failures: [String] = []
        for c in cases {
            var times: [Double] = []
            var r = SpeechGate.process(c.x, sampleRate: sampleRate, params: gateParams)
            for _ in 0..<20 {
                let t0 = DispatchTime.now().uptimeNanoseconds
                r = SpeechGate.process(c.x, sampleRate: sampleRate, params: gateParams)
                times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            }
            gated[c.id] = r
            var cov = ""
            if let sp = c.speechOnly, c.expectSpeech {
                let a = SpeechGate.analyze(c.x, sampleRate: sampleRate, params: gateParams)
                let k = speechCoverage(sp, segments: a.segments)
                cov = "\(fmt(k.frames * 100))%  \(fmt(k.weakest * 100))%"
                if k.frames < 0.995 { failures.append("\(c.id): speech frames kept \(fmt(k.frames * 100))%") }
            }
            let a0 = SpeechGate.analyze(c.x, sampleRate: sampleRate, params: gateParams)
            if a0.usedFallback { cov += "  [no-pitch fallback]" }
            if r.hasSpeech != c.expectSpeech { failures.append("\(c.id): hasSpeech=\(r.hasSpeech), expected \(c.expectSpeech)") }
            print("\(c.id.padding(toLength: 5, withPad: " ", startingAt: 0))  \(c.expectSpeech ? "yes   " : "no    ")  \(r.hasSpeech ? "true     " : "false    ")  \(fmt(r.originalSeconds).padding(toLength: 5, withPad: " ", startingAt: 0))  \(fmt(r.outputSeconds).padding(toLength: 5, withPad: " ", startingAt: 0))  \(fmt(median(times), 2).padding(toLength: 8, withPad: " ", startingAt: 0))  \(cov)   \(c.title)")
            writeWav("\(outDir)/\(c.id)_raw.wav", c.x)
            if r.hasSpeech { writeWav("\(outDir)/\(c.id)_gated.wav", r.samples) }
        }

        if env["GATE_SKIP_STT"] != nil {
            print(failures.isEmpty ? "\nGATE CHECKS: all passed" : "\nGATE CHECKS FAILED:\n  " + failures.joined(separator: "\n  "))
            return
        }

        // ---- real recognizer: raw vs gated
        guard #available(macOS 26.0, *) else { print("needs macOS 26"); return }
        print("\n== Apple recognizer: raw vs gated ==")
        let stt = AppleTranscriber()
        do { try await stt.prepare() } catch { print("prepare failed: \(error)"); return }
        _ = try? await stt.transcribe(samples: cases[0].x, sampleRate: sampleRate)     // warm-up, not timed

        struct Row { let id: String; let rawWER: Double?; let gatedWER: Double?; let rawIns: Int; let gatedIns: Int }
        var rows: [Row] = []
        for c in cases {
            let r = gated[c.id]!
            var rawText = "", gatedText = "(skipped: no speech detected)"
            var rawMs = 0.0, gatedMs = 0.0
            do {
                let t0 = Date()
                rawText = try await stt.transcribe(samples: c.x, sampleRate: sampleRate)
                rawMs = Date().timeIntervalSince(t0) * 1000
                if r.hasSpeech {
                    let t1 = Date()
                    gatedText = try await stt.transcribe(samples: r.samples, sampleRate: sampleRate)
                    gatedMs = Date().timeIntervalSince(t1) * 1000
                }
            } catch { print("\(c.id): transcribe error \(error)"); continue }

            print("\n[\(c.id)] \(c.title)   hasSpeech=\(r.hasSpeech)  \(fmt(r.originalSeconds)) s -> \(fmt(r.outputSeconds)) s")
            print("  RAW   (\(fmt(rawMs, 0)) ms): \"\(rawText)\"")
            print("  GATED (\(r.hasSpeech ? fmt(gatedMs, 0) + " ms" : "no call")): \"\(gatedText)\"")
            if let ref = c.reference {
                let refW = normalizeWords(ref)
                let sr = score(refW, normalizeWords(rawText))
                let sg = r.hasSpeech ? score(refW, normalizeWords(gatedText)) : (wer: 1.0, ins: 0, del: refW.count, sub: 0)
                func stops(_ t: String) -> Int { t.filter { ".?!".contains($0) }.count }
                print("  sentence breaks: reference \(stops(ref)) raw \(stops(rawText)) gated \(r.hasSpeech ? stops(gatedText) : 0)")
                print("  WER raw \(fmt(sr.wer * 100))% (ins \(sr.ins) del \(sr.del) sub \(sr.sub))   gated \(fmt(sg.wer * 100))% (ins \(sg.ins) del \(sg.del) sub \(sg.sub))")
                rows.append(Row(id: c.id, rawWER: sr.wer, gatedWER: sg.wer, rawIns: sr.ins, gatedIns: sg.ins))
                if c.expectSpeech && c.id != "i" && sg.wer > sr.wer + 1e-9 { failures.append("\(c.id): gated WER \(fmt(sg.wer * 100))% > raw \(fmt(sr.wer * 100))%") }
            } else {
                let junkRaw = normalizeWords(rawText).count, junkGated = r.hasSpeech ? normalizeWords(gatedText).count : 0
                print("  junk words: raw \(junkRaw)   gated \(junkGated)")
                rows.append(Row(id: c.id, rawWER: nil, gatedWER: nil, rawIns: junkRaw, gatedIns: junkGated))
            }
        }

        print("\n== summary ==")
        print("case  rawWER  gatedWER  rawJunk  gatedJunk")
        for r in rows {
            print("\(r.id.padding(toLength: 5, withPad: " ", startingAt: 0))  \((r.rawWER.map { fmt($0 * 100) + "%" } ?? "-").padding(toLength: 6, withPad: " ", startingAt: 0))  \((r.gatedWER.map { fmt($0 * 100) + "%" } ?? "-").padding(toLength: 8, withPad: " ", startingAt: 0))  \(r.rawIns)        \(r.gatedIns)")
        }
        print(failures.isEmpty ? "\nALL CHECKS PASSED" : "\nCHECKS FAILED:\n  " + failures.joined(separator: "\n  "))
    }

    // MARK: one-voice experiment: where does a transcript difference come from?

    static func experiment(voice: String, seed: UInt64) async {
        guard #available(macOS 26.0, *) else { return }
        let stt = AppleTranscriber(); try? await stt.prepare()
        let safe = voice.replacingOccurrences(of: " ", with: "_")
        let a = clip("v_\(safe)_1", voice: voice, T3), b = clip("v_\(safe)_2", voice: voice, T4)
        func say(_ label: String, _ x: [Float]) async {
            let t = (try? await stt.transcribe(samples: x, sampleRate: sampleRate)) ?? "ERR"
            print("\(label.padding(toLength: 34, withPad: " ", startingAt: 0)) \(fmt(Double(x.count) / 16000)) s  \(t)")
        }
        // build as in the voices test (same RNG sequence is not needed; chips are random anyway)
        var rng = RNG(seed)
        var tl = Timeline()
        tl.silence(0.6); tl.say(a, T3); tl.gap(2.2); tl.say(b, T4); tl.silence(0.8)
        let clean = tl.x
        chipify(&tl, &rng, refPeak: max(0.5, peak(a)), riffles: 1)
        await say("clean raw (no chips)", clean)
        let g0 = SpeechGate.process(clean, sampleRate: sampleRate, params: gateParams)
        await say("clean gated", g0.samples)
        await say("chips raw", tl.x)
        let g1 = SpeechGate.process(tl.x, sampleRate: sampleRate, params: gateParams)
        await say("chips gated", g1.samples)
        // same sentence-1 audio followed by hiss only (no click in the pad), then sentence 2
        var tl2 = Timeline()
        tl2.silence(0.6); tl2.say(a, T3); tl2.gap(2.2); tl2.say(b, T4); tl2.silence(0.8)
        addHiss(&tl2.x, &rng, dB: -58)
        await say("hiss only raw", tl2.x)
        let g2 = SpeechGate.process(tl2.x, sampleRate: sampleRate, params: gateParams)
        await say("hiss only gated", g2.samples)
        // sentence 1 alone, raw vs gated
        var tl3 = Timeline(); tl3.silence(0.6); tl3.say(a, T3); tl3.silence(0.8); addHiss(&tl3.x, &rng, dB: -58)
        await say("sentence 1 alone, raw", tl3.x)
        await say("sentence 1 alone, gated", SpeechGate.process(tl3.x, sampleRate: sampleRate, params: gateParams).samples)
        // sentence 1 then sentence 2 with only a 0.7 s gap, ungated
        var tl4 = Timeline(); tl4.silence(0.6); tl4.say(a, T3); tl4.silence(0.7); tl4.say(b, T4); tl4.silence(0.8); addHiss(&tl4.x, &rng, dB: -58)
        await say("0.7 s gap, raw (no gate)", tl4.x)
        let an = SpeechGate.analyze(g1.samples.isEmpty ? clean : tl.x, sampleRate: sampleRate, params: gateParams)
        print("segments kept (s):", an.segments.map { "\(fmt(Double($0.start) / 16000, 2))-\(fmt(Double($0.end) / 16000, 2))" }.joined(separator: "  "))
        writeWav("\(outDir)/exp_\(safe)_chips_gated.wav", g1.samples)
        writeWav("\(outDir)/exp_\(safe)_chips_raw.wav", tl.x)
    }

    // MARK: how quiet can the talker be, and what about soft starts / trailing-off endings?

    static func levels(seed: UInt64) async {
        guard #available(macOS 26.0, *) else { return }
        let stt = AppleTranscriber(); try? await stt.prepare()
        let c = Clips()
        var scenarios: [(String, Timeline)] = []
        func build(_ label: String, gain: Float, shape: (([Float]) -> [Float])? = nil, hiss: Float = -64) {
            var rng = RNG(seed)
            var tl = Timeline()
            let f: ([Float]) -> [Float] = shape ?? { $0 }
            tl.silence(0.6); tl.say(f(c.s1), T1, gain: gain); tl.gap(2.2); tl.say(f(c.s2), T2, gain: gain)
            tl.gap(2.0); tl.say(f(c.s3), T3, gain: gain); tl.silence(0.8)
            chipify(&tl, &rng, refPeak: 0.5, riffles: 1, hiss: hiss)
            scenarios.append((label, tl))
        }
        for (g, label) in [(1.0, "normal (0 dB)"), (0.3, "-10 dB"), (0.1, "-20 dB"), (0.05, "-26 dB"), (0.03, "-30 dB"), (0.02, "-34 dB"), (0.01, "-40 dB")] as [(Float, String)] {
            build("level \(label)", gain: g)
        }
        // soft start: each sentence ramps up from -35 dB over its first 400 ms
        build("soft starts (ramp up over 400 ms)", gain: 1, shape: { x in
            var y = x; let n = min(6400, y.count)
            for i in 0..<n { y[i] *= Float(0.018 + (1 - 0.018) * Double(i) / Double(n)) }
            return y })
        // trailing off: each sentence fades to -35 dB over its last 700 ms
        build("trailing off (ramp down over 700 ms)", gain: 1, shape: { x in
            var y = x; let n = min(11200, y.count)
            for i in 0..<n { y[y.count - 1 - i] *= Float(0.018 + (1 - 0.018) * Double(i) / Double(n)) }
            return y })
        // both, on top of a -10 dB level
        build("-10 dB + soft starts + trailing off", gain: 0.3, shape: { x in
            var y = x
            let a = min(6400, y.count), b = min(11200, y.count)
            for i in 0..<a { y[i] *= Float(0.018 + (1 - 0.018) * Double(i) / Double(a)) }
            for i in 0..<b { y[y.count - 1 - i] *= Float(0.018 + (1 - 0.018) * Double(i) / Double(b)) }
            return y })
        print("scenario                                   hasSpeech  frames kept  weak kept   WER raw  WER gated")
        for (label, tl) in scenarios {
            let r = SpeechGate.process(tl.x, sampleRate: sampleRate, params: gateParams)
            let a = SpeechGate.analyze(tl.x, sampleRate: sampleRate, params: gateParams)
            let k = speechCoverage(tl.speech, segments: a.segments)
            let raw = (try? await stt.transcribe(samples: tl.x, sampleRate: sampleRate)) ?? ""
            let g = r.hasSpeech ? ((try? await stt.transcribe(samples: r.samples, sampleRate: sampleRate)) ?? "") : ""
            let ref = normalizeWords(tl.reference)
            let sr = score(ref, normalizeWords(raw)), sg = score(ref, normalizeWords(g))
            print("\(label.padding(toLength: 42, withPad: " ", startingAt: 0)) \(r.hasSpeech ? "true " : "false")      \(fmt(k.frames * 100).padding(toLength: 6, withPad: " ", startingAt: 0))%     \(fmt(k.weakest * 100).padding(toLength: 6, withPad: " ", startingAt: 0))%    \(fmt(sr.wer * 100).padding(toLength: 6, withPad: " ", startingAt: 0))%  \(fmt(sg.wer * 100))%\(a.usedFallback ? "  [fallback]" : "")")
        }
    }

    // MARK: timing on 60 s inputs, including the worst case (every frame needs the full pitch search)

    static func perf(seed: UInt64) {
        var rng = RNG(seed)
        let n = 16000 * 60
        func time(_ label: String, _ x: [Float]) {
            _ = SpeechGate.process(x)
            var t: [Double] = []
            for _ in 0..<30 {
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = SpeechGate.process(x)
                t.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            }
            t.sort()
            print("  \(label.padding(toLength: 52, withPad: " ", startingAt: 0)) min \(fmt(t[0], 2)) ms   median \(fmt(t[15], 2)) ms   max \(fmt(t[29], 2)) ms")
        }
        print("60 s of audio, \(n) samples:")
        if let k = buildCases(seed: seed).first(where: { $0.id == "k" }) { time("speech dictation (case k, \(fmt(Double(k.x.count) / 16000)) s)", k.x) }
        var brown = [Float](repeating: 0, count: n); var b = 0.0
        for i in 0..<n { b = 0.995 * b + 0.05 * rng.gauss(); brown[i] = Float(b) }
        time("loud brown noise (all frames pass the cheap tests)", brown)
        time("white noise at -20 dB", (0..<n).map { _ in Float(0.1 * rng.gauss()) })
        time("loud pitched buzz 140 Hz (all frames voiced)", (0..<n).map { i in
            let t = Double(i) / 16000
            return Float(0.3 * (sin(2 * Double.pi * 140 * t) + 0.5 * sin(2 * Double.pi * 280 * t) + 0.3 * sin(2 * Double.pi * 420 * t)))
        })
        time("digital silence", [Float](repeating: 0, count: n))
    }

    // MARK: robustness: odd lengths, odd content, other sample rates (must never crash, output must be sane)

    static func fuzz(seed: UInt64) {
        var rng = RNG(seed)
        var checked = 0, withSpeech = 0
        func check(_ x: [Float], _ sr: Double, _ label: String) {
            let r = SpeechGate.process(x, sampleRate: sr)
            checked += 1
            if r.hasSpeech { withSpeech += 1 }
            // sanity: output never longer than input + a few pauses, never NaN, flags consistent
            let finite = r.samples.allSatisfy { $0.isFinite && abs($0) <= 1.5 }
            let sane = finite && r.samples.count <= x.count + 10 * Int(sr) && (r.hasSpeech || r.samples.isEmpty)
            if !sane { print("FUZZ FAIL: \(label)  n=\(x.count) sr=\(sr) out=\(r.samples.count) hasSpeech=\(r.hasSpeech)") }
        }
        // every length from 0 to 3000 samples, three kinds of content
        for n in 0...3000 {
            check((0..<n).map { _ in Float(rng.gauss() * 0.1) }, 16000, "noise \(n)")
            check((0..<n).map { Float(0.5 * sin(2 * Double.pi * 150 * Double($0) / 16000)) }, 16000, "sine \(n)")
            if n % 7 == 0 { check([Float](repeating: n % 2 == 0 ? 1 : -1, count: n), 16000, "dc/clip \(n)") }
        }
        // longer odd content
        check([Float](repeating: 0, count: 16000 * 30), 16000, "30 s zeros")
        check((0..<16000 * 20).map { _ in Float(rng.uniform(-1, 1)) }, 16000, "20 s full-scale white noise")
        check((0..<16000 * 20).map { $0 % 2 == 0 ? 1 : -1 }, 16000, "20 s Nyquist square")
        check((0..<16000 * 20).map { Float(0.9 * sin(2 * Double.pi * 120 * Double($0) / 16000)) }, 16000, "20 s loud 120 Hz tone")
        check((0..<16000 * 20).map { _ in Float(1e-9 * rng.gauss()) }, 16000, "20 s denormal-level noise")
        // real material at other sample rates (simple resampling is fine for a robustness check)
        let c = Clips()
        var tl = Timeline()
        tl.silence(0.5); tl.say(c.s1, T1); tl.gap(2); tl.say(c.s2, T2); tl.silence(0.5)
        chipify(&tl, &rng, refPeak: 0.5)
        for sr in [8000.0, 11025, 22050, 32000, 44100, 48000] {
            let ratio = sr / 16000
            let m = Int(Double(tl.x.count) * ratio)
            var y = [Float](repeating: 0, count: m)
            for i in 0..<m {
                let t = Double(i) / ratio, k = Int(t), f = Float(t - Double(k))
                y[i] = tl.x[min(k, tl.x.count - 1)] * (1 - f) + tl.x[min(k + 1, tl.x.count - 1)] * f
            }
            if sr < 16000 { // crude anti-alias for the down-conversion
                for i in stride(from: y.count - 1, to: 0, by: -1) { y[i] = 0.5 * (y[i] + y[i - 1]) }
            }
            let r = SpeechGate.process(y, sampleRate: sr)
            print("  sample rate \(Int(sr)) Hz: hasSpeech=\(r.hasSpeech)  \(fmt(r.originalSeconds)) s -> \(fmt(r.outputSeconds)) s")
            checked += 1
        }
        print("fuzz: \(checked) inputs processed without a crash (\(withSpeech) flagged as speech)")
    }

    // MARK: how often does the RAW recognizer produce junk from chips, and does the gate remove it?

    static func junkStudy(runs: Int) async {
        guard #available(macOS 26.0, *) else { return }
        let stt = AppleTranscriber()
        do { try await stt.prepare() } catch { print("prepare failed"); return }
        let c = Clips()
        var rng = RNG(99)
        var chipsOnly = 0, rawJunky = 0, gateSaid = 0, gatedJunky = 0
        var examples: [String] = []
        var spInsRaw = 0, spInsGated = 0, spDelRaw = 0, spDelGated = 0, spN = 0, spWordsRaw = 0, spWordsGated = 0
        for k in 0..<runs {
            // chips only, three styles, loud (peak up to 0.98)
            for style in 0..<3 {
                var x = [Float](repeating: 0, count: 16000 * (style == 2 ? 10 : 7))
                let pk = Float(rng.uniform(0.3, 0.98))
                let nClicks = style == 0 ? Int(rng.uniform(5, 13)) : (style == 1 ? Int(rng.uniform(3, 7)) : 40)
                for _ in 0..<nClicks {
                    add(&x, makeClick(&rng, kind: randomKind(&rng, thudShare: 0.1), peak: pk * Float(rng.uniform(0.4, 1.0))),
                        at: Int(rng.uniform(0.2, Double(x.count) / 16000 - 0.5) * 16000))
                }
                for _ in 0..<(style == 0 ? 0 : (style == 1 ? Int(rng.uniform(1, 4)) : 4)) {
                    addRiffle(&x, &rng, at: Int(rng.uniform(0.2, Double(x.count) / 16000 - 1.5) * 16000), peak: pk, thudShare: 0.1)
                }
                addHiss(&x, &rng, dB: Float(rng.uniform(-66, -50)))
                let r = SpeechGate.process(x, sampleRate: sampleRate, params: gateParams)
                let raw = (try? await stt.transcribe(samples: x, sampleRate: sampleRate)) ?? ""
                let g = r.hasSpeech ? ((try? await stt.transcribe(samples: r.samples, sampleRate: sampleRate)) ?? "") : ""
                chipsOnly += 1
                if !normalizeWords(raw).isEmpty { rawJunky += 1; if examples.count < 8 { examples.append("style \(style) seed \(k): \"\(raw)\"") } }
                if r.hasSpeech { gateSaid += 1 }
                if !normalizeWords(g).isEmpty { gatedJunky += 1 }
            }
            // speech + dense chips in pauses and on words
            var tl = Timeline()
            tl.silence(0.5); tl.say(c.s1, T1); tl.gap(2.0); tl.say(c.s2, T2); tl.gap(2.0); tl.say(c.s3, T3); tl.silence(0.8)
            chipify(&tl, &rng, refPeak: 0.9, riffles: 2, onWords: 8, thudShare: 0.1)
            let r = SpeechGate.process(tl.x, sampleRate: sampleRate, params: gateParams)
            let raw = (try? await stt.transcribe(samples: tl.x, sampleRate: sampleRate)) ?? ""
            let g = r.hasSpeech ? ((try? await stt.transcribe(samples: r.samples, sampleRate: sampleRate)) ?? "") : ""
            let ref = normalizeWords(tl.reference)
            let sr = score(ref, normalizeWords(raw)), sg = score(ref, normalizeWords(g))
            spN += 1; spInsRaw += sr.ins; spInsGated += sg.ins; spDelRaw += sr.del; spDelGated += sg.del
            spWordsRaw += sr.ins + sr.del + sr.sub; spWordsGated += sg.ins + sg.del + sg.sub
            if sg.ins + sg.del + sg.sub > sr.ins + sr.del + sr.sub { print("seed \(k): gated worse\n  raw:   \(raw)\n  gated: \(g)") }
        }
        print("== junk study (\(runs) seeds) ==")
        print("chips-only recordings: \(chipsOnly)")
        print("  raw recognizer returned words:   \(rawJunky)")
        print("  gate said 'speech':              \(gateSaid)   (gated recognizer returned words: \(gatedJunky))")
        for e in examples { print("    raw junk example: \(e)") }
        print("speech + chips: \(spN) recordings, word errors raw \(spWordsRaw) vs gated \(spWordsGated)  (inserted words raw \(spInsRaw) vs gated \(spInsGated); deleted raw \(spDelRaw) vs gated \(spDelGated))")
    }

    // MARK: every installed English voice (different pitch ranges / styles)

    static func voices(skipSTT: Bool, seed: UInt64) async {
        // Parse `say -v ?` for English voices; skip pure novelty voices (not human-like speech).
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/say"); p.arguments = ["-v", "?"]
        let pipe = Pipe(); p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let novelty: Set<String> = ["Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos", "Wobble", "Good News", "Jester",
                                    "Organ", "Superstar", "Trinoids", "Whisper", "Zarvox"]
        var names: [String] = []
        for line in listing.split(separator: "\n") {
            guard let r = line.range(of: #"\s{2,}[a-z]{2}_[A-Z]{2}"#, options: .regularExpression) else { continue }
            let name = String(line[line.startIndex..<r.lowerBound])
            let locale = line[r].trimmingCharacters(in: .whitespaces)
            if locale.hasPrefix("en_") && !novelty.contains(name) && !names.contains(name) { names.append(name) }
        }
        print("== \(names.count) English voices ==")
        var rng = RNG(seed)
        let rp: Float = 0.5
        var stt: AnyObject? = nil
        if !skipSTT, #available(macOS 26.0, *) { let t = AppleTranscriber(); try? await t.prepare(); stt = t }
        var bad = 0
        var totRaw = 0, totGated = 0, totRef = 0, better = 0, worse = 0, same = 0, covBad = 0, n = 0
        let seedsPerVoice = Int(ProcessInfo.processInfo.environment["GATE_VOICE_SEEDS"] ?? "") ?? 1
        for name in names {
            let safe = name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
            let a = clip("v_\(safe)_1", voice: name, T3), b = clip("v_\(safe)_2", voice: name, T4)
            guard !a.isEmpty, !b.isEmpty else { print("\(name): no audio"); continue }
            for _ in 0..<seedsPerVoice {
            var tl = Timeline()
            tl.silence(0.6); tl.say(a, T3); tl.gap(2.2); tl.say(b, T4); tl.silence(0.8)
            chipify(&tl, &rng, refPeak: max(rp, peak(a)), riffles: 1)
            let r = SpeechGate.process(tl.x, sampleRate: sampleRate, params: gateParams)
            let an = SpeechGate.analyze(tl.x, sampleRate: sampleRate, params: gateParams)
            let k = speechCoverage(tl.speech, segments: an.segments)
            var line = "\(name.padding(toLength: 24, withPad: " ", startingAt: 0)) hasSpeech=\(r.hasSpeech) \(fmt(r.originalSeconds))s->\(fmt(r.outputSeconds))s  frames kept \(fmt(k.frames * 100))%  weak kept \(fmt(k.weakest * 100))%\(an.usedFallback ? "  [fallback]" : "")"
            if k.frames < 0.99 || !r.hasSpeech { bad += 1; covBad += 1 }
            n += 1
            if #available(macOS 26.0, *), let t = stt as? AppleTranscriber {
                let raw = (try? await t.transcribe(samples: tl.x, sampleRate: sampleRate)) ?? "ERR"
                let g = r.hasSpeech ? ((try? await t.transcribe(samples: r.samples, sampleRate: sampleRate)) ?? "ERR") : ""
                let ref = normalizeWords(tl.reference)
                let sr = score(ref, normalizeWords(raw)), sg = score(ref, normalizeWords(g))
                line += "  WER raw \(fmt(sr.wer * 100))% gated \(fmt(sg.wer * 100))%"
                let er = sr.ins + sr.del + sr.sub, eg = sg.ins + sg.del + sg.sub
                totRaw += er; totGated += eg; totRef += ref.count
                if eg < er { better += 1 } else if eg > er { worse += 1; line += "\n      raw:   \(raw)\n      gated: \(g)" } else { same += 1 }
            }
            print(line)
            }
        }
        print("recordings: \(n)   speech frames lost (<99%) or no speech: \(covBad)")
        if totRef > 0 {
            print("word errors over all recordings: raw \(totRaw) vs gated \(totGated)  (of \(totRef) reference words)")
            print("per recording: gated better \(better), same \(same), worse \(worse)")
        }
    }

    // MARK: per-frame dump

    static func dump(_ c: Case) {
        var p = gateParams; p.computeAllFeatures = true
        let a = SpeechGate.analyze(c.x, sampleRate: sampleRate, params: p)
        print("case \(c.id): floor \(fmt(Double(a.floorDB))) dB, speechRef \(fmt(Double(a.speechRefDB))) dB, gate \(fmt(Double(a.gateDB))) dB, voiced \(fmt(a.voicedSeconds, 2)) s, hasSpeech \(a.hasSpeech)")
        print("  t(s)    dB    ratio crest period  voiced accepted  trueSpeech kept")
        for i in 0..<a.dB.count where a.dB[i] > -70 {
            let t0 = i * a.hop
            var truth = ""
            if let sp = c.speechOnly {
                var s: Float = 0; for k in t0..<min(sp.count, t0 + a.win) { s += sp[k] * sp[k] }
                truth = s / Float(a.win) > 1e-6 ? "S" : "."
            }
            let mid = t0 + a.win / 2
            let kept = a.segments.contains { mid >= $0.start && mid < $0.end } ? "K" : "."
            print(String(format: "  %6.2f %6.1f %5.2f %5.1f %5.2f   %@      %@        %@        %@", Double(t0) / 16000, a.dB[i], a.ratio[i], a.crest[i], a.period[i],
                         a.voiced[i] ? "V" : ".", a.accepted[i] ? "A" : ".", truth, kept))
        }
    }

    // MARK: stress over many seeds (gate only)

    static func stress(seeds: Int) {
        var chipsOnlyBad = 0, chipsOnlyTotal = 0
        var speechBad = 0, speechTotal = 0, worstCoverage = 1.0, worstWeak = 1.0
        var quietBad = 0, quietTotal = 0
        for s in 1...seeds {
            let cs = buildCases(seed: UInt64(1000 + s))
            for c in cs {
                let r = SpeechGate.process(c.x, sampleRate: sampleRate, params: gateParams)
                switch c.id {
                case "d", "d2", "f", "f2", "f3":
                    chipsOnlyTotal += 1
                    if r.hasSpeech { chipsOnlyBad += 1; print("seed \(s) case \(c.id): FALSE POSITIVE (chips/noise only gave hasSpeech)") }
                default:
                    guard let sp = c.speechOnly else { break }
                    let a = SpeechGate.analyze(c.x, sampleRate: sampleRate, params: gateParams)
                    let k = speechCoverage(sp, segments: a.segments)
                    if c.id == "e" { quietTotal += 1; if !r.hasSpeech || k.frames < 0.995 { quietBad += 1 } }
                    speechTotal += 1
                    worstCoverage = min(worstCoverage, k.frames); worstWeak = min(worstWeak, k.weakest)
                    if !r.hasSpeech || k.frames < 0.995 {
                        speechBad += 1
                        print("seed \(s) case \(c.id): speech missed (hasSpeech \(r.hasSpeech), frames kept \(fmt(k.frames * 100))%, weak kept \(fmt(k.weakest * 100))%)")
                    }
                }
            }
        }
        // chips only with NO hiss at all (voice-processed audio can be near-digital silence between sounds)
        var noHissBad = 0, noHissTotal = 0
        for sd in 1...seeds {
            var rng = RNG(UInt64(5000 + sd))
            for style in 0..<4 {
                var x = [Float](repeating: 0, count: 16000 * 10)
                let pk = Float(rng.uniform(0.2, 0.98))
                let nClicks = style == 0 ? 8 : (style == 1 ? 25 : 60)
                for _ in 0..<nClicks { add(&x, makeClick(&rng, kind: randomKind(&rng, thudShare: style == 3 ? 0.5 : 0.15), peak: pk * Float(rng.uniform(0.3, 1.0))), at: Int(rng.uniform(0.1, 9.0) * 16000)) }
                for _ in 0..<(style == 0 ? 0 : 4) { addRiffle(&x, &rng, at: Int(rng.uniform(0.1, 8.0) * 16000), peak: pk, thudShare: style == 3 ? 0.5 : 0.15) }
                noHissTotal += 1
                if SpeechGate.process(x, sampleRate: sampleRate, params: gateParams).hasSpeech { noHissBad += 1 }
            }
        }
        print("  chips only, no hiss at all -> false positives: \(noHissBad) / \(noHissTotal)")
        print("stress over \(seeds) seeds:")
        print("  chips/noise only -> false positives: \(chipsOnlyBad) / \(chipsOnlyTotal)")
        print("  speech cases -> missed or <99.5% frames kept: \(speechBad) / \(speechTotal)   (quiet case: \(quietBad) / \(quietTotal))")
        print("  worst speech-frame coverage \(fmt(worstCoverage * 100, 2))%, worst weak-frame coverage \(fmt(worstWeak * 100, 2))%")
    }
}
