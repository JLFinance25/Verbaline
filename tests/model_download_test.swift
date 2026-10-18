import Foundation
import CryptoKit

// model_download_test: ModelDownloader installs a good download and refuses bad ones.
// Uses a small local file (file:// URL) in place of the real 1.6 GB model. Exit 0 = all PASS.

@main struct ModelDownloadTest {
    static var failed = 0
    static func check(_ ok: Bool, _ name: String) { print("\(ok ? "PASS" : "FAIL")  \(name)"); if !ok { failed += 1 } }

    static func run(_ d: ModelDownloader) -> Result<Void, Error> {
        var out: Result<Void, Error>?
        var progressed = false
        d.start(progress: { _ in progressed = true }, completion: { out = $0 })
        let deadline = Date().addingTimeInterval(20)
        while out == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        _ = progressed
        return out ?? .failure(ModelDownloader.Failure.network("timed out"))
    }

    static func main() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verbaline-dl-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let src = dir.appendingPathComponent("fake-model.bin")
        try! payload.write(to: src)
        let sha = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()

        func downloader(sha256: String = sha, size: Int64 = Int64(payload.count), source: URL = src) -> ModelDownloader {
            let d = ModelDownloader()
            d.source = source; d.expectedSize = size; d.expectedSHA256 = sha256
            d.destination = dir.appendingPathComponent("installed/model.bin")
            try? FileManager.default.removeItem(at: d.destination)
            return d
        }

        let good = downloader()
        if case .success = run(good) {
            check(FileManager.default.contentsEqual(atPath: good.destination.path, andPath: src.path), "good download installed byte for byte")
        } else { check(false, "good download succeeds") }

        let badSum = downloader(sha256: String(repeating: "0", count: 64))
        if case .failure(let e) = run(badSum), case ModelDownloader.Failure.wrongChecksum? = e as? ModelDownloader.Failure {
            check(!FileManager.default.fileExists(atPath: badSum.destination.path), "wrong checksum rejected and not installed")
        } else { check(false, "wrong checksum rejected") }

        let badSize = downloader(size: Int64(payload.count) + 1)
        if case .failure(let e) = run(badSize), case ModelDownloader.Failure.wrongSize? = e as? ModelDownloader.Failure {
            check(!FileManager.default.fileExists(atPath: badSize.destination.path), "cut-off download rejected and not installed")
        } else { check(false, "cut-off download rejected") }

        let missing = downloader(source: dir.appendingPathComponent("nope.bin"))
        if case .failure = run(missing) { check(true, "missing file reports an error") } else { check(false, "missing file reports an error") }

        check(ModelDownloader.expectedSize == 1_624_555_275 && ModelDownloader.expectedSHA256.count == 64, "real model size and checksum are pinned")
        print(failed == 0 ? "ALL PASSED" : "\(failed) FAILED")
        exit(failed == 0 ? 0 : 1)
    }
}
