import Foundation
import Testing

@testable import SeatGaugeCore

@Suite struct SpendCombinedTests {
    @Test("ALL adds every family's figure, and the unpriced count adds nothing")
    func combined() {
        let totals = [SpendGroupTotal(group: "Opus", amount: 300, responses: 3),
                      SpendGroupTotal(group: "Sol", amount: 200, responses: 2),
                      SpendGroupTotal(group: SpendChart.unpriced, amount: nil, responses: 4)]
        let chart = SpendChart(series: [], totals: totals, from: Date(), days: 28)
        #expect(chart.combined == 500)
        #expect(SpendChart(series: [], totals: [], from: Date(), days: 28).combined == nil)
    }
}
