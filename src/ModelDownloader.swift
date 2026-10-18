import Foundation
import CryptoKit

// ModelDownloader
// ---------------
// First launch only: fetches the Whisper speech model (1.62 GB) into Verbaline's own folder, when the user
// clicks "Download speech model" in the panel. This is the one time Verbaline uses the network; nothing about
// you is sent, it's a plain file download from the whisper.cpp project's Hugging Face page.
//
// The file is checked before it's used: exact size and SHA-256 must match the published model, so a cut-off
// or altered download is thrown away instead of loaded.
//
//     ModelDownloader.isInstalled            the model file is in place
//     start(progress:completion:)            download, verify, move into place (main-thread callbacks)
//     cancel()

final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    static let source = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!
    static let expectedSize: Int64 = 1_624_555_275
    /// Matches the x-linked-etag the download site publishes for this file (checked 2026-10-17).
    static let expectedSHA256 = "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"

    enum Failure: LocalizedError {
        case network(String), wrongSize(Int64), wrongChecksum, couldNotSave(String)
        var errorDescription: String? {
            switch self {
            case .network(let why): return "Download failed: \(why)"
            case .wrongSize(let n): return "Download was incomplete (\(n / 1_000_000) MB). Try again"
            case .wrongChecksum: return "The download didn't match the real model, so it wasn't used. Try again"
            case .couldNotSave(let why): return "Couldn't save the model: \(why)"
            }
        }
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: VerbalinePaths.model) }

    // Overridable for tests (a small local file instead of the real 1.6 GB one).
    var source = ModelDownloader.source
    var expectedSize = ModelDownloader.expectedSize
    var expectedSHA256 = ModelDownloader.expectedSHA256
    var destination = URL(fileURLWithPath: VerbalinePaths.model)

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var onProgress: ((Double) -> Void)?
    private var onDone: ((Result<Void, Error>) -> Void)?

    var isRunning: Bool { task != nil }

    /// `progress` gets 0...1; `completion` runs once. Both on the main thread.
    func start(progress: @escaping (Double) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        guard task == nil else { return }
        onProgress = progress
        onDone = completion
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        task = s.downloadTask(with: source)
        task?.resume()
    }

    func cancel() {
        task?.cancel()
        finish(.failure(Failure.network("cancelled")))
    }

    // MARK: URLSessionDownloadDelegate (background queue)

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedSize
        let fraction = min(1, Double(totalBytesWritten) / Double(total))
        DispatchQueue.main.async { self.onProgress?(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // `location` is deleted when this method returns, so verify and move it now.
        finish(Result { try Self.verifyAndInstall(location, size: expectedSize, sha256: expectedSHA256, to: destination) })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(Failure.network(error.localizedDescription))) }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard task != nil || session != nil else { return }
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
        DispatchQueue.main.async {
            let done = self.onDone
            self.onDone = nil
            self.onProgress = nil
            done?(result)
        }
    }

    /// Checks size and SHA-256 (streamed, so 1.6 GB never sits in memory), then moves the file into place.
    static func verifyAndInstall(_ file: URL, size: Int64, sha256: String, to destination: URL) throws {
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        let actual = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        guard actual == size else { throw Failure.wrongSize(actual) }
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw Failure.couldNotSave("can't read the download") }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw Failure.wrongChecksum }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: file, to: destination)
        } catch {
            throw Failure.couldNotSave(error.localizedDescription)
        }
    }
}
