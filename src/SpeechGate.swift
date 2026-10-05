import Foundation
import Accelerate

// SpeechGate
// ----------
// Cleans one complete recording before it goes to the speech recognizer.
//
// The problem it solves: the user dictates while clicking poker chips together. A chip click is a
// very short, broadband burst; a recognizer that hears one in a pause may write a junk word, and a
// recording that is only chips may come back as "Yeah." or similar. The user also pauses a lot
// (1-3 s), which is wasted audio.
//
// What it does:
//   1. Finds the stretches that contain VOICED speech (vowels and voiced consonants: the sound made
//      with vibrating vocal cords). Voiced speech is the one thing a chip can't imitate: it is
//      periodic (a repeating waveform at the speaker's pitch, 70-400 Hz) with a steady loudness and
//      pitch from one 16 ms step to the next, it carries most of its energy below ~1 kHz, and it
//      lasts tens of milliseconds. A click has none of those (a low "thump" fools a plain periodicity
//      test, so the test also demands steady amplitude and a continuous pitch over >= 80 ms).
//   2. Keeps each voiced stretch plus a pad of original audio around it (before: 200 ms, after:
//      350 ms) so unvoiced consonants (s, f, t, k, sh) at the edges of words survive. The pad keeps
//      growing (up to 250 ms before / 450 ms after) while the neighbouring audio is still loud, smooth
//      noise, such as the long "-sts" of "costs" or the "-ked" of "fixed".
//   3. Replaces everything else (silence, clicks, riffles) with digital silence, capped at a short
//      pause, so long gaps are compressed but sentence boundaries are still audible to the recognizer.
//   4. Reports hasSpeech == false when there is not enough voiced speech (chips only, silence, hum).
//   5. Whispering has no pitch, so if NO voiced speech was found, a fallback looks for long stretches
//      (>= 0.5 s in total) of loud, smooth sound and passes those on instead of dropping the recording.
//
// Audio inside a kept stretch is never altered (apart from 5 ms fades at the cut points).
//
// Cost: ~1.5 ms for 60 s of audio, ~1.9 ms worst case (decimate to 4 kHz, one correlation per loud frame).

enum SpeechGate {

    struct Result {
        let samples: [Float]        // processed 16 kHz mono audio to feed the recognizer ([] when !hasSpeech)
        let hasSpeech: Bool         // false -> caller skips transcription entirely ("No speech detected")
        let originalSeconds: Double
        let outputSeconds: Double
    }

    /// Input: mono Float32 PCM in [-1, 1] at `sampleRate` (the app passes 16000).
    static func process(_ samples: [Float], sampleRate: Double = 16000) -> Result {
        process(samples, sampleRate: sampleRate, params: Params())
    }

    // MARK: - Tunables

    struct Params {
        // Padding kept around every voiced stretch (original audio).
        var padBeforeMs = 200.0
        var padAfterMs = 350.0
        /// Beyond the fixed pad, a kept stretch keeps growing while the audio next to it is still loud,
        /// smooth noise (the long "s" of "costs", a breathy word ending), up to this much more.
        var extendBeforeMs = 250.0
        var extendAfterMs = 450.0
        /// ... bridging dips (a "t" closure) of up to this many frames.
        var extendGapFrames = 6
        /// Longest silence inserted where a gap was cut out (shorter gaps keep their length, as silence).
        var pauseMs = 250.0
        /// Kept stretches closer than this are joined and the original audio between them is kept.
        var mergeGapMs = 100.0

        // What counts as a voiced stretch.
        /// A voiced run must span at least this long (a chip click or a single clack is < 40 ms).
        var minRunMs = 80.0
        /// Holes of up to this many frames inside a voiced run are bridged (voicing dips at stops).
        var holeFillFrames = 2
        /// A shorter voiced fragment (>= weakRunMs) still counts if a solid run is within weakLinkMs of it:
        /// word starts/ends often voice only briefly. Fragments far from any solid run are ignored.
        var weakRunMs = 48.0
        var weakLinkMs = 200.0
        /// hasSpeech needs at least this much voiced time in total ...
        var minVoicedTotalMs = 140.0
        /// ... and at least one voiced run this long.
        var minStrongRunMs = 96.0

        // Per-frame voicedness tests.
        /// Periodicity score (autocorrelation peak at a 70-400 Hz pitch lag, normalized by the LARGER of the two
        /// window energies, so a decaying thump scores low): voiced speech 0.7-0.98, noise/clicks < 0.45.
        var periodMin: Float = 0.55
        /// Frames at least this periodic (and clearly low-frequency) set the reference speech level.
        var periodStrong: Float = 0.75
        /// Fraction of the frame's energy below ~1 kHz. Voiced speech > 0.3, chip clicks < 0.1.
        var ratioMin: Float = 0.20
        /// Peak 4 ms block energy / mean block energy within the 32 ms frame. Steady voiced speech 1.3-3,
        /// word onsets up to ~4.5, single clicks mostly 5-8.
        var crestMax: Float = 4.5
        /// Consecutive voiced frames must have a consistent pitch (lag ratio within this), else the run is broken.
        var pitchJump: Float = 1.25
        /// "Smooth noise next to speech" test used for pad extension.
        var softCrestMax: Float = 4.5
        /// A recording whose loudest voiced level is not at least this far above its noise floor is not speech
        /// (rejects constant hum, which is periodic and steady: its level stays within ~1 dB of its own floor).
        var minSpeechAboveFloorDB: Float = 6

        // Loudness gate (dB, mean-square scale: 0 dB = full-scale square wave).
        var absMinDB: Float = -66
        var floorPercentile = 0.15
        var floorMarginDB: Float = 10
        /// The gate is never closer than this to the noise floor (keeps steady hum out of the "voiced" set).
        var floorMinMarginDB: Float = 4
        /// The gate never sits more than this far below the speech reference level.
        var capBelowSpeechDB: Float = 30

        // Fallback for speech without a pitch (whispering): used ONLY when no voiced speech was found.
        // Long stretches of loud, smooth (non-impulsive) sound are handed to the recognizer; clicks are
        // sparse and spiky and never add up to this.
        var sustainedAboveFloorDB: Float = 15
        var sustainedCrestMax: Float = 3.0
        var sustainedMinRunMs = 240.0
        var sustainedMinTotalMs = 500.0

        var fadeMs = 5.0

        /// Debug only: compute every feature for every loud frame instead of skipping early.
        var computeAllFeatures = false
    }

    // MARK: - Analysis result (internal; the test harness reads it)

    struct Analysis {
        var sampleCount = 0
        var sampleRate = 16000.0
        var hop = 0
        var win = 0
        var dB: [Float] = []
        var period: [Float] = []
        var ratio: [Float] = []
        var crest: [Float] = []
        var lag: [Int] = []
        var voiced: [Bool] = []          // after loudness gate, before hole fill / run filter
        var accepted: [Bool] = []        // frames inside accepted runs
        var floorDB: Float = -120
        var gateDB: Float = -120
        var speechRefDB: Float = -120
        var voicedSeconds = 0.0
        var longestRunSeconds = 0.0
        var hasSpeech = false
        var usedFallback = false         // speech accepted by the no-pitch fallback (whisper), not by voicing
        var sustainedSeconds = 0.0
        var segments: [(start: Int, end: Int)] = []   // sample ranges kept, padded and merged
    }

    // MARK: - Entry point

    static func process(_ x: [Float], sampleRate sr: Double, params p: Params) -> Result {
        let n = x.count
        let original = sr > 0 ? Double(n) / sr : 0
        guard n > 0 else {
            return Result(samples: [], hasSpeech: false, originalSeconds: original, outputSeconds: 0)
        }
        // Unsupported sample rate: do not guess, pass the audio through untouched.
        guard sr >= 4000, sr <= 400_000 else {
            return Result(samples: x, hasSpeech: true, originalSeconds: original, outputSeconds: original)
        }
        let a = analyze(x, sampleRate: sr, params: p)
        guard a.hasSpeech, !a.segments.isEmpty else {
            return Result(samples: [], hasSpeech: false, originalSeconds: original, outputSeconds: 0)
        }
        let out = render(x, segments: a.segments, sampleRate: sr, params: p)
        return Result(samples: out, hasSpeech: true, originalSeconds: original,
                      outputSeconds: Double(out.count) / sr)
    }

    // MARK: - Analysis

    // Geometry, in samples of the 4 kHz decimated signal (everything is a multiple of one 4 ms block):
    //   block = 16  (4 ms)      frame window = 8 blocks (32 ms)      hop = 4 blocks (16 ms)
    private static let blockD = 16
    private static let blocksPerWin = 8
    private static let blocksPerHop = 4

    static func analyze(_ x: [Float], sampleRate sr: Double, params p: Params) -> Analysis {
        var A = analyzeVoiced(x, sampleRate: sr, params: p)
        if !A.hasSpeech { applySustainedFallback(&A, params: p) }
        return A
    }

    /// No voiced speech was found. Is there still a long stretch of loud, smooth sound (whispering)?
    /// If so, say "speech" and keep just those stretches; the recognizer makes the final call.
    private static func applySustainedFallback(_ A: inout Analysis, params p: Params) {
        let F = A.dB.count
        guard F > 0, A.hop > 0 else { return }
        let hopSec = Double(A.hop) / A.sampleRate, winSec = Double(A.win) / A.sampleRate
        let gate = max(p.absMinDB, A.floorDB + p.sustainedAboveFloorDB)
        var ok = (0..<F).map { A.dB[$0] >= gate && A.crest[$0] <= p.sustainedCrestMax }
        // bridge dips of up to 2 frames
        var i = 0
        while i < F {
            if ok[i] { i += 1; continue }
            var j = i
            while j < F && !ok[j] { j += 1 }
            if i > 0 && j < F && j - i <= 2 { for k in i..<j { ok[k] = true } }
            i = j
        }
        var runs: [(Int, Int)] = []
        var total = 0.0
        i = 0
        while i < F {
            if !ok[i] { i += 1; continue }
            var j = i
            while j < F && ok[j] { j += 1 }
            let span = Double(j - i - 1) * hopSec + winSec
            if span * 1000 >= p.sustainedMinRunMs { runs.append((i, j - 1)); total += span }
            i = j
        }
        A.sustainedSeconds = total
        guard total * 1000 >= p.sustainedMinTotalMs else { return }

        let n = A.sampleCount, sr = A.sampleRate
        let padB = Int(p.padBeforeMs / 1000 * sr), padA = Int(p.padAfterMs / 1000 * sr)
        let mergeGap = Int(p.mergeGapMs / 1000 * sr)
        var segs: [(start: Int, end: Int)] = []
        for (f0, f1) in runs {
            let s = max(0, f0 * A.hop - padB), e = min(n, f1 * A.hop + A.win + padA)
            if var last = segs.last, s <= last.end + mergeGap {
                last.end = max(last.end, e); segs[segs.count - 1] = last
            } else { segs.append((s, e)) }
        }
        A.segments = segs
        A.usedFallback = true
        A.hasSpeech = true
    }

    private static func analyzeVoiced(_ x: [Float], sampleRate sr: Double, params p: Params) -> Analysis {
        var A = Analysis()
        let n = x.count
        A.sampleCount = n
        A.sampleRate = sr

        let dec = max(1, Int((sr / 4000).rounded()))
        let dSr = sr / Double(dec)
        let blk = blockD * dec
        let hop = blk * blocksPerHop
        let win = blk * blocksPerWin
        let winD = blockD * blocksPerWin
        let hopD = blockD * blocksPerHop
        A.hop = hop
        A.win = win
        let hopSec = Double(hop) / sr
        let winSec = Double(win) / sr

        // Pitch search range (lags in decimated samples): 400 Hz ... 70 Hz.
        let lagMin = max(2, Int(dSr / 400))
        let lagMax = Int(dSr / 70)

        let F = max(1, (n + hop - 1) / hop)               // frames; frame i covers [i*hop, i*hop + win)

        // --- low-pass FIR (cutoff ~1 kHz, DC gain 1) + decimation to ~4 kHz ---------------------
        let taps = 8 * dec
        var h = [Float](repeating: 0, count: taps)
        do {
            let fc = 1000.0 / sr                             // cycles per sample
            let c = Double(taps - 1) / 2
            var sum = 0.0
            for k in 0..<taps {
                let t = Double(k) - c
                let sinc = t == 0 ? 2 * fc : sin(2 * Double.pi * fc * t) / (Double.pi * t)
                let w = 0.54 - 0.46 * cos(2 * Double.pi * Double(k) / Double(taps - 1))
                h[k] = Float(sinc * w)
                sum += sinc * w
            }
            for k in 0..<taps { h[k] = Float(Double(h[k]) / sum) }
        }

        let Nd = F * hopD + winD + lagMax + 4                // decimated samples needed
        let lead = taps / 2
        let xpLen = lead + max(n, (Nd + 1) * dec) + taps + win + dec * 4
        var xp = [Float](repeating: 0, count: xpLen)
        x.withUnsafeBufferPointer { src in
            xp.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.advanced(by: lead).update(from: src.baseAddress!, count: n)
            }
        }
        var d = [Float](repeating: 0, count: Nd)
        xp.withUnsafeBufferPointer { xpp in
            h.withUnsafeBufferPointer { hp in
                d.withUnsafeMutableBufferPointer { dp in
                    vDSP_desamp(xpp.baseAddress!, vDSP_Stride(dec), hp.baseAddress!,
                                dp.baseAddress!, vDSP_Length(Nd), vDSP_Length(taps))
                }
            }
        }

        // --- 4 ms block energies at full rate -> frame energy (dB) and crest ----------------------
        let nBlocks = F * blocksPerHop + blocksPerWin
        var bms = [Float](repeating: 0, count: nBlocks)
        xp.withUnsafeBufferPointer { xpp in
            bms.withUnsafeMutableBufferPointer { bp in
                let base = xpp.baseAddress!.advanced(by: lead)
                for b in 0..<nBlocks {
                    var e: Float = 0
                    vDSP_svesq(base.advanced(by: b * blk), 1, &e, vDSP_Length(blk))
                    bp[b] = e / Float(blk)
                }
            }
        }
        A.dB = [Float](repeating: -120, count: F)
        A.crest = [Float](repeating: 0, count: F)
        var frameMS = [Float](repeating: 0, count: F)
        for i in 0..<F {
            var s: Float = 0, m: Float = 0
            let b0 = i * blocksPerHop
            for b in b0..<(b0 + blocksPerWin) { let v = bms[b]; s += v; if v > m { m = v } }
            let mean = s / Float(blocksPerWin)
            frameMS[i] = mean
            A.dB[i] = 10 * log10f(mean + 1e-10)
            A.crest[i] = m / (mean + 1e-12)
        }

        // --- noise floor of this recording ---------------------------------------------------------
        let sortedDB = A.dB.sorted()
        let floorIdx = min(F - 1, Int(p.floorPercentile * Double(F - 1)))
        A.floorDB = sortedDB[floorIdx]

        // --- per-frame voicedness features (loud frames only) -------------------------------------
        A.period = [Float](repeating: 0, count: F)
        A.ratio = [Float](repeating: 0, count: F)
        A.lag = [Int](repeating: 0, count: F)
        var like = [Bool](repeating: false, count: F)      // voiced-looking, before the loudness gate
        var corr = [Float](repeating: 0, count: lagMax + 2)
        var score = [Float](repeating: 0, count: lagMax + 2)

        d.withUnsafeBufferPointer { dp in
            let dBase = dp.baseAddress!
            for i in 0..<F where A.dB[i] >= p.absMinDB {
                let s = i * hopD
                var e0: Float = 0
                vDSP_svesq(dBase.advanced(by: s), 1, &e0, vDSP_Length(winD))
                let ratio = (e0 / Float(winD)) / (frameMS[i] + 1e-12)
                A.ratio[i] = ratio
                if !p.computeAllFeatures {
                    if ratio < p.ratioMin || A.crest[i] > p.crestMax { continue }
                }
                if e0 <= 1e-12 { continue }

                // Autocorrelation of the low-passed frame for lags 0...lagMax+1 (one vDSP call).
                corr.withUnsafeMutableBufferPointer { cp in
                    vDSP_conv(dBase.advanced(by: s), 1, dBase.advanced(by: s), 1,
                              cp.baseAddress!, 1, vDSP_Length(lagMax + 2), vDSP_Length(winD))
                }
                // score(lag) = r(lag) / max(E0, E_lag). E_lag (energy of the window shifted by `lag`) slides.
                var el = Double(e0)
                var best: Float = 0
                for lag in 1...(lagMax + 1) {
                    let out = Double(dBase[s + lag - 1]), inn = Double(dBase[s + lag - 1 + winD])
                    el += inn * inn - out * out
                    let sc = Float(Double(corr[lag]) / max(Double(e0), max(el, 1e-20)))
                    score[lag] = sc
                    if lag >= lagMin && lag <= lagMax && sc > best { best = sc }
                }
                // Fundamental period = the smallest lag that is a local peak within 10% of the best score.
                var bestLag = 0
                if best > 0 {
                    for lag in lagMin...lagMax where score[lag] >= 0.9 * best
                        && score[lag] >= score[lag - 1] && score[lag] >= score[lag + 1] {
                        bestLag = lag; break
                    }
                }
                A.period[i] = best
                A.lag[i] = bestLag
                like[i] = bestLag > 0 && best >= p.periodMin && ratio >= p.ratioMin && A.crest[i] <= p.crestMax
            }
        }

        // --- reference speech level, then the loudness gate ---------------------------------------
        var strongDB: [Float] = []
        for i in 0..<F where like[i] && A.period[i] >= p.periodStrong && A.ratio[i] >= 0.4 {
            strongDB.append(A.dB[i])
        }
        let minSeedFrames = 3
        A.voiced = [Bool](repeating: false, count: F)
        A.accepted = A.voiced
        if strongDB.count < minSeedFrames { return A }
        strongDB.sort()
        A.speechRefDB = strongDB[min(strongDB.count - 1, Int(0.9 * Double(strongDB.count - 1)))]
        // A steady periodic hum has no level range: speech has to stand clear of the noise floor.
        if A.speechRefDB - A.floorDB < p.minSpeechAboveFloorDB { return A }
        A.gateDB = max(p.absMinDB, A.floorDB + p.floorMinMarginDB,
                       min(A.floorDB + p.floorMarginDB, A.speechRefDB - p.capBelowSpeechDB))

        for i in 0..<F { A.voiced[i] = like[i] && A.dB[i] >= A.gateDB }

        // --- bridge small holes (they carry no pitch of their own) ---------------------------------
        var bridged = A.voiced
        var wild = [Bool](repeating: false, count: F)       // bridged frames: pitch unknown, match anything
        var i = 0
        while i < F {
            if A.voiced[i] { i += 1; continue }
            var j = i
            while j < F && !A.voiced[j] { j += 1 }
            if i > 0 && j < F && (j - i) <= p.holeFillFrames {
                for k in i..<j { bridged[k] = true; wild[k] = true }
            }
            i = j
        }

        // --- runs: consecutive voiced frames with a continuous pitch, long enough ---------------------
        func consistent(_ a: Int, _ b: Int) -> Bool {
            let hi = Float(max(a, b)), lo = Float(min(a, b))
            let r = hi / lo
            // same pitch, or an octave apart (the best lag can hop between a period and twice a period)
            return r <= p.pitchJump || (r >= 2 / p.pitchJump && r <= 2 * p.pitchJump)
        }
        A.accepted = [Bool](repeating: false, count: F)
        var runs: [(Int, Int)] = []
        var weak: [(Int, Int)] = []
        i = 0
        while i < F {
            if !bridged[i] { i += 1; continue }
            // split the bridged stretch into chains of consistent pitch
            var j = i
            var chainStart = i
            var lastLag = 0
            func closeChain(_ endExclusive: Int) {
                guard endExclusive > chainStart else { return }
                let spanSec = Double(endExclusive - chainStart - 1) * hopSec + winSec
                if spanSec * 1000 >= p.minRunMs {
                    runs.append((chainStart, endExclusive - 1))
                    A.voicedSeconds += spanSec
                    A.longestRunSeconds = max(A.longestRunSeconds, spanSec)
                } else if spanSec * 1000 >= p.weakRunMs {
                    weak.append((chainStart, endExclusive - 1))
                }
            }
            while j < F && bridged[j] {
                if !wild[j] {
                    if lastLag != 0 && !consistent(lastLag, A.lag[j]) {
                        closeChain(j)
                        chainStart = j
                    }
                    lastLag = A.lag[j]
                }
                j += 1
            }
            closeChain(j)
            i = j
        }
        // Weak fragments next to a solid run join it (never on their own).
        let linkFrames = Int((p.weakLinkMs / 1000 / hopSec).rounded(.up))
        let solid = runs
        for w in weak {
            if solid.contains(where: { w.0 - $0.1 <= linkFrames && $0.0 - w.1 <= linkFrames }) { runs.append(w) }
        }
        runs.sort { $0.0 < $1.0 }
        for (a, b) in runs { for k in a...b { A.accepted[k] = true } }
        A.hasSpeech = A.voicedSeconds * 1000 >= p.minVoicedTotalMs && A.longestRunSeconds * 1000 >= p.minStrongRunMs
        guard A.hasSpeech else { return A }

        // --- soft frames: loud, smooth noise (fricatives, breathy word endings), not impulsive --------
        let softGate = A.gateDB + 3
        let soft = (0..<F).map { A.dB[$0] >= softGate && A.crest[$0] <= p.softCrestMax }
        let off = (win - hop) / 2                              // frame i "owns" [i*hop + off, i*hop + off + hop)
        let extGap = p.extendGapFrames

        // --- sample ranges to keep: voiced runs + pads (+ soft extension), merged ----------------------
        let padB = Int(p.padBeforeMs / 1000 * sr)
        let padA = Int(p.padAfterMs / 1000 * sr)
        let extB = Int(p.extendBeforeMs / 1000 * sr)
        let extA = Int(p.extendAfterMs / 1000 * sr)
        let mergeGap = Int(p.mergeGapMs / 1000 * sr)
        var segs: [(start: Int, end: Int)] = []
        for (f0, f1) in runs {
            var s = max(0, f0 * hop - padB)
            var e = min(n, f1 * hop + win + padA)
            // grow forward while the next frames are soft (allowing short dips)
            do {
                var f = (e - off + hop - 1) / hop, gap = 0
                var grown = e
                while f < F && (f * hop + off + hop) - e <= extA {
                    if soft[f] { grown = (f + 1) * hop + off; gap = 0 } else { gap += 1; if gap > extGap { break } }
                    f += 1
                }
                e = min(n, max(e, grown))
            }
            // grow backward
            do {
                var f = (s - off) / hop - 1, gap = 0
                var grown = s
                while f >= 0 && s - (f * hop + off) <= extB {
                    if soft[f] { grown = f * hop + off; gap = 0 } else { gap += 1; if gap > extGap { break } }
                    f -= 1
                }
                s = max(0, min(s, grown))
            }
            if var last = segs.last, s <= last.end + mergeGap {
                last.end = max(last.end, e)
                segs[segs.count - 1] = last
            } else {
                segs.append((s, e))
            }
        }
        A.segments = segs
        return A
    }

    // MARK: - Rendering

    static func render(_ x: [Float], segments: [(start: Int, end: Int)], sampleRate sr: Double,
                       params p: Params) -> [Float] {
        let n = x.count
        let pause = Int(p.pauseMs / 1000 * sr)
        let fade = max(1, Int(p.fadeMs / 1000 * sr))

        var total = 0
        for (k, s) in segments.enumerated() {
            total += s.end - s.start
            if k > 0 { total += min(s.start - segments[k - 1].end, pause) }
        }
        var out = [Float](repeating: 0, count: total)
        x.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                var pos = 0
                for (k, s) in segments.enumerated() {
                    if k > 0 { pos += min(s.start - segments[k - 1].end, pause) }   // silence is already zeros
                    let len = s.end - s.start
                    dst.baseAddress!.advanced(by: pos).update(from: src.baseAddress!.advanced(by: s.start), count: len)
                    let f = min(fade, len / 2)
                    if s.start > 0 {                       // fade in at a cut (not at the start of the recording)
                        for j in 0..<f {
                            let g = 0.5 - 0.5 * cosf(Float.pi * (Float(j) + 0.5) / Float(f))
                            dst[pos + j] *= g
                        }
                    }
                    if s.end < n {                          // fade out at a cut
                        for j in 0..<f {
                            let g = 0.5 - 0.5 * cosf(Float.pi * (Float(j) + 0.5) / Float(f))
                            dst[pos + len - 1 - j] *= g
                        }
                    }
                    pos += len
                }
            }
        }
        return out
    }
}
