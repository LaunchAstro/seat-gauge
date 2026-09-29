import Foundation
import Testing

import SeatGaugeCore

/// Where the user puts the cards, read against the config and kept in
/// `state.json`.
@Suite struct CardArrangementTests {

    static func ids(_ names: String...) -> [SeatID] { names.map(SeatID.init(rawValue:)) }

    @Test func savedOrderLeadsAndTheConfigDecidesWhoIsIn() {
        let saved = CardArrangement(order: Self.ids("work", "gone", "personal"))
        // A seat new to the config goes last; one gone from it drops out.
        #expect(saved.arranged(Self.ids("personal", "work", "codex")) == Self.ids("work", "personal", "codex"))
        #expect(saved.kept(Self.ids("personal", "work")).order == Self.ids("work", "personal"))
    }

    @Test func aDroppedCardTakesTheTargetsPlace() {
        let config = Self.ids("a", "b", "c")
        let none = CardArrangement()
        #expect(none.moving(SeatID(rawValue: "a"), to: SeatID(rawValue: "c"), configured: config).order
            == Self.ids("b", "c", "a"))
        #expect(none.moving(SeatID(rawValue: "c"), to: SeatID(rawValue: "a"), configured: config).order
            == Self.ids("c", "a", "b"))
        #expect(none.moving(SeatID(rawValue: "a"), to: SeatID(rawValue: "unknown"), configured: config) == none)
    }

    @Test func hidingOneSeatTouchesNoOther() {
        let work = SeatID(rawValue: "work")
        let shown = CardArrangement(shown: [SeatID(rawValue: "dormant")]).hiding(work)
        #expect(shown.hidden == [work])
        #expect(shown.shown == [SeatID(rawValue: "dormant")])
        #expect(shown.showing(work).hidden.isEmpty)
    }

    @Test func theArrangementSurvivesAWriteAndARead() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-cards-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = StateStore(file: folder.appendingPathComponent("state.json"))
        let cards = CardArrangement(order: Self.ids("work", "personal"), hidden: [SeatID(rawValue: "work")],
                                    shown: [SeatID(rawValue: "spare")])
        try store.update { $0.cards = cards }
        #expect(store.load().cards == cards)
        // An older file has none of the keys: nothing hidden, config order.
        #expect(AppState().cards == CardArrangement())
    }

    @Test func aDormantSeatKeepsWhatItLastReported() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-cards-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = SeatID(rawValue: "work")
        let read = Reading(seat: id, windows: [], takenAt: Date(timeIntervalSince1970: 1_758_500_100), plan: nil)
        let store = GaugeStore(file: folder.appendingPathComponent("readings.json"))
        _ = await store.apply(states: [id: .live(read)], order: [id])
        let dormant = await store.apply(states: [id: .dormant(reason: "not logged in")], order: [id])
        #expect(dormant.reported[id] == read)
        let again = await store.apply(states: [id: .dormant(reason: "not logged in")], order: [id])
        #expect(again.reported[id] == read)
    }
}
