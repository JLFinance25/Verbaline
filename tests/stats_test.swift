import Foundation

// Tests for Stats (src/Stats.swift): the Insights tally file and every number the Insights page shows.
//
//   swiftc -swift-version 5 -O -parse-as-library src/History.swift src/Stats.swift tests/stats_test.swift -o stats_test
//   ./stats_test
//
// Uses its own temp folder, never the real ~/Library/Application Support/Verbaline/stats.json.
// Exit code: 0 = every check passed, 1 = at least one failed.

var passed = 0, failed = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS  \(name)") } else { failed += 1; print("FAIL  \(name) \(detail())") }
}

let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    c.firstWeekday = 1   // Sunday, like a US Mac
    return c
}()

/// A local date in the test calendar.
func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("verbaline-stats-test-\(getpid())")
var fileN = 0
func freshFile() -> URL { fileN += 1; return dir.appendingPathComponent("stats\(fileN).json") }

func words(_ n: Int) -> String { Array(repeating: "word", count: n).joined(separator: " ") }

@main enum Main {
    static func main() {
        try? FileManager.default.removeItem(at: dir)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // MARK: word count
        check(Stats.wordCount("Hello there,  friend.\nNew line") == 5, "word count splits on any whitespace")
        check(Stats.wordCount("   ") == 0, "word count of blank text is 0")

        // MARK: empty
        do {
            let s = Stats(fileURL: freshFile())
            let sum = s.summary(now: day(2026, 10, 17), calendar: cal, typingWPM: 40)
            check(sum.totalWords == 0 && sum.totalDictations == 0, "empty: no words, no dictations")
            check(sum.wordsPerMinute == nil, "empty: no pace yet")
            check(sum.currentStreak == 0 && sum.bestStreak == 0, "empty: streaks 0")
            check(sum.timeSavedSeconds == 0, "empty: no time saved")
            check(sum.busiestDay == nil, "empty: no busiest day")
            check(sum.badges.count == 10 && sum.badges.allSatisfy { !$0.earned }, "empty: 10 badges, none earned")
        }

        // MARK: recording, totals, pace, time saved
        do {
            let url = freshFile()
            let s = Stats(fileURL: url)
            s.record(text: words(120), seconds: 60, at: day(2026, 10, 17, 9), calendar: cal)
            s.record(text: words(30), seconds: 15, at: day(2026, 10, 17, 10), calendar: cal)
            let sum = s.summary(now: day(2026, 10, 17), calendar: cal, typingWPM: 40)
            check(sum.totalWords == 150, "totals: words add up", "\(sum.totalWords)")
            check(sum.totalDictations == 2, "totals: dictations add up")
            check(sum.wordsPerMinute == 120, "pace: 150 words in 75 s = 120 wpm", "\(String(describing: sum.wordsPerMinute))")
            // Typing 150 words at 40 wpm = 225 s; spoken 75 s → 150 s saved.
            check(abs(sum.timeSavedSeconds - 150) < 0.001, "time saved: 225 s typing − 75 s talking", "\(sum.timeSavedSeconds)")
            let slowTalker = Stats(fileURL: freshFile())
            slowTalker.record(text: words(10), seconds: 60, at: day(2026, 10, 17), calendar: cal)
            check(slowTalker.summary(now: day(2026, 10, 17), calendar: cal, typingWPM: 40).timeSavedSeconds == 0,
                  "time saved never goes below 0")
            check(s.tally(on: day(2026, 10, 17), calendar: cal) == DayTally(words: 150, seconds: 75, dictations: 2),
                  "tally for a day")

            // Saved to disk and read back by a new instance.
            let again = Stats(fileURL: url)
            check(again.summary(now: day(2026, 10, 17), calendar: cal, typingWPM: 40).totalWords == 150, "saved and reloaded")
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            check(!text.contains("word word"), "file holds counts only, no dictation text")
        }

        // MARK: midnight
        do {
            let s = Stats(fileURL: freshFile())
            s.record(text: words(5), seconds: 3, at: day(2026, 10, 16, 23, 59), calendar: cal)
            s.record(text: words(7), seconds: 3, at: day(2026, 10, 17, 0, 1), calendar: cal)
            check(s.tally(on: day(2026, 10, 16), calendar: cal).words == 5 && s.tally(on: day(2026, 10, 17), calendar: cal).words == 7,
                  "midnight: 11:59 pm and 12:01 am land on different days")
        }

        // MARK: streaks
        do {
            let s = Stats(fileURL: freshFile())
            // Oct 1–3 (3 days), gap Oct 4, Oct 10–16 (7 days), today Oct 17 not yet.
            for d in [1, 2, 3] + Array(10...16) { s.record(text: words(10), seconds: 5, at: day(2026, 10, d), calendar: cal) }
            var sum = s.summary(now: day(2026, 10, 17, 8), calendar: cal, typingWPM: 40)
            check(sum.currentStreak == 7, "streak: today not dictated yet still shows yesterday's run", "\(sum.currentStreak)")
            check(sum.bestStreak == 7, "best streak: 7", "\(sum.bestStreak)")
            s.record(text: words(10), seconds: 5, at: day(2026, 10, 17, 9), calendar: cal)
            sum = s.summary(now: day(2026, 10, 17, 9), calendar: cal, typingWPM: 40)
            check(sum.currentStreak == 8 && sum.bestStreak == 8, "streak: dictating today extends it", "\(sum.currentStreak)/\(sum.bestStreak)")
            sum = s.summary(now: day(2026, 10, 19), calendar: cal, typingWPM: 40)
            check(sum.currentStreak == 0, "streak: a missed day (every day counts) resets it", "\(sum.currentStreak)")
            check(sum.bestStreak == 8, "best streak survives the reset")
            sum = s.summary(now: day(2026, 10, 18, 7), calendar: cal, typingWPM: 40)
            check(sum.currentStreak == 8, "streak: the next morning it still counts until midnight")
        }
        do {   // across a month and a daylight-saving change (Nov 1, 2026 in Los Angeles)
            let s = Stats(fileURL: freshFile())
            for d in [day(2026, 10, 30), day(2026, 10, 31), day(2026, 11, 1), day(2026, 11, 2)] {
                s.record(text: "hi", seconds: 1, at: d, calendar: cal)
            }
            let sum = s.summary(now: day(2026, 11, 2), calendar: cal, typingWPM: 40)
            check(sum.currentStreak == 4 && sum.bestStreak == 4, "streak runs across month end and clock change", "\(sum.currentStreak)")
        }

        // MARK: weeks and busiest day
        do {
            let s = Stats(fileURL: freshFile())
            // Oct 17 2026 is a Saturday. This week = Sun Oct 11 … Sat Oct 17; last week = Oct 4 … Oct 10.
            s.record(text: words(100), seconds: 30, at: day(2026, 10, 4, 0, 5), calendar: cal)   // last week, first minute-ish
            s.record(text: words(50), seconds: 30, at: day(2026, 10, 10, 23, 50), calendar: cal) // last week, last day
            s.record(text: words(300), seconds: 30, at: day(2026, 10, 11, 0, 5), calendar: cal)  // this week, Sunday
            s.record(text: words(20), seconds: 30, at: day(2026, 10, 17), calendar: cal)
            s.record(text: words(999), seconds: 30, at: day(2026, 10, 3), calendar: cal)         // two weeks ago
            let sum = s.summary(now: day(2026, 10, 17, 15), calendar: cal, typingWPM: 40)
            check(sum.thisWeek == 320, "this week: Sunday through today", "\(sum.thisWeek)")
            check(sum.lastWeek == 150, "last week: the 7 days before", "\(sum.lastWeek)")
            check(sum.busiestDay.map { cal.isDate($0.date, inSameDayAs: day(2026, 10, 3)) && $0.words == 999 } == true,
                  "busiest day: date and words")
            var monday = cal; monday.firstWeekday = 2
            let mSum = s.summary(now: day(2026, 10, 17, 15), calendar: monday, typingWPM: 40)
            check(mSum.thisWeek == 20 && mSum.lastWeek == 350, "weeks follow the Mac's first weekday (Monday)", "\(mSum.thisWeek)/\(mSum.lastWeek)")
        }

        // MARK: badges
        do {
            let s = Stats(fileURL: freshFile())
            for d in 1...7 { s.record(text: words(150), seconds: 60, at: day(2026, 10, d), calendar: cal) }
            let earned = Set(s.summary(now: day(2026, 10, 7), calendar: cal, typingWPM: 40).badges.filter(\.earned).map(\.id))
            check(earned == ["first", "words1k", "streak3", "streak7"], "badges: 1,050 words over 7 days", "\(earned.sorted())")
            let b = Stats(fileURL: freshFile())
            for i in 0..<100 { b.record(text: "ok", seconds: 1, at: day(2026, 10, 1).addingTimeInterval(Double(i)), calendar: cal) }
            let e2 = Set(b.summary(now: day(2026, 10, 1), calendar: cal, typingWPM: 40).badges.filter(\.earned).map(\.id))
            check(e2.contains("dictations100") && !e2.contains("dictations1k"), "badges: 100 dictations")
        }

        // MARK: backfill from history
        do {
            let url = freshFile()
            let s = Stats(fileURL: url)
            let entries = [
                HistoryEntry(date: day(2026, 10, 17, 9), raw: "a", text: words(40), seconds: 20),
                HistoryEntry(date: day(2026, 10, 17, 10), raw: "[command] make it shorter", text: words(500), seconds: 0),
                HistoryEntry(date: day(2026, 10, 16, 9), raw: "b", text: words(10), seconds: 5),
            ]
            s.backfill(from: entries, calendar: cal)
            var sum = s.summary(now: day(2026, 10, 17), calendar: cal, typingWPM: 40)
            check(sum.totalWords == 50 && sum.totalDictations == 2, "backfill: imports dictations, skips command-mode edits", "\(sum.totalWords)")
            check(sum.currentStreak == 2, "backfill: streak from history")
            s.backfill(from: entries, calendar: cal)
            sum = s.summary(now: day(2026, 10, 17), calendar: cal, typingWPM: 40)
            check(sum.totalWords == 50, "backfill only happens once", "\(sum.totalWords)")
            let reopened = Stats(fileURL: url)
            reopened.backfill(from: entries, calendar: cal)
            check(reopened.summary(now: day(2026, 10, 17), calendar: cal, typingWPM: 40).totalWords == 50,
                  "backfill never runs again once the file exists")
        }

        // MARK: reset
        do {
            let url = freshFile()
            let s = Stats(fileURL: url)
            s.record(text: words(10), seconds: 5, at: day(2026, 10, 17), calendar: cal)
            s.reset()
            check(s.summary(now: day(2026, 10, 17), calendar: cal, typingWPM: 40).totalWords == 0, "reset: all zero")
            let reopened = Stats(fileURL: url)
            check(reopened.summary(now: day(2026, 10, 17), calendar: cal, typingWPM: 40).totalWords == 0, "reset: stays reset after reopening")
            reopened.backfill(from: [HistoryEntry(date: day(2026, 10, 17), raw: "x", text: words(9), seconds: 3)], calendar: cal)
            check(reopened.summary(now: day(2026, 10, 17), calendar: cal, typingWPM: 40).totalWords == 0,
                  "reset: history isn't imported again afterwards")
        }

        // MARK: damaged file
        do {
            let url = freshFile()
            try! Data("{not json".utf8).write(to: url)
            let s = Stats(fileURL: url)
            check(s.summary(now: day(2026, 10, 17), calendar: cal, typingWPM: 40).totalWords == 0, "damaged file: starts empty, no crash")
            check(FileManager.default.fileExists(atPath: url.path + ".damaged"), "damaged file: kept aside, not thrown away")
            s.record(text: words(3), seconds: 1, at: day(2026, 10, 17), calendar: cal)
            check(Stats(fileURL: url).summary(now: day(2026, 10, 17), calendar: cal, typingWPM: 40).totalWords == 3, "damaged file: new counts saved")
        }

        // MARK: month grid
        do {
            let g = Stats.month(containing: day(2026, 10, 17), calendar: cal)
            // Oct 1 2026 is a Thursday → 4 blanks before it when weeks start on Sunday.
            check(g.leadingBlanks == 4 && g.days.count == 31, "month grid: October 2026", "\(g.leadingBlanks)/\(g.days.count)")
            check(cal.component(.day, from: g.days[0]) == 1 && cal.component(.month, from: g.days[30]) == 10, "month grid: 1st to 31st")
            var monday = cal; monday.firstWeekday = 2
            check(Stats.month(containing: day(2026, 10, 17), calendar: monday).leadingBlanks == 3, "month grid: Monday-first weeks")
            check(Stats.month(containing: day(2026, 2, 10), calendar: cal).days.count == 28, "month grid: February 2026 has 28 days")
            check(Stats.month(containing: day(2026, 11, 1), calendar: cal).days.count == 30, "month grid: November (clock-change month) has 30 days")
        }

        try? FileManager.default.removeItem(at: dir)
        print("\n\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
