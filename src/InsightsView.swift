import SwiftUI

// InsightsView
// ------------
// The Insights tab of the Verbaline window: total words, pace, streak, time saved, a one-month calendar shaded
// by how much you dictated, this week vs last, and badges. It only draws `Stats` (src/Stats.swift); it has no
// window of its own — the Verbaline window shows it as a tab. Look and feel: src/Theme.swift.

struct InsightsView: View {
    @ObservedObject var stats: Stats
    /// Your typing speed, for "time saved". 40 wpm is a starting guess, not a measurement.
    @AppStorage("insightsTypingWPM") private var typingWPM = 40
    @State private var monthOffset = 0           // 0 = this month, -1 = last month, …
    @State private var hovered: Date?
    @State private var confirmReset = false
    /// Fixed only for screenshots and tests.
    var now: () -> Date = { Date() }

    init(stats: Stats = .shared, now: @escaping () -> Date = { Date() }) {
        self.stats = stats
        self.now = now
    }

    var body: some View {
        let s = stats.summary(now: now(), typingWPM: Double(typingWPM))
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gap) {
                HStack(spacing: Theme.gap) {
                    numberCard("Words", s.totalWords.formatted(), "all time")
                    numberCard("Per minute", s.wordsPerMinute.map(String.init) ?? "—", "your pace")
                    numberCard("Streak", s.currentStreak == 1 ? "1 day" : "\(s.currentStreak) days",
                               "best \(s.bestStreak)")
                    timeSavedCard(s.timeSavedSeconds)
                }
                calendarCard
                HStack(spacing: Theme.gap) {
                    weekCard(s)
                    numberCard("Busiest day", s.busiestDay.map { $0.words.formatted() } ?? "—",
                               s.busiestDay.map { $0.date.formatted(.dateTime.month(.abbreviated).day()) } ?? "no dictations yet",
                               size: 24)
                    numberCard("Dictations", s.totalDictations.formatted(), "all time", size: 24)
                }
                badgesCard(s.badges)
                HStack {
                    Spacer()
                    Button("Reset stats…") { confirmReset = true }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(Theme.faint)
                }
            }
            .padding(Theme.pad)
        }
        .background(Theme.page)
        .foregroundColor(Theme.text)
        .alert("Reset your stats?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { stats.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Words, streaks, and badges go back to zero. Your dictation history stays.")
        }
    }

    // MARK: cards

    private func numberCard(_ label: String, _ value: String, _ under: String, size: CGFloat = 30) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).themeCaption()
            Text(value).font(Theme.number(size)).lineLimit(1).minimumScaleFactor(0.6)
            Text(under).font(.system(size: 12)).foregroundColor(Theme.faint).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
    }

    private func timeSavedCard(_ seconds: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Time saved").themeCaption()
            Text(Self.duration(seconds)).font(Theme.number(30)).lineLimit(1).minimumScaleFactor(0.6)
            Menu {
                ForEach([30, 40, 50, 60, 70, 80], id: \.self) { w in
                    Button("\(w) wpm\(w == typingWPM ? "  ✓" : "")") { typingWPM = w }
                }
            } label: {
                Text("estimate · you type \(typingWPM) wpm").font(.system(size: 12)).foregroundColor(Theme.faint)
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            .help("Time saved compares talking with typing at this speed. Click to change it.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
    }

    private func weekCard(_ s: StatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("This week").themeCaption()
            Text(s.thisWeek.formatted()).font(Theme.number(24)).lineLimit(1)
            Group {
                if s.lastWeek > 0 {
                    let change = Int(((Double(s.thisWeek) / Double(s.lastWeek) - 1) * 100).rounded())
                    HStack(spacing: 3) {
                        Image(systemName: change >= 0 ? "arrow.up" : "arrow.down")
                        Text("\(abs(change))% vs last week")
                    }
                    .foregroundColor(change >= 0 ? Theme.teal : Theme.dim)
                } else {
                    Text("nothing last week").foregroundColor(Theme.faint)
                }
            }
            .font(.system(size: 12)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
    }

    // MARK: calendar

    private var shownMonth: Date {
        Calendar.current.date(byAdding: .month, value: monthOffset, to: now()) ?? now()
    }

    private var calendarCard: some View {
        let cal = Calendar.current
        let grid = Stats.month(containing: shownMonth, calendar: cal)
        let today = cal.startOfDay(for: now())
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let weekdays = (0..<7).map { symbols[(cal.firstWeekday - 1 + $0) % 7] }
        let active = grid.days.filter { $0 <= today && stats.tally(on: $0).dictations > 0 }.count
        let soFar = grid.days.filter { $0 <= today }.count

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(shownMonth.formatted(.dateTime.month(.wide).year())).font(Theme.title(22))
                Spacer()
                Text(hoverText).font(.system(size: 12)).foregroundColor(Theme.dim)
                arrow("chevron.left", help: "Earlier month") { monthOffset -= 1 }
                arrow("chevron.right", help: "Later month") { monthOffset += 1 }
                    .disabled(monthOffset >= 0).opacity(monthOffset >= 0 ? 0.3 : 1)
            }
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(weekdays.indices, id: \.self) { i in
                    Text(weekdays[i]).themeCaption().frame(maxWidth: .infinity)
                }
                ForEach(0..<grid.leadingBlanks, id: \.self) { i in Color.clear.frame(height: 1).id("blank\(i)") }
                ForEach(grid.days, id: \.self) { day in
                    dayCell(day, today: today)
                }
            }
            HStack {
                Text("\(active) of \(soFar) days").font(.system(size: 12)).foregroundColor(Theme.faint)
                Spacer()
                Text("Less").font(.system(size: 12)).foregroundColor(Theme.faint)
                ForEach(Theme.heat.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3).fill(Theme.heat[i]).frame(width: 10, height: 10)
                }
                Text("More").font(.system(size: 12)).foregroundColor(Theme.faint)
            }
        }
        .themeCard()
    }

    private var hoverText: String {
        guard let d = hovered else { return "" }
        let w = stats.tally(on: d).words
        return d.formatted(.dateTime.month(.abbreviated).day()) + " · " + (w == 1 ? "1 word" : "\(w.formatted()) words")
    }

    @ViewBuilder private func dayCell(_ day: Date, today: Date) -> some View {
        let n = Calendar.current.component(.day, from: day)
        let shape = RoundedRectangle(cornerRadius: 8)
        if day > today {
            Text("\(n)").font(.system(size: 11)).foregroundColor(Theme.line)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(6)
                .frame(height: 44)
                .overlay(shape.strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        } else {
            let level = Self.level(stats.tally(on: day).words)
            Text("\(n)").font(.system(size: 11)).foregroundColor(Theme.heatText[level])
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(6)
                .frame(height: 44)
                .background(Theme.heat[level], in: shape)
                .overlay(shape.strokeBorder(Theme.violet, lineWidth: day == today ? 2 : 0))
                .onHover { inside in
                    if inside { hovered = day } else if hovered == day { hovered = nil }
                }
        }
    }

    private func arrow(_ icon: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.dim)
                .frame(width: 26, height: 26).background(Theme.raised, in: Circle()).contentShape(Circle())
        }
        .buttonStyle(.plain).help(help)
    }

    // MARK: badges

    private func badgesCard(_ badges: [Badge]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Badges · \(badges.filter(\.earned).count) of \(badges.count)").themeCaption()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 12) {
                ForEach(badges) { b in
                    VStack(spacing: 6) {
                        Image(systemName: b.icon).font(.system(size: 17))
                            .foregroundColor(b.earned ? Theme.violetOnSoft : Theme.faint)
                            .frame(width: 42, height: 42)
                            .background(b.earned ? Theme.violetSoft : Theme.heat[0], in: Circle())
                        Text(b.title).font(.system(size: 11)).multilineTextAlignment(.center)
                            .foregroundColor(b.earned ? Theme.text : Theme.faint)
                    }
                    .help(b.earned ? "Earned" : "Not yet")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeCard()
    }

    // MARK: helpers

    /// Words in a day → calendar shade 0…4.
    static func level(_ words: Int) -> Int {
        switch words {
        case 0: return 0
        case ..<250: return 1
        case ..<750: return 2
        case ..<1500: return 3
        default: return 4
        }
    }

    /// 0 → "0m", 16 min → "16m", 3 h 20 min → "3h 20m".
    static func duration(_ seconds: Double) -> String {
        let m = Int(seconds / 60)
        return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
    }
}
