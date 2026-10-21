import Foundation
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// The panel reads the rate card with the record, once, and draws every
/// spend figure from that read.
@Suite(.sharedMirror) @MainActor struct SpendReadOnceTests {
    @Test func drawingAgainReadsNoRateCard() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-read-once-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let today = DateFormatter()
        today.dateFormat = "yyyy-MM-dd"
        let counts = TokenCounts(responses: 1, input: 1_000_000)
        try SpendCSV.write([SpendRow(seat: "personal", day: today.string(from: Date()), hour: "01",
                                     model: "claude-opus-5", counts: counts, usd: nil, sealed: false)],
                           to: folder.appendingPathComponent("spend.csv"))
        let card = RateCard(version: "test", models: ["claude-opus-5": Rate(input: 1234, output: 0, group: "opus")])
        try card.write(to: RateCard.defaultFile)
        defer { try? FileManager.default.removeItem(at: RateCard.defaultFile) }

        let mirror = GaugeMirror()
        mirror.readSpend(csv: folder.appendingPathComponent("spend.csv"),
                         state: folder.appendingPathComponent("state.json"),
                         attribution: folder.appendingPathComponent("attribution.json"))
        try FileManager.default.removeItem(at: RateCard.defaultFile)
        // A new measure redraws the tab; it prices on the card read with the record.
        try mirror.choose(measure: .usd, store: StateStore(file: folder.appendingPathComponent("state.json")))
        let line = try #require(mirror.chart.series.first { $0.name == "personal" })
        #expect(line.points.map(\.amount).reduce(0, +) == 1234)
    }
}
