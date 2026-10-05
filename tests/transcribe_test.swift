import Foundation
import AVFoundation
import Speech

// CLI harness for AppleTranscriber.
//
//   transcribe_test <audio-file> [more files...]
//
// Environment:
//   STT_ENGINE=speech|dictation   which Apple recognizer to use (default: speech)
//   STT_RUNS=N                    transcribe() calls per clip (default: 2, so you see cold then warm)
//   STT_RATE=Hz                   hand the samples to transcribe() at this rate instead of 16000
//                                 (exercises the module's own sample-rate conversion)
//   STT_SKIP_PREPARE=1            do not call prepare(); shows the cost of forgetting it
//   STT_WATCHDOG=seconds          abort with exit code 3 if the whole run takes longer than this (hang detector)
//   STT_FORCE_TIMEOUT=1           force the FIRST transcribe() of each clip to time out, then check the
//                                 next call on the same object recovers (tests the failure path)
//   STT_PARALLEL=1                after the normal runs, fire all clips concurrently as a thread-safety check
//   VERBALINE_STT_DEBUG=1         print phase timings from inside the module
//
// Each file is decoded with AVAudioFile and converted to mono Float32 16 kHz [Float],
// exactly what the app will pass in.

/// Decode any audio file to mono Float32 samples at `targetRate`.
func loadSamples(path: String, targetRate: Double = 16000) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let inFormat = file.processingFormat
    guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
                                        channels: 1, interleaved: false),
          let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
        throw NSError(domain: "transcribe_test", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "cannot build converter from \(inFormat)"])
    }

    let inCapacity = AVAudioFrameCount(file.length)
    guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: max(inCapacity, 1)) else {
        throw NSError(domain: "transcribe_test", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "cannot allocate input buffer"])
    }
    try file.read(into: inBuffer)

    let ratio = targetRate / inFormat.sampleRate
    let outCapacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 4096
    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
        throw NSError(domain: "transcribe_test", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "cannot allocate output buffer"])
    }

    var supplied = false
    var error: NSError?
    let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
        if supplied { inputStatus.pointee = .endOfStream; return nil }
        supplied = true
        inputStatus.pointee = .haveData
        return inBuffer
    }
    if status == .error || error != nil {
        throw error ?? NSError(domain: "transcribe_test", code: 4,
                               userInfo: [NSLocalizedDescriptionKey: "conversion failed"])
    }
    let n = Int(outBuffer.frameLength)
    guard let ch = outBuffer.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: ch, count: n))
}

@main
struct TranscribeTest {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else {
            FileHandle.standardError.write(Data("usage: transcribe_test <audio-file> [...]\n".utf8))
            exit(2)
        }
        guard #available(macOS 26.0, *) else {
            print("This test needs macOS 26 or newer.")
            exit(2)
        }

        let env = ProcessInfo.processInfo.environment
        let engineName = env["STT_ENGINE"] ?? "speech"
        guard let engine = AppleTranscriber.Engine(rawValue: engineName) else {
            print("STT_ENGINE must be 'speech' or 'dictation' (got '\(engineName)')")
            exit(2)
        }
        let runs = Int(env["STT_RUNS"] ?? "") ?? 2
        if let secs = Double(env["STT_WATCHDOG"] ?? "") {
            DispatchQueue.global().asyncAfter(deadline: .now() + secs) {
                print("WATCHDOG: still running after \(secs) s, treating as a HANG")
                exit(3)
            }
        }
        let rate = Double(env["STT_RATE"] ?? "") ?? 16000

        let transcriber = AppleTranscriber(locale: Locale(identifier: "en-US"), engine: engine)

        if env["STT_SKIP_PREPARE"] == nil {
            do {
                let t0 = Date()
                try await transcriber.prepare()
                print(String(format: "engine=%@  prepare(): %.0f ms", engine.rawValue, Date().timeIntervalSince(t0) * 1000))
            } catch {
                print("prepare() FAILED: \(error)")
                exit(1)
            }
        } else {
            print("engine=\(engine.rawValue)  prepare() SKIPPED")
        }

        for path in args {
            do {
                let samples = try loadSamples(path: path, targetRate: rate)
                let seconds = Double(samples.count) / rate
                print(String(format: "\n== %@  (%.1f s of audio)", (path as NSString).lastPathComponent, seconds))
                for run in 1...max(runs, 1) {
                    let start = Date()
                    if env["STT_FORCE_TIMEOUT"] != nil {
                        if run == 1 { setenv("VERBALINE_STT_TIMEOUT", "0.001", 1) } else { unsetenv("VERBALINE_STT_TIMEOUT") }
                    }
                    let text: String
                    do {
                        text = try await transcriber.transcribe(samples: samples, sampleRate: rate)
                    } catch {
                        let ms = Date().timeIntervalSince(start) * 1000
                        print(String(format: "  run %d  %5.0f ms  threw: %@", run, ms, "\(error)"))
                        continue
                    }
                    let ms = Date().timeIntervalSince(start) * 1000
                    print(String(format: "  run %d  %5.0f ms  (%.2fx realtime)", run, ms, (ms / 1000) / max(seconds, 0.001)))
                    if run == 1 || run == runs { print("  text: \"\(text)\"") }
                }
            } catch {
                print("  FAILED: \(error)")
            }
        }

        if env["STT_PARALLEL"] != nil {
            print("\n== parallel: \(args.count) clips at once")
            let start = Date()
            await withTaskGroup(of: (String, String).self) { group in
                for path in args {
                    group.addTask {
                        guard let samples = try? loadSamples(path: path, targetRate: rate) else { return (path, "<load failed>") }
                        let text = (try? await transcriber.transcribe(samples: samples, sampleRate: rate)) ?? "<transcribe failed>"
                        return (path, text)
                    }
                }
                for await (path, text) in group {
                    print("  \((path as NSString).lastPathComponent): \"\(text.prefix(70))\"")
                }
            }
            print(String(format: "  wall clock for all: %.0f ms", Date().timeIntervalSince(start) * 1000))
        }
    }
}
