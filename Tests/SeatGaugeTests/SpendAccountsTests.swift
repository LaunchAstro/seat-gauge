import Foundation
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// The Spend tab: a line per account, the shared measure, the family totals,
/// hover and the legend's toggles. Every row and span is made up.
@Suite(.serialized, .sharedMirror) @MainActor struct SpendAccountsTests {

    typealias Glance = GlanceFaceTests

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static let now = ISO8601DateFormatter().date(from: "2026-09-22T08:00:00Z")!

    static func row(_ seat: String, _ day: String, _ hour: String, _ model: String, responses: Int = 1,
                    input: Int = 1_000_000, output: Int = 0, cacheRead: Int = 0) -> SpendRow {
        let counts = TokenCounts(responses: responses, input: input, output: output, cacheRead: cacheRead)
        return SpendRow(seat: seat, day: day, hour: hour, model: model, counts: counts,
                        usd: RateCard.bundled.usd(model: model, counts: counts), sealed: true)
    }

    static func instant(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    /// `default` is work until noon on the 20th and personal from then.
    static let attribution = AttributionRecord(timeZone: "UTC", directories: ["default": [
        AttributionSpan(from: instant("2026-09-01T00:00:00Z"), to: instant("2026-09-20T12:00:00Z"),
                        lastSeen: instant("2026-09-01T00:00:00Z"), account: "work"),
        AttributionSpan(from: instant("2026-09-20T12:00:00Z"), lastSeen: instant("2026-09-22T08:00:00Z"),
                        account: "personal"),
    ]])

    static let rows = [
        row("default", "2026-09-20", "02", "claude-opus-5"),
        row("default", "2026-09-20", "09", "claude-opus-5"),
        row("default", "2026-09-21", "04", "claude-fable-5-1", output: 500_000, cacheRead: 9_000_000),
        row("personal", "2026-09-21", "05", "claude-sonnet-5"),
        row("codex", "2026-09-21", "06", "gpt-6-sol", responses: 4),
        // Before any span: unattributed, so in the total and on no line.
        row("default", "2026-08-30", "01", "claude-opus-5"),
        // Older than the 28 days: in the record, off the chart.
        row("team", "2026-08-01", "01", "claude-sonnet-5"),
    ]

    static func chart(_ rows: [SpendRow], _ measure: Measure) -> SpendChart {
        SpendChart.make(record: .available(rows), through: attribution, rates: .bundled, measure: measure,
                        now: now, calendar: utc)
    }

    // MARK: - A line per account and the total

    @Test func aHoveredSpendPointNamesItsDateAndFigure() throws {
        let chart = Self.chart(Self.rows, .tokens)
        let work = try #require(chart.series.first { $0.name == "work" })
        let point = try #require(work.points.first)
        let callout = try #require(SpendTab.callout(for: point, in: chart))
        #expect(callout.contains("20 Sep"))
        #expect(callout.contains("2.0M tokens"))
    }

    @Test func aLinePerAccountAndTheTotal() throws {
        let chart = Self.chart(Self.rows, .usd)
        #expect(chart.series.map(\.name) == ["codex", "personal", "work", "total"])
        #expect(chart.days == 28)
        let work = try #require(chart.series.first { $0.name == "work" })
        #expect(work.points.count == 1)
        #expect(work.points.allSatisfy { Self.utc.component(.hour, from: $0.day) == 0 })
        let total = try #require(chart.series.last)
        let lines = chart.series.dropLast().flatMap(\.points).reduce(Decimal(0)) { $0 + $1.amount }
        let unattributed = try #require(Self.rows[5].usd)
        #expect(total.points.reduce(Decimal(0)) { $0 + $1.amount } == lines + unattributed)

        let withTeam = Self.chart(Self.rows + [Self.row("team", "2026-09-10", "03", "claude-sonnet-5")], .usd)
        #expect(withTeam.series.map(\.name) == ["codex", "personal", "team", "work", "total"])
    }

    // MARK: - The shared measure

    @Test func theMeasureIsShared() throws {
        let tokens = Self.chart(Self.rows, .tokens)
        let personal = try #require(tokens.series.first { $0.name == "personal" })
        // Personal holds the Fable row (1.5M, its cache reads left out) and its own Sonnet row (1M).
        #expect(personal.points.reduce(Decimal(0)) { $0 + $1.amount } == Decimal(2_500_000))

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-spend-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(file: root.appendingPathComponent("state.json"))
        let mirror = GaugeMirror()
        mirror.measureStore = store
        mirror.measure = .usd
        #expect(store.load().measure == .usd)
        mirror.measure = .tokens
        #expect(store.load().measure == .tokens)
    }

    // MARK: - The headings are the families

    @Test func theHeadingsAreTheFamilies() throws {
        let dollars = Self.chart(Self.rows, .usd)
        #expect(dollars.totals.map(\.group) == ["Opus", "Fable", "Sonnet", "Sol", "other", "unpriced"])
        let sol = try #require(dollars.totals.first { $0.group == "Sol" })
        #expect(sol.amount == 0)
        let unpriced = try #require(dollars.totals.first { $0.group == "unpriced" })
        #expect(unpriced.amount == nil)
        #expect(unpriced.responses == 4)

        let tokens = Self.chart(Self.rows, .tokens)
        #expect(tokens.totals.map(\.group) == ["Opus", "Fable", "Sonnet", "Sol", "other"])
        #expect(tokens.totals.first { $0.group == "Sol" }?.amount == Decimal(1_000_000))
        #expect(tokens.totals.first { $0.group == "Fable" }?.amount == Decimal(1_500_000))
        #expect(ModelFamily(model: "gpt-6-sol") == .sol)
        #expect(RateCard.bundled.priceStatus(for: "gpt-6-sol") == .unpriced)
    }

    // MARK: - The totals step down, the legend steps up

    @Test func theTotalsStepDownAndTheLegendUp() {
        #expect(SpendTab.headingLabelSize < 10)
        #expect(SpendTab.headingFigureSize < 12)
        #expect(SpendTab.legendSize == 11)
    }

    // MARK: - A legend click hides its line, and the choice is kept

    @Test func aLegendClickHidesItsLineAndIsKept() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-spend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(file: root.appendingPathComponent("state.json"))
        let chart = Self.chart(Self.rows, .usd)
        let mirror = GaugeMirror()
        mirror.spendFocus = "total"
        try mirror.toggle(line: "total", store: store)
        #expect(mirror.hiddenLines == ["total"])
        #expect(mirror.spendFocus == nil)
        #expect(store.load().hiddenSpendLines == ["total"])
        #expect(chart.visible(hiding: mirror.hiddenLines).map(\.name) == ["codex", "personal", "work"])
        // Hover over a hidden line's entry brings nothing forward.
        #expect(SpendTab.dimmed(chart.visible(hiding: mirror.hiddenLines), focus: "total").isEmpty)
        #expect(SpendTab.legendTone(off: true, dimmed: false) == Tone.inkDim)
        #expect(SpendTab.legendTone(off: false, dimmed: false) == Tone.inkMuted)

        try mirror.toggle(line: "total", store: store)
        try mirror.toggle(line: "account:work", store: store)
        let relaunched = GaugeMirror()
        relaunched.readSpend(csv: root.appendingPathComponent("spend.csv"), state: store.file,
                             attribution: root.appendingPathComponent("attribution.json"))
        #expect(relaunched.hiddenLines == ["account:work"])
        #expect(chart.visible(hiding: Set(chart.series.map(\.key))).isEmpty)
    }

    @Test func everyLineHiddenDrawsAnEmptyGraph() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-spend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(file: root.appendingPathComponent("state.json"))
        let chart = Self.chart(Self.rows, .usd)
        let mirror = GaugeMirror.shared
        let names = chart.series.map(\.key).filter { !mirror.hiddenLines.contains($0) }
        for name in names { try mirror.toggle(line: name, store: store) }
        defer { for name in names { try? mirror.toggle(line: name, store: store) } }
        #expect(HugAndHoverTests.height(SpendTab(chart: chart).fixedSize(horizontal: false, vertical: true),
                                        width: 520) > 0)
    }

    @Test func aTotalNamedAccountCanBeToggledSeparately() {
        let chart = Self.chart(
            [Self.row("total", "2026-09-21", "03", "claude-opus-5")],
            .tokens
        )
        #expect(chart.series.count == 2)
        #expect(chart.visible(hiding: ["total"]).count == 1)
    }

    @Test func failedLegendSaveLeavesLineVisible() throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-blocked-\(UUID().uuidString)")
        try Data().write(to: parent)
        defer { try? FileManager.default.removeItem(at: parent) }

        let store = StateStore(file: parent.appendingPathComponent("state.json"))
        let mirror = GaugeMirror()
        #expect(throws: (any Error).self) {
            try mirror.toggle(line: "total", store: store)
        }
        #expect(mirror.hiddenLines.isEmpty)
    }

    // MARK: - Hover changes day halfway between two points

    @Test func hoverChangesDayHalfwayBetweenPoints() throws {
        let rows = ["2026-09-19", "2026-09-20", "2026-09-21"].map { Self.row("codex", $0, "03", "claude-opus-5") }
        let points = try #require(Self.chart(rows, .tokens).series.first { $0.name == "codex" }).points
        #expect(points.count == 3)
        func pick(_ at: String) -> Date? {
            SpendChart.point(nearest: Self.instant(at), in: points, calendar: Self.utc)?.day
        }
        // The 20th is drawn at its noon: just past its dot is still the 20th,
        // and the switch to the 21st comes at midnight, halfway to the next dot.
        #expect(pick("2026-09-20T13:00:00Z") == points[1].day)
        #expect(pick("2026-09-20T23:30:00Z") == points[1].day)
        #expect(pick("2026-09-21T00:30:00Z") == points[2].day)
        #expect(pick("2026-09-19T23:30:00Z") == points[0].day)
        #expect(SpendChart.point(nearest: Self.now, in: [], calendar: Self.utc) == nil)
    }

    // MARK: - Hover brings a line forward

    @Test func hoverDimsTheOtherLines() {
        let chart = Self.chart(Self.rows, .usd)
        let mirror = GaugeMirror()
        #expect(mirror.spendFocus == nil)
        #expect(SpendTab.dimmed(chart.series, focus: mirror.spendFocus).isEmpty)
        mirror.spendFocus = "account:personal"
        #expect(SpendTab.dimmed(chart.series, focus: mirror.spendFocus) == ["account:codex", "account:work", "total"])
        mirror.spendFocus = nil
        #expect(SpendTab.dimmed(chart.series, focus: mirror.spendFocus).isEmpty)
        #expect(SpendTab.lineTone(dimmed: true) == Tone.inkDim)
    }

    // MARK: - A partial record says why, an unavailable one says why instead

    @Test func aRecordThatIsNotWholeSaysSo() {
        let partial = SpendChart.make(record: .partial(Self.rows, "2 malformed row(s) skipped"), through: Self.attribution,
                                      rates: .bundled, measure: .usd, now: Self.now, calendar: Self.utc)
        #expect(SpendTab.reason(partial) == "2 malformed row(s) skipped")
        #expect(!partial.isEmpty)
        let unavailable = SpendChart.make(record: .unavailable("spend.csv has the wrong header"), through: Self.attribution,
                                          rates: .bundled, measure: .usd, now: Self.now, calendar: Self.utc)
        #expect(unavailable.emptyMessage == "spend.csv has the wrong header")
        #expect(SpendTab.messageIsWarning(unavailable))
        #expect(SpendTab.reason(Self.chart(Self.rows, .usd)) == nil)
    }

    // MARK: - The Seats tab and the menu are untouched

    @Test func theSeatsTabAndTheMenuAreStillDrawn() {
        func windows(_ percent: Int) -> [SeatGaugeCore.Window] {
            [Glance.window(.weekly, used: percent), Glance.window(.fiveHour, used: percent, in: 90 * 60)]
        }
        let seat = Glance.codex("work"), other = Glance.codex("team")
        let model = Glance.panel([seat, other], [windows(80), windows(20)])
        #expect(model.cards.count == 2)
        #expect(model.cards.first?.lines.map(\.kind) == [.fiveHour, .weekly])
        #expect(model.cards.first(where: \.isBest)?.id == other.id)
        #expect(model.cards.first?.lines.map(\.countdown) == ["1:30", "1d 0h"])
        #expect(model.cards.contains { $0.pace != nil })
        #expect([WindowKind.fiveHour, .weekly, .fable].map(\.shortName) == ["5H", "WK", "FABLE"])
        #expect(MeterTone.of(usedPercent: 59) == .good)
        #expect(MeterTone.of(usedPercent: 60) == .warning)
        #expect(MeterTone.of(usedPercent: 85) == .danger)
        #expect(Tab.allCases.map(\.title) == ["SEATS", "SPEND"])
        #expect(PanelMenu().menu.items.prefix(4).map(\.title) == ["Sync all", "Launch at login", "Reveal config", "Quit"])
        #expect(Self.chart(Self.rows, .tokens).days == 28)
    }

    // MARK: - Fails closed

    @Test func failsClosedWithALineNotAFrame() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-spend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = SpendChart.read(csv: root.appendingPathComponent("spend.csv"),
                                      state: root.appendingPathComponent("state.json"),
                                      attribution: root.appendingPathComponent("attribution.json"),
                                      rates: .bundled, measure: .tokens, now: Self.now, calendar: Self.utc)
        #expect(missing.series.isEmpty)
        #expect(missing.emptyMessage != nil)

        let old = Self.chart([Self.row("personal", "2026-01-01", "01", "claude-sonnet-5")], .tokens)
        #expect(old.series.isEmpty)
        #expect(old.emptyMessage == "no spend recorded yet")

        #expect(SpendTab.dimmed(Self.chart(Self.rows, .usd).series, focus: "nobody").isEmpty)
        let state = try JSONDecoder().decode(AppState.self, from: Data(#"{"textSizeStep": 3}"#.utf8))
        #expect(state.measure == .tokens)
    }
}
