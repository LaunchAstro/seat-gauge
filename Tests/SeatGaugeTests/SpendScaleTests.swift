import Testing

@testable import SeatGauge

@Suite struct SpendScaleTests {
    @Test("the graph's top is the full graph's peak rounded up to a round figure")
    func roundUp() {
        #expect(SpendTab.roundUp(243_000_000) == 250_000_000)
        #expect(SpendTab.roundUp(171_000_000) == 200_000_000)
        #expect(SpendTab.roundUp(3_400) == 5_000)
        #expect(SpendTab.roundUp(0) == 1)
    }
}
