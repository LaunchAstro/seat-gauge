import Foundation
import Testing

import SeatGaugeCore

/// The spend read side: `spend.csv` through `attribution.json` from
/// `spendFrom`, on one rate card, read once and answered many ways.
@Suite struct SpendViewTests {
    struct Scratch {
        let folder: URL
        var csv: URL { folder.appendingPathComponent("spend.csv") }
        var state: URL { folder.appendingPathComponent("state.json") }
        var attribution: URL { folder.appendingPathComponent("attribution.json") }
        var rates: URL { folder.appendingPathComponent("rates.json") }

        init() throws {
            folder = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("seat-gauge-spend-view-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: folder) }
    }

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static let now = ISO8601DateFormatter().date(from: "2026-09-22T12:00:00Z")!

    static func row(_ seat: String, _ day: String, _ hour: String, _ model: String = "claude-opus-5") -> SpendRow {
        let counts = TokenCounts(responses: 1, input: 1_000_000)
        return SpendRow(seat: seat, day: day, hour: hour, model: model, counts: counts,
                        usd: RateCard.bundled.usd(model: model, counts: counts), sealed: true)
    }

    static let rows = [row("personal", "2026-09-21", "05"), row("default", "2026-09-21", "06"),
                       row("personal", "2026-09-22", "07", "claude-sonnet-5")]

    /// A card that prices the one model these rows use at a figure no
    /// bundled card has, so a chart priced on it is told apart.
    static let odd = RateCard(version: "test", models: ["claude-opus-5": Rate(input: 1234, output: 0, group: "opus")])

    @Test("the rate card is read once: after the file goes, every answer still prices on it")
    func ratesReadOnce() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try SpendCSV.write(Self.rows, to: scratch.csv)
        try Self.odd.write(to: scratch.rates)
        let view = SpendView.read(csv: scratch.csv, state: scratch.state, attribution: scratch.attribution,
                                  rates: RateCard.load(scratch.rates), zone: TimeZone(identifier: "UTC")!)
        try FileManager.default.removeItem(at: scratch.rates)
        #expect(view.rates == Self.odd)
        let history = view.history(seat: "personal", range: .week, measure: .usd, now: Self.now, calendar: Self.utc)
        #expect(history.outcome.buckets.map(\.amount).reduce(0, +) == 1234)
        let chart = view.chart(measure: .usd, now: Self.now, calendar: Self.utc)
        #expect(chart.series.first { $0.name == "personal" }?.points.map(\.amount).reduce(0, +) == 1234)
    }

    @Test("the chart, the picked model's chart and a seat's history come from one read for one choice")
    func chartAndHistoryFromOneRead() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try SpendCSV.write(Self.rows, to: scratch.csv)
        let view = SpendView.read(csv: scratch.csv, state: scratch.state, attribution: scratch.attribution,
                                  rates: .bundled, zone: TimeZone(identifier: "UTC")!)
        let choices = SpendChoices(measure: .tokens)
        #expect(view.modelChart(choices, now: Self.now) == nil)
        let picked = choices.picking("Sonnet 5")
        #expect(picked.model == "Sonnet 5")
        #expect(picked.picking("Sonnet 5").model == nil)
        let narrowed = try #require(view.modelChart(picked, now: Self.now, calendar: Self.utc))
        #expect(narrowed == SpendChart.make(record: view.record, through: view.attribution, rates: .bundled,
                                            measure: .tokens, now: Self.now, calendar: Self.utc, model: "Sonnet 5"))
        let whole = view.chart(measure: .tokens, now: Self.now, calendar: Self.utc)
        #expect(view.modelRows(whole, SpendChoices(hidden: ["total"])) == whole.modelRows(hiding: ["total"]))
        let history = view.history(seat: "personal", range: .week, measure: .tokens, now: Self.now, calendar: Self.utc)
        #expect(history.outcome.buckets.map(\.amount).reduce(0, +) == 2_000_000)
    }

    @Test("a missing or malformed attribution file is one fallback: no spans, so main login cells are unattributed")
    func oneFallbackForMissingAttribution() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try SpendCSV.write(Self.rows, to: scratch.csv)
        let utc = TimeZone(identifier: "UTC")!
        let missing = SpendView.read(csv: scratch.csv, state: scratch.state, attribution: scratch.attribution,
                                     rates: .bundled, zone: utc)
        try Data("{ not json".utf8).write(to: scratch.attribution)
        let malformed = SpendView.read(csv: scratch.csv, state: scratch.state, attribution: scratch.attribution,
                                       rates: .bundled, zone: utc)
        for view in [missing, malformed] {
            #expect(view.attribution == AttributionRecord(timeZone: utc.identifier))
            let names = Set(view.chart(measure: .tokens, now: Self.now, calendar: Self.utc).series.map(\.name))
            #expect(!names.contains("default"))
            let main = view.history(seat: AttributionRecord.unattributed, range: .week, measure: .tokens,
                                    now: Self.now, calendar: Self.utc)
            #expect(main.outcome.buckets.map(\.amount).reduce(0, +) == 1_000_000)
        }
        // The file-path reader takes the same fallback.
        #expect(AttributionFile.record(at: scratch.folder.appendingPathComponent("absent.json"))
            == AttributionFile.Read.missing.kept())
    }

    @Test("what reading the records raises comes with the read")
    func problemsFromTheRead() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try Data((SpendCSV.text(Self.rows) + "not,a,row\n").utf8).write(to: scratch.csv)
        try Data("{ not json".utf8).write(to: scratch.attribution)
        let view = SpendView.read(csv: scratch.csv, state: scratch.state, attribution: scratch.attribution,
                                  rates: .bundled, zone: TimeZone(identifier: "UTC")!)
        #expect(view.problems == [.spendRecord, .attributionRecord])
    }

    @Test("reading never writes spend.csv or the files beside it")
    func readLeavesTheRecordUntouched() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try SpendCSV.write(Self.rows, to: scratch.csv)
        let before = FileManager.default.contents(atPath: scratch.csv.path)
        let stamp = try FileManager.default.attributesOfItem(atPath: scratch.csv.path)[.modificationDate] as? Date
        let view = SpendView.read(csv: scratch.csv, state: scratch.state, attribution: scratch.attribution,
                                  rates: .bundled, start: "2026-09-22")
        _ = view.chart(measure: .usd, now: Self.now)
        _ = view.history(seat: "personal", range: .month, measure: .usd, now: Self.now)
        #expect(FileManager.default.contents(atPath: scratch.csv.path) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: scratch.csv.path)[.modificationDate] as? Date == stamp)
        let left = try FileManager.default.contentsOfDirectory(atPath: scratch.folder.path)
        #expect(left == ["spend.csv"])
    }
}
