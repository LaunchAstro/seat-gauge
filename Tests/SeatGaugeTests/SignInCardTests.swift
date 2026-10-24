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

    // MARK: - A signed-out card is one click from Sign in

    static func claude(_ id: String, open: [String]?) -> Seat {
        Seat(id: SeatID(rawValue: id), label: id.capitalized, kind: .claude(profileDir: profile.appendingPathComponent(id)),
             open: open)
    }

    @Test func aSignedOutCardsClickSignsInEvenWhenItsSeatHasAnOpenCommand() {
        let live = SeatState.live(PanelCardTests.reading("work", [PanelCardTests.weekly(used: 20)]))
        let cards = Self.cards(
            [Self.claude("work", open: ["/usr/bin/true"]), Self.claude("spare", open: nil),
             Self.claude("personal", open: ["/usr/bin/true"]), Self.claude("plain", open: nil)],
            ["work": .dormant(reason: "not logged in"), "spare": .dormant(reason: "not logged in"),
             "personal": live, "plain": live])
        #expect(cards["work"]?.click == .signIn)
        #expect(cards["spare"]?.click == .signIn)
        #expect(cards["personal"]?.click == .open)
        #expect(cards["plain"]?.click == nil)
        #expect(cards["work"]?.clickLabel == "Sign in Work")
        #expect(cards["personal"]?.clickLabel == "Open Personal")
    }

    @Test func clickingASignedOutCardStartsItsSignInAndRunsNoOpenCommand() async throws {
        let folder = try SeatOpenPanelTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("ran")
        let script = folder.appendingPathComponent("open-seat")
        try "#!/bin/sh\necho ran >> \"\(log.path)\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let seat = Self.claude("work", open: [script.path])
        let mirror = GaugeMirror()
        mirror.readCards(StateStore(file: folder.appendingPathComponent("state.json")))
        mirror.apply(Snapshot(states: [seat.id: .dormant(reason: "not logged in")], order: [seat.id]), seats: [seat])
        var signedIn: [SeatID] = []
        mirror.signIn = { signedIn.append($0) }

        let card = try #require(mirror.model(at: PanelCardTests.now).cards.first)
        #expect(mirror.click(card) == nil)
        #expect(signedIn == [seat.id])
        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: log.path), "the click ran the open command")
    }

    @Test func theHoverFaceOfASignedOutCardOffersSignIn() {
        let cards = Self.cards([Self.claude("work"), Self.claude("personal")],
                               ["work": .dormant(reason: "not logged in"),
                                "personal": .live(PanelCardTests.reading("personal", [PanelCardTests.weekly(used: 20)]))])
        let work = try? #require(cards["work"])
        let personal = try? #require(cards["personal"])
        guard let work, let personal else { return }
        let detail = CardDetail.make(card: work, history: nil, selected: nil)
        #expect(detail.signsIn)
        #expect(detail.status == DetailLine(text: CardModel.signedOut, tone: .danger))
        // The quiet copy a card off the pointer draws keeps it too.
        #expect(detail.quiet.signsIn)
        #expect(!CardDetail.make(card: personal, history: nil, selected: nil).signsIn)
    }
}
