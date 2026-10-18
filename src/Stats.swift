import Foundation
import Combine

// Stats
// -----
// The numbers behind the Insights page: words, pace, streaks, time saved, weeks, badges.
// Kept in ~/Library/Application Support/Verbaline/stats.json as one small entry per local day
// ({words, seconds, dictations}) — counts only, never dictation text. It's separate from history.jsonl,
// so trimming or clearing history doesn't reset anyone's streak. Nothing leaves the Mac.
//
// Call `record` / `backfill` / `reset` on the main thread (the Insights view observes `days`).

struct DayTally: Codable, Equatable {
    var words = 0
    var seconds = 0.0
    var dictations = 0
}

struct Badge: Identifiable {
    let id: String
    let title: String
    let icon: String      // SF Symbol
    let earned: Bool
}

struct StatsSummary {
    var totalWords = 0
    var totalDictations = 0
    var totalSeconds = 0.0
    var wordsPerMinute: Int?          // nil until there's at least a second of speech
    var currentStreak = 0
    var bestStreak = 0
    var timeSavedSeconds = 0.0
    var thisWeek = 0
    var lastWeek = 0
    var busiestDay: (date: Date, words: Int)?
    var badges: [Badge] = []
}

final class Stats: ObservableObject {
    static let shared = Stats(fileURL: Stats.defaultURL)

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Verbaline", isDirectory: true).appendingPathComponent("stats.json")
    }

    /// Day key ("2026-10-17", the Mac's local date) → that day's totals.
    @Published private(set) var days: [String: DayTally] = [:]
    let fileURL: URL
    /// True once the file has ever been written (or a reset happened), so history is imported only on the first run.
    private var started = false

    private struct File: Codable {
        var version = 1
        var days: [String: DayTally]
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        guard let data = try? Data(contentsOf: fileURL) else { return }
        started = true
        if let file = try? JSONDecoder().decode(File.self, from: data) {
            days = file.days
        } else {
            // Don't overwrite what we can't read: keep it aside and start fresh.
            let aside = URL(fileURLWithPath: fileURL.path + ".damaged")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            NSLog("Verbaline: stats file unreadable, kept as %@", aside.lastPathComponent)
        }
    }

    // MARK: changes

    func record(text: String, seconds: Double, at date: Date = Date(), calendar: Calendar = .current) {
        let k = Self.key(date, calendar)
        var t = days[k] ?? DayTally()
        t.words += Self.wordCount(text)
        t.seconds += max(0, seconds)
        t.dictations += 1
        days[k] = t
        save()
    }

    /// First run only: counts the dictations already in history (command-mode edits aren't dictations).
    func backfill(from entries: [HistoryEntry], calendar: Calendar = .current) {
        guard !started else { return }
        for e in entries where !e.raw.hasPrefix("[command] ") {
            let k = Self.key(e.date, calendar)
            var t = days[k] ?? DayTally()
            t.words += Self.wordCount(e.text)
            t.seconds += max(0, e.seconds)
            t.dictations += 1
            days[k] = t
        }
        save()
    }

    func reset() {
        days = [:]
        save()
    }

    private func save() {
        started = true
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        do {
            try enc.encode(File(days: days)).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Verbaline: couldn't save stats (%@)", error.localizedDescription)
        }
    }

    // MARK: reading

    func tally(on date: Date, calendar: Calendar = .current) -> DayTally {
        days[Self.key(date, calendar)] ?? DayTally()
    }

    func summary(now: Date = Date(), calendar: Calendar = .current, typingWPM: Double) -> StatsSummary {
        var s = StatsSummary()
        for t in days.values {
            s.totalWords += t.words
            s.totalSeconds += t.seconds
            s.totalDictations += t.dictations
        }
        if s.totalSeconds >= 1 { s.wordsPerMinute = Int((Double(s.totalWords) / (s.totalSeconds / 60)).rounded()) }
        if typingWPM > 0 {
            s.timeSavedSeconds = max(0, Double(s.totalWords) / typingWPM * 60 - s.totalSeconds)
        }

        // Streaks: every day counts. Today without a dictation yet doesn't break it until midnight.
        let active = Set(days.filter { $0.value.dictations > 0 }.keys)
        let today = calendar.startOfDay(for: now)
        var d = active.contains(Self.key(today, calendar)) ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        while active.contains(Self.key(d, calendar)) {
            s.currentStreak += 1
            d = calendar.date(byAdding: .day, value: -1, to: d)!
        }
        let sorted = active.compactMap { Self.date(fromKey: $0, calendar) }.sorted()
        var run = 0
        var prev: Date?
        for day in sorted {
            if let p = prev, calendar.date(byAdding: .day, value: 1, to: p).map({ calendar.isDate($0, inSameDayAs: day) }) == true {
                run += 1
            } else {
                run = 1
            }
            s.bestStreak = max(s.bestStreak, run)
            prev = day
        }

        // Weeks follow the Mac's calendar (its first weekday).
        if let week = calendar.dateInterval(of: .weekOfYear, for: now),
           let lastStart = calendar.date(byAdding: .day, value: -7, to: week.start) {
            for (k, t) in days {
                guard let day = Self.date(fromKey: k, calendar) else { continue }
                if day >= week.start && day < week.end { s.thisWeek += t.words }
                else if day >= lastStart && day < week.start { s.lastWeek += t.words }
            }
        }

        if let best = days.filter({ $0.value.words > 0 })
            .max(by: { ($0.value.words, $1.key) < ($1.value.words, $0.key) }),   // ties → the earlier day
           let date = Self.date(fromKey: best.key, calendar) {
            s.busiestDay = (date, best.value.words)
        }

        s.badges = Self.badges(words: s.totalWords, dictations: s.totalDictations, bestStreak: s.bestStreak)
        return s
    }

    static func badges(words: Int, dictations: Int, bestStreak: Int) -> [Badge] {
        [
            Badge(id: "first", title: "First dictation", icon: "mic", earned: dictations >= 1),
            Badge(id: "words1k", title: "1,000 words", icon: "pencil", earned: words >= 1_000),
            Badge(id: "words10k", title: "10,000 words", icon: "book", earned: words >= 10_000),
            Badge(id: "words50k", title: "50,000 words", icon: "books.vertical", earned: words >= 50_000),
            Badge(id: "words100k", title: "100,000 words", icon: "trophy", earned: words >= 100_000),
            Badge(id: "streak3", title: "3-day streak", icon: "flame", earned: bestStreak >= 3),
            Badge(id: "streak7", title: "7-day streak", icon: "flame.fill", earned: bestStreak >= 7),
            Badge(id: "streak30", title: "30-day streak", icon: "calendar", earned: bestStreak >= 30),
            Badge(id: "dictations100", title: "100 dictations", icon: "bubble.left", earned: dictations >= 100),
            Badge(id: "dictations1k", title: "1,000 dictations", icon: "star", earned: dictations >= 1_000),
        ]
    }

    // MARK: helpers

    /// Same rule as the menu bar panel's "Today" number.
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    static func key(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(fromKey key: String, _ calendar: Calendar) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    /// The calendar month around `date`: how many blank squares come before the 1st (so it lands under the
    /// right weekday), then the start of each day of the month.
    static func month(containing date: Date, calendar: Calendar = .current) -> (leadingBlanks: Int, days: [Date]) {
        guard let interval = calendar.dateInterval(of: .month, for: date),
              let count = calendar.range(of: .day, in: .month, for: date)?.count else { return (0, []) }
        let first = interval.start
        let weekday = calendar.component(.weekday, from: first)
        let blanks = (weekday - calendar.firstWeekday + 7) % 7
        let days = (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
        return (blanks, days)
    }
}
