import Foundation
import Testing

import SeatGaugeCore

/// One seat's spend history by range and measure. Rows and attribution records are built in memory with seat names only; the
/// calendar is UTC and now is Sunday 27 September 2026, midday.
@Suite struct SeatHistoryTests {

    // MARK: - Fixtures

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func date(_ text: String) -> Date {
        let reader = ISO8601DateFormatter()
        reader.formatOptions = [.withInternetDateTime]
        return reader.date(from: text)!
    }

    static func day(_ text: String) -> Date { date(text + "T00:00:00Z") }

    static let now = date("2026-09-27T12:00:00Z")

    static func row(_ seat: String, _ day: String, _ hour: String = "10", input: Int = 1_000,
                    output: Int = 0, model: String = "claude-opus-5") -> SpendRow {
        let counts = TokenCounts(responses: 1, input: input, output: output)
        return SpendRow(seat: seat, day: day, hour: hour, model: model, counts: counts,
                        usd: RateCard.bundled.usd(model: model, counts: counts), sealed: true)
    }

    static let noSpans = AttributionRecord(timeZone: "UTC")

    static func history(_ record: SpendRecord, _ seat: String, _ range: HistoryRange = .week,
                        _ measure: Measure = .tokens,
                        through attribution: AttributionRecord = noSpans) -> SeatHistory {
        SeatHistory.make(record: record, through: attribution, seat: seat, range: range, measure: measure,
                         now: now, calendar: utc)
    }

    static func amounts(_ history: SeatHistory) -> [Decimal] { history.outcome.buckets.map(\.amount) }

    // MARK: - Cases

    @Test func oneMeasureCountsFreshTokensOrListPrice() {
        let counts = TokenCounts(responses: 1, input: 100, output: 50, thinking: 30, cacheRead: 1_000,
                                 cacheWrite5m: 7, cacheWrite1h: 3)
        let priced = SpendRow(seat: "personal", day: "2026-09-27", hour: "10", model: "claude-opus-5",
                              counts: counts, usd: RateCard.bundled.usd(model: "claude-opus-5", counts: counts),
                              sealed: true)
        #expect(Measure.tokens.amount(of: priced) == 160)
        #expect(Measure.usd.amount(of: priced) == priced.usd)
        #expect(priced.usd != nil)

        let unpriced = SpendRow(seat: "codex", day: "2026-09-27", hour: "10", model: "gpt-6-sol",
                                counts: counts, usd: nil, sealed: true)
        #expect(Measure.tokens.amount(of: unpriced) == 160)
        #expect(Measure.usd.amount(of: unpriced) == nil)
    }

    @Test func dailyRangesEndTodayAndKeepEveryDay() {
        let week = HistoryRange.week.starts(now: Self.now, calendar: Self.utc)
        #expect(week.count == 7)
        #expect(week.first == Self.day("2026-09-21"))
        #expect(week.last == Self.day("2026-09-27"))

        let month = HistoryRange.month.starts(now: Self.now, calendar: Self.utc)
        #expect(month.count == 30)
        #expect(month.first == Self.day("2026-08-29"))
        #expect(month.last == Self.day("2026-09-27"))
        for (a, b) in zip(month, month.dropFirst()) { #expect(b.timeIntervalSince(a) == 86_400) }

        let record = SpendRecord.available([Self.row("personal", "2026-09-25", input: 500)])
        #expect(Self.amounts(Self.history(record, "personal", .week)) == [0, 0, 0, 0, 500, 0, 0])
        #expect(Self.history(record, "personal", .month).outcome.buckets.count == 30)
    }

    @Test func weeklyRangesStartMondayAndMonthlyRangesStartOnTheFirst() {
        let weeks = HistoryRange.halfYear.starts(now: Self.now, calendar: Self.utc)
        #expect(weeks.count == 26)
        #expect(weeks.first == Self.day("2026-03-30"))
        #expect(weeks.last == Self.day("2026-09-21"))
        for start in weeks { #expect(Self.utc.component(.weekday, from: start) == 2) }

        let months = HistoryRange.year.starts(now: Self.now, calendar: Self.utc)
        #expect(months.count == 12)
        #expect(months.first == Self.day("2025-10-01"))
        #expect(months.last == Self.day("2026-09-01"))
        for start in months { #expect(Self.utc.component(.day, from: start) == 1) }

        let record = SpendRecord.available([Self.row("personal", "2026-09-27", input: 5),
                                            Self.row("personal", "2026-09-20", input: 7)])
        let amounts = Self.amounts(Self.history(record, "personal", .halfYear))
        #expect(amounts.suffix(2) == [7, 5])
    }

    @Test func everyBucketReadsOutItsLabelAndFigure() {
        let record = SpendRecord.available([
            Self.row("personal", "2026-09-23", input: 1_000_000, output: 200_000, model: "gpt-6-sol"),
            Self.row("personal", "2026-09-22", input: 0, output: 1_648_000),
            Self.row("personal", "2026-08-10", input: 380_000),
        ])
        let days = Self.history(record, "personal", .week).outcome.buckets
        #expect(days.first { $0.start == Self.day("2026-09-23") }?.readOut == "Wed 23 Sep · 1.2M tokens")

        let weeks = Self.history(record, "personal", .halfYear, .usd).outcome.buckets
        #expect(weeks.last?.readOut == "wk of 21 Sep · $41.20")

        let months = Self.history(record, "personal", .year).outcome.buckets
        #expect(months.first { $0.start == Self.day("2026-08-01") }?.readOut == "Aug 2026 · 380K tokens")
    }

    @Test func aSeatCountsOnlyWhatIsFiledUnderIt() {
        let attribution = AttributionRecord(timeZone: "UTC", directories: ["default": [
            AttributionSpan(from: Self.date("2026-09-25T00:00:00Z"), to: Self.date("2026-09-26T00:00:00Z"),
                            lastSeen: Self.date("2026-09-25T00:00:00Z"), account: "personal"),
        ]])
        let record = SpendRecord.available([
            Self.row("personal", "2026-09-24", input: 3),
            Self.row("default", "2026-09-25", input: 5),
            Self.row("default", "2026-09-26", input: 11),
            Self.row("work", "2026-09-25", input: 13),
            Self.row("personal", "2026-09-01", input: 17),
        ])
        #expect(Self.amounts(Self.history(record, "personal", through: attribution)) == [0, 0, 0, 3, 5, 0, 0])
        #expect(Self.amounts(Self.history(record, "work", through: attribution)) == [0, 0, 0, 0, 13, 0, 0])
    }

    @Test func theHistorySaysWhatTheRecordMet() {
        let rows = [Self.row("personal", "2026-09-25"), Self.row("default", "2026-09-26")]
        let whole = SpendRecord.available(rows)
        guard case let .available(buckets) = Self.history(whole, "personal").outcome else {
            Issue.record("a seat with usage in a whole record is available"); return
        }
        #expect(buckets.count == 7)
        #expect(Self.history(whole, "work").outcome == .empty)
        #expect(Self.history(.empty, "personal").outcome == .empty)
        #expect(Self.history(.available([Self.row("default", "2026-09-26")]), "personal").outcome == .empty)

        guard case let .partial(partial, reason) = Self.history(.partial(rows, "spend.csv: 1 line"), "personal").outcome
        else { Issue.record("a partial record is a partial history"); return }
        #expect(partial == buckets)
        #expect(reason == "spend.csv: 1 line")

        #expect(Self.history(.unavailable("gone"), "personal").outcome == .unavailable("gone"))
        #expect(Self.history(.unavailable("gone"), "personal").outcome.buckets.isEmpty)
    }

    @Test func dollarsSayWhenASeatHasNoListPrice() {
        let record = SpendRecord.available([Self.row("codex", "2026-09-25", model: "gpt-6-sol"),
                                            Self.row("personal", "2026-09-25"),
                                            Self.row("personal", "2026-09-26", model: "gpt-6-sol")])
        #expect(Self.history(record, "codex", .week, .usd).noListPrice)
        #expect(!Self.history(record, "codex", .week, .tokens).noListPrice)
        #expect(!Self.history(record, "personal", .week, .usd).noListPrice)
        #expect(!Self.history(record, "work", .week, .usd).noListPrice)
        #expect(Self.history(record, "codex", .week, .usd).range == .week)
        #expect(Self.history(record, "codex", .week, .usd).measure == .usd)
    }

    @Test func failsClosedOnARowWhoseDayIsNotADate() {
        let record = SpendRecord.available([Self.row("personal", "2026-09-25", input: 5),
                                            Self.row("personal", "not-a-day", input: 7)])
        guard case let .partial(buckets, reason) = Self.history(record, "personal").outcome else {
            Issue.record("a row with no date must make the history partial"); return
        }
        #expect(buckets.map(\.amount) == [0, 0, 0, 0, 5, 0, 0])
        #expect(reason.contains("1"))
    }
}
