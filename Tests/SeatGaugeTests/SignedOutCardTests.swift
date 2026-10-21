import Foundation
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// A seat that signs itself out stays on the window with a red warning and
/// an × that puts it away, rather than dropping off unseen.
@Suite(.sharedMirror) @MainActor struct SignedOutCardTests {

    typealias SignIn = SignInCardTests

    static func model(_ arrangement: CardArrangement) -> PanelModel {
        let seats = [SignIn.claude("work"), SignIn.claude("off")]
        let states: [SeatID: SeatState] = [SeatID(rawValue: "work"): .dormant(reason: "not logged in"),
                                           SeatID(rawValue: "off"): .dormant(reason: "switched off")]
        return PanelModel.make(snapshot: Snapshot(states: states, order: seats.map(\.id)), seats: seats,
                               now: PanelCardTests.now, hovered: nil, selected: nil, histories: [:],
                               arrangement: arrangement)
    }

    @Test func aSignedOutSeatIsDrawnUnaskedAndSaysSo() {
        let model = Self.model(CardArrangement())
        let card = model.cards.first { $0.id.rawValue == "work" }
        #expect(card?.stale == CardModel.signedOut)
        #expect(card?.signsIn == true)
        // Any other dormant seat still waits to be asked for.
        #expect(!model.cards.contains { $0.id.rawValue == "off" })
        #expect(model.offstage.map(\.id.rawValue) == ["off"])
    }

    @Test func itsCrossPutsItInThePlusMenu() {
        let model = Self.model(CardArrangement(hidden: [SeatID(rawValue: "work")]))
        #expect(model.cards.isEmpty)
        #expect(model.offstage.first { $0.id.rawValue == "work" }?.why == "hidden")
    }
}
