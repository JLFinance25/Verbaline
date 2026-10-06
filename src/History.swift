import Foundation

struct HistoryEntry: Codable {
    let date: Date
    let raw: String
    let text: String
    let seconds: Double
    /// Seconds spent per stage (gate, speech, cleanup, total) — for tuning speed.
    var timings: [String: Double]? = nil
}

/// Keeps every dictation in ~/Library/Application Support/Verbaline/history.jsonl (one JSON per line).
final class History {
    private(set) var items: [HistoryEntry] = []
    let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Verbaline", isDirectory: true)
        // Only this user can open the folder (history, dictionary, snippets, status live here).
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        fileURL = dir.appendingPathComponent("history.jsonl")
        load()
    }

    var last: HistoryEntry? { items.first }

    /// Deletes every saved entry (the file and the in-memory list). The dictionary and snippets stay.
    func clear() {
        items.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    func add(_ t: HistoryEntry) {
        items.insert(t, at: 0)
        if items.count > 200 { items.removeLast(items.count - 200) }
        guard var line = try? encoder.encode(t) else { return }
        line.append(0x0A)
        // The throwing FileHandle APIs: the old seekToEndOfFile()/write(_:) raise an uncatchable
        // exception on a full disk and would crash the app right after pasting.
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                NSLog("Verbaline: couldn't save history (%@)", error.localizedDescription)
            }
        } else {
            try? line.write(to: fileURL)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        // Keep the file from growing forever: past 5,000 entries, keep the newest 2,000.
        let lines = data.split(separator: 0x0A)
        if lines.count > 5000 {
            var kept = Data()
            for line in lines.suffix(2000) { kept.append(contentsOf: line); kept.append(0x0A) }
            try? kept.write(to: fileURL, options: .atomic)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = data.split(separator: 0x0A).suffix(200)
            .compactMap { try? decoder.decode(HistoryEntry.self, from: Data($0)) }
            .reversed()
    }

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
