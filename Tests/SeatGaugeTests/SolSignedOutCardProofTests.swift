import Foundation
import Testing

import SeatGaugeCore
@testable import SeatGauge

@Suite(.serialized, .sharedMirror) @MainActor struct SolSignedOutCardProofTests {
    @Test("Sol proof, criterion 2: signed-out hover keeps its red status with spend history")
    func signedOutStatusSurvivesHistory() throws {
        let seat = SignInCardTests.claude("work")
        let snapshot = Snapshot(states: [seat.id: .dormant(reason: "not logged in")], order: [seat.id])
        let rows = [DetailHistoryTests.row("work", "2026-09-23")]
        let cases: [(SpendRecord, Int?)] = [
            (.unavailable("spend.csv has the wrong header"), nil),
            (.partial(rows, "spend.csv: 1 line could not be read"), nil),
            (.available(rows), 2),
        ]
        for (record, selected) in cases {
            let model = PanelModel.make(snapshot: snapshot, seats: [seat], now: DetailHistoryTests.now,
                                        hovered: seat.id, selected: selected, spend: record,
                                        through: SeatHistoryTests.noSpans, calendar: DetailHistoryTests.utc)
            let card = try #require(model.cards.first)
            let detail = try #require(model.details[seat.id])
            try #require(card.signsIn && detail.signsIn)
            #expect(detail.status == DetailLine(text: CardModel.signedOut, tone: .danger),
                    "Sign in lost its adjacent red signed-out status: \(String(describing: detail.status))")
        }
    }

}
