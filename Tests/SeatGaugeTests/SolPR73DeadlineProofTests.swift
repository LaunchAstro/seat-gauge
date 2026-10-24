import Testing
@testable import SeatGauge

@Suite @MainActor struct SolPR73DeadlineProofTests {
    @Test("Sol proof, criterion 3: the refresh fallback is no later than fifteen minutes")
    func theRefreshFallbackIsNoLaterThanFifteenMinutes() {
        #expect(SignIn.limit <= 15 * 60,
                "Without a marker a started login must release its seat and refresh after fifteen minutes")
    }
}
