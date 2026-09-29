import Foundation
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// The Spend tab's All range and each account's floor over the whole record.
/// Every row and span is made up.
@Suite @MainActor struct SpendRangeTests {

    typealias Spend = SpendAccountsTests

    /// `default` is work until noon on 20 Sep and personal from then; the
    /// `personal` folder is personal's own seat.
    static let attribution = AttributionRecord(timeZone: "UTC", directories: ["default": [
        AttributionSpan(from: Spend.instant("2026-06-01T00:00:00Z"), to: Spend.instant("2026-09-20T12:00:00Z"),
                        lastSeen: Spend.instant("2026-06-01T00:00:00Z"), account: "work"),
        AttributionSpan(from: Spend.instant("2026-09-20T12:00:00Z"), lastSeen: Spend.instant("2026-09-22T08:00:00Z"),
                        account: "personal"),
    ]])

    static let rows = [
        Spend.row("default", "2026-06-22", "03", "claude-opus-5"),
        Spend.row("default", "2026-08-01", "03", "claude-opus-5", output: 500_000),
        Spend.row("default", "2026-09-21", "04", "claude-sonnet-5"),
        Spend.row("personal", "2026-08-26", "05", "claude-sonnet-5", cacheRead: 9_000_000),
        Spend.row("personal", "2026-09-21", "06", "claude-sonnet-5"),
    ]

    static func chart(_ rows: [SpendRow]) -> SpendChart {
        SpendChart.make(record: .available(rows), through: attribution, rates: .bundled, measure: .tokens,
                        now: Spend.now, calendar: Spend.utc)
    }

    static func day(_ text: String) -> Date { Spend.instant(text + "T00:00:00Z") }

    @Test func allStartsAtTheFirstDayOnRecordAndRecentIsUnchanged() throws {
        let chart = Self.chart(Self.rows)
        #expect(chart.showing(.recent) == chart)
        #expect(chart.days == 28)
        #expect(chart.series.map(\.name) == ["personal", "total"])

        let all = chart.showing(.all)
        #expect(all.from == Self.day("2026-06-22"))
        #expect(all.days == 93)
        #expect(all.series.map(\.name) == ["personal", "work", "total"])
        let total = try #require(all.series.last)
        #expect(total.points.first?.day == Self.day("2026-06-22"))
        #expect(total.points.reduce(Decimal(0)) { $0 + $1.amount } == Decimal(5_500_000))
        #expect(all.totals.first { $0.group == "Opus" }?.amount == Decimal(2_500_000))
        #expect(all.axisStride > chart.axisStride)
        #expect(chart.axisStride == 7)
    }

    @Test func eachAccountIsCountedAcrossItsFoldersAsAFloor() throws {
        let accounts = Self.chart(Self.rows).accounts
        #expect(accounts.map(\.account) == ["personal", "work"])
        // Personal: its own folder on two days, and `default` after noon on the 20th.
        let personal = try #require(accounts.first)
        #expect(personal.tokens == Decimal(3_000_000))
        #expect(personal.activeDays == 2)
        #expect(personal.firstDay == Self.day("2026-08-26"))
        // Work: `default` in its span, June and August.
        let work = try #require(accounts.last)
        #expect(work.tokens == Decimal(2_500_000))
        #expect(work.activeDays == 2)
        #expect(work.firstDay == Self.day("2026-06-22"))

        let words = SpendTab.floor(work)
        #expect(words.figure == "at least 2.5M")
        #expect(words.detail == "2 days · from 22 Jun 2026")
    }

    @Test func floorDoesNotOverstateRecordedTokens() throws {
        let row = Spend.row("personal", "2026-09-21", "05",
                            "claude-sonnet-5", input: 1_960_000)
        let account = try #require(Self.chart([row]).accounts.first)
        #expect(SpendTab.floor(account).figure == "at least 1.9M")
    }

    @Test func floorIsShortAndRoundedDown() {
        func figure(_ tokens: Int) -> String {
            let row = Spend.row("personal", "2026-09-21", "05", "claude-sonnet-5", input: tokens)
            return Self.chart([row]).accounts.first.map { SpendTab.floor($0).figure } ?? ""
        }
        #expect(figure(444_931_141) == "at least 444.9M")
        #expect(figure(12_999) == "at least 12K")
        #expect(figure(640) == "at least 640")
    }

    @Test func aGapIsDrawnAtZeroNotBridged() throws {
        let rows = [
            Spend.row("personal", "2026-09-01", "05", "claude-sonnet-5"),
            Spend.row("personal", "2026-09-05", "05", "claude-sonnet-5"),
            Spend.row("personal", "2026-09-06", "05", "claude-sonnet-5"),
            Spend.row("personal", "2026-09-08", "05", "claude-sonnet-5"),
        ]
        let line = try #require(Self.chart(rows).series.first { $0.name == "personal" })
        #expect(line.points.map(\.day) == ["01", "02", "04", "05", "06", "07", "08"].map { Self.day("2026-09-" + $0) })
        #expect(line.points.map(\.amount) == [1_000_000, 0, 0, 1_000_000, 1_000_000, 0, 1_000_000])
    }

    @Test func noAxisLabelStartsTooNearTheRightEdge() {
        func offsets(_ chart: SpendChart) -> [Int] {
            chart.axisDays(calendar: Spend.utc).compactMap {
                Spend.utc.dateComponents([.day], from: chart.from, to: $0).day
            }
        }
        let recent = Self.chart(Self.rows)
        #expect(offsets(recent) == [0, 7, 14, 21])
        // 92 days drawn a 21-day stride apart: a label at day 84 would have 8
        // days after it, under an eighth of the span, so it is left off.
        let all = recent.showing(.all)
        #expect(all.axisStride == 21)
        #expect(offsets(all) == [0, 21, 42, 63])
    }

    @Test func recentRecordsKeepAnXAxisDateLabel() {
        let chart = Self.chart([
            Spend.row("personal", "2026-09-21", "05", "claude-sonnet-5"),
            Spend.row("personal", "2026-09-22", "05", "claude-sonnet-5"),
        ])
        #expect(chart.axisDays(calendar: Spend.utc).contains {
            $0 >= Self.day("2026-09-21") && $0 <= Self.day("2026-09-22")
        })
    }

    @Test func accountFloorUsesOnlyDaysTheChartCanShow() throws {
        let current = Spend.row("personal", "2026-09-21", "05", "claude-sonnet-5")
        let future = Spend.row("personal", "2026-09-23", "05", "claude-sonnet-5")
        let account = try #require(Self.chart([current, future]).accounts.first)
        #expect(account.tokens == Decimal(1_000_000))
        #expect(account.activeDays == 1)
    }

    @Test func unattributedUseIsInTheTotalAndOnNoAccount() {
        let early = Spend.row("default", "2026-05-01", "01", "claude-opus-5")
        let chart = Self.chart(Self.rows + [early])
        #expect(!chart.accounts.contains { $0.account == AttributionRecord.unattributed })
        #expect(chart.showing(.all).from == Self.day("2026-05-01"))
        #expect(!chart.showing(.all).series.contains { $0.name == AttributionRecord.unattributed })
    }

    @Test func withNothingOlderAllDrawsTheRecentView() {
        let recent = Self.rows.filter { $0.day >= "2026-09-01" }
        let chart = Self.chart(recent)
        let all = chart.showing(.all)
        #expect(all.series == chart.series)
        #expect(all.totals == chart.totals)
        #expect(all.from == chart.from)
        #expect(all.days == chart.days)

        let empty = Self.chart([])
        #expect(empty.showing(.all).emptyMessage == "no spend recorded yet")
        #expect(empty.accounts.isEmpty)
    }
}
