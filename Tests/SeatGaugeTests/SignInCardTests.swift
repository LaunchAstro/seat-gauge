import Foundation
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// The Sign in action on a card: offered where the core says a seat can be
/// signed in, and nowhere else.
@Suite(.sharedMirror) @MainActor struct SignInCardTests {

    static let profile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("never-made")

    static func claude(_ id: String, token: Bool = false) -> Seat {
        Seat(id: SeatID(rawValue: id), label: id.capitalized, kind: .claude(profileDir: profile.appendingPathComponent(id)),
             tokenFile: token ? profile.appendingPathComponent("\(id).token") : nil)
    }

    static func cards(_ seats: [Seat], _ states: [String: SeatState]) -> [String: CardModel] {
        let ids = seats.map(\.id)
        let model = PanelModel.make(
            snapshot: Snapshot(states: Dictionary(uniqueKeysWithValues: states.map { (SeatID(rawValue: $0), $1) }),
                               order: ids),
            seats: seats, now: PanelCardTests.now, hovered: nil, selected: nil, histories: [:],
            arrangement: CardArrangement(shown: Set(ids)))
        return Dictionary(uniqueKeysWithValues: model.cards.map { ($0.id.rawValue, $0) })
    }

    @Test func aShownOwnLoginSeatThatIsNotLoggedInOffersSignIn() {
        let notLoggedIn = SeatState.dormant(reason: "not logged in")
        let cards = Self.cards(
            [Self.claude("work"), Self.claude("spare", token: true), PanelCardTests.seat("codex", "Codex"),
             Self.claude("personal"), Self.claude("off")],
            ["work": notLoggedIn, "spare": notLoggedIn, "codex": .dormant(reason: "Codex needs a login"),
             "personal": .live(PanelCardTests.reading("personal", [PanelCardTests.weekly(used: 20)])),
             "off": .dormant(reason: "switched off")])
        #expect(cards["work"]?.signsIn == true)
        #expect(cards["spare"]?.signsIn == false)
        #expect(cards["codex"]?.signsIn == false)
        #expect(cards["personal"]?.signsIn == false)
        #expect(cards["off"]?.signsIn == false)
    }

    @Test func aSeatThatLastReportedSomethingStillOffersSignIn() async {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-sign-in-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = SeatID(rawValue: "work")
        let store = GaugeStore(file: folder.appendingPathComponent("readings.json"))
        _ = await store.apply(states: [id: .live(PanelCardTests.reading("work", [PanelCardTests.weekly(used: 40)]))],
                              order: [id])
        let snapshot = await store.apply(states: [id: .dormant(reason: "not logged in")], order: [id])
        let model = PanelModel.make(snapshot: snapshot, seats: [Self.claude("work")],
                                    now: PanelCardTests.now, hovered: nil, selected: nil, histories: [:],
                                    arrangement: CardArrangement(shown: [id]))
        #expect(model.cards.first?.lines.isEmpty == false)
        #expect(model.cards.first?.signsIn == true)
    }
}
