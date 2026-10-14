import Foundation
import Testing

@testable import SeatGaugeCore

@Suite struct SpendCombinedTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func row(_ seat: String, _ model: String, input: Int, usd: Decimal? = nil) -> SpendRow {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        return SpendRow(seat: seat, day: day.string(from: now), hour: "05", model: model,
                        counts: TokenCounts(responses: 1, input: input), usd: usd, sealed: true)
    }

    @Test("a picked model draws alone, on every account that used it")
    func picked() {
        let rows = [Self.row("work", "claude-opus-5-5", input: 3_000_000),
                    Self.row("home", "claude-opus-5-5", input: 1_000_000),
                    Self.row("home", "gpt-6-astra", input: 2_000_000)]
        let opus = SpendChart.make(record: .available(rows), through: AttributionRecord(timeZone: "UTC"),
                                   rates: .bundled, measure: .tokens, now: Self.now, model: "Opus 5.5")
        #expect(opus.series.map(\.name) == ["home", "work", "total"])
        #expect(opus.series.last?.points.map(\.amount).reduce(0, +) == 4_000_000)
        let astra = SpendChart.make(record: .available(rows), through: AttributionRecord(timeZone: "UTC"),
                                    rates: .bundled, measure: .tokens, now: Self.now, model: "Astra 6")
        #expect(astra.series.map(\.name) == ["home", "total"])
    }

    @Test("a billion tokens and more read in billions")
    func billions() {
        #expect(Measure.tokens.figure(2_233_000_000) == "2.2B tokens")
        #expect(Measure.tokens.figure(487_500_000) == "487.5M tokens")
    }

    @Test("models are named by their own version")
    func names() {
        #expect(ModelName.display("claude-opus-5-5") == "Opus 5.5")
        #expect(ModelName.display("claude-opus-4-8") == "Opus 4.8")
        #expect(ModelName.display("claude-fable-5") == "Fable 5")
        #expect(ModelName.display("claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(ModelName.display("gpt-6.1-sol") == "Sol 6.1")
        #expect(ModelName.display("gpt-6-astra") == "Astra 6")
        #expect(ModelName.display("gpt-5.5") == "GPT-5.5")
        #expect(ModelName.display("unknown") == "Other")
    }

    @Test("dollars come from tokens on today's card, not the price stored when the row was written")
    func repriced() {
        let stale = Self.row("work", "claude-opus-5-5", input: 1_000_000, usd: nil)
        #expect(Measure.usd.amount(of: stale, rates: .bundled) == 4)
        #expect(Measure.usd.amount(of: stale) == nil)
    }

    @Test("the model list follows the accounts left on, largest first, under their sum")
    func rows() {
        let rows = [Self.row("work", "claude-opus-5-5", input: 3_000_000),
                    Self.row("home", "claude-opus-5-5", input: 1_000_000),
                    Self.row("home", "gpt-6-astra", input: 2_000_000),
                    Self.row("home", "local-model", input: 5)]
        let chart = SpendChart.make(rows: rows, rates: .bundled, measure: .tokens, now: Self.now)
        #expect(chart.modelRows(hiding: []).map(\.model) == ["Opus 5.5", "Astra 6", "Other"])
        #expect(chart.modelRows(hiding: []).first?.amount == 4_000_000)
        #expect(chart.modelRows(hiding: ["account:home"]).map(\.model) == ["Opus 5.5"])
        #expect(chart.modelRows(hiding: ["account:home"]).first?.amount == 3_000_000)
        // Every account off: the list follows the total line and counts it all.
        #expect(chart.modelRows(hiding: ["account:home", "account:work"]).first?.amount == 4_000_000)
        let dollars = SpendChart.make(rows: rows, rates: .bundled, measure: .usd, now: Self.now)
        #expect(dollars.modelRows(hiding: []).map(\.model) == ["Astra 6", "Opus 5.5", "unpriced"])
    }
}
