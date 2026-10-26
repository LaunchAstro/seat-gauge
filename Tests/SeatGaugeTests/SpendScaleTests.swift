import Foundation
import Testing

@testable import SeatGaugeCore

@testable import SeatGauge

@Suite struct SpendScaleTests {
    @Test("the graph's top is the full graph's peak rounded up to a round figure")
    func roundUp() {
        #expect(SpendTab.roundUp(243_000_000) == 250_000_000)
        #expect(SpendTab.roundUp(171_000_000) == 200_000_000)
        #expect(SpendTab.roundUp(3_400) == 5_000)
        #expect(SpendTab.roundUp(0) == 1)
    }

    @Test("the seats list the total first, then the seats by their figure, largest first")
    func seatsByFigure() {
        let day = Date(timeIntervalSince1970: 0)
        func line(_ name: String, _ amount: Decimal, total: Bool = false) -> SpendSeries {
            SpendSeries(name: name, points: [SpendPoint(day: day, amount: amount)], isTotal: total)
        }
        let ordered = SpendTab.byFigure([line("codex", 5), line("personal", 9), line("total", 14, total: true)])
        #expect(ordered.map(\.name) == ["total", "personal", "codex"])
    }
}
