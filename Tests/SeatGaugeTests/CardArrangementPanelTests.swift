import Foundation
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// The panel read through a saved arrangement: its order, the seats hidden
/// from it and the seats shown on it with nothing live to draw.
@Suite(.sharedMirror) @MainActor struct CardArrangementPanelTests {

    static let now = PanelCardTests.now
    static let seats = [PanelCardTests.seat("personal", "Personal"), PanelCardTests.seat("work", "Work"),
                        PanelCardTests.seat("spare", "Spare")]

    static func live(_ id: String, used: Int) -> SeatState {
        .live(PanelCardTests.reading(id, [PanelCardTests.weekly(used: used)]))
    }

    static func model(_ cards: CardArrangement) -> PanelModel {
        let states: [SeatID: SeatState] = [
            SeatID(rawValue: "personal"): live("personal", used: 20),
            SeatID(rawValue: "work"): live("work", used: 60),
            SeatID(rawValue: "spare"): .dormant(reason: "not logged in"),
        ]
        return PanelModel.make(snapshot: Snapshot(states: states, order: seats.map(\.id)), seats: seats,
                               now: now, hovered: nil, selected: nil, histories: [:], arrangement: cards)
    }

    @Test func withNothingSavedThePanelIsAsItWas() {
        let model = Self.model(CardArrangement())
        #expect(model.cards.map(\.label) == ["Personal", "Work"])
        #expect(model.notes == ["Spare: not logged in"])
        #expect(model.offstage.map(\.title) == ["Spare · not logged in"])
        #expect(model.summary != nil)
    }

    @Test func theSavedOrderIsTheRowsOrder() {
        let model = Self.model(CardArrangement(order: [SeatID(rawValue: "work")]))
        #expect(model.cards.map(\.label) == ["Work", "Personal"])
    }

    @Test func aHiddenSeatLeavesTheRowTheAllCardAndThePick() {
        let model = Self.model(CardArrangement(hidden: [SeatID(rawValue: "personal")]))
        #expect(model.cards.map(\.label) == ["Work"])
        #expect(model.cards[0].isBest)
        // One seat left is no average.
        #expect(model.summary == nil)
        #expect(model.offstage.map(\.title) == ["Personal · hidden", "Spare · not logged in"])
    }

    @Test func aShownDormantSeatIsAnInactiveCard() {
        let model = Self.model(CardArrangement(shown: [SeatID(rawValue: "spare")]))
        let spare = model.cards.first { $0.label == "Spare" }
        #expect(spare?.stale == "not logged in")
        #expect(spare?.isDimmed == true)
        #expect(spare?.lines.isEmpty == true)
        #expect(model.offstage.isEmpty)
        #expect(model.summary != nil)
    }

    @Test func aShownDormantSeatKeepsItsLastReportAfterRelaunch() async {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-cards-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let id = SeatID(rawValue: "work")
        let reading = PanelCardTests.reading("work", [PanelCardTests.weekly(used: 40)])
        let file = folder.appendingPathComponent("readings.json")
        let store = GaugeStore(file: file)
        _ = await store.apply(states: [id: .live(reading)], order: [id])
        _ = await store.apply(states: [id: .dormant(reason: "not logged in")], order: [id])

        let relaunched = GaugeStore(file: file)
        let snapshot = await relaunched.apply(
            states: [id: .dormant(reason: "not logged in")], order: [id])
        let model = PanelModel.make(
            snapshot: snapshot, seats: [PanelCardTests.seat("work", "Work")],
            now: PanelCardTests.now, hovered: nil, selected: nil, histories: [:],
            arrangement: CardArrangement(shown: [id]))

        #expect(model.cards.first?.lines.first?.usedPercent == 40)
        #expect(model.cards.first?.stale == "not logged in")
    }

    @Test func aRemovedSeatLeavesSavedOrder() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = StateStore(file: folder.appendingPathComponent("state.json"))

        let personal = PanelCardTests.seat("personal", "Personal")
        let work = PanelCardTests.seat("work", "Work")
        let personalReading = PanelCardTests.reading("personal", [PanelCardTests.weekly(used: 20)])
        let workReading = PanelCardTests.reading("work", [PanelCardTests.weekly(used: 40)])
        let states: [SeatID: SeatState] = [
            personal.id: .live(personalReading), work.id: .live(workReading),
        ]
        let mirror = GaugeMirror()
        mirror.apply(Snapshot(states: states, order: [personal.id, work.id]),
                     seats: [personal, work])
        try mirror.arrange({
            $0.moving(work.id, to: personal.id, configured: [personal.id, work.id])
        }, store: store)

        mirror.apply(Snapshot(states: [personal.id: .live(personalReading)],
                              order: [personal.id]), seats: [personal])
        #expect(store.load().cards.order == [personal.id])

        mirror.apply(Snapshot(states: states, order: [personal.id, work.id]),
                     seats: [personal, work])
        #expect(mirror.model(at: PanelCardTests.now).cards.map(\.id)
            == [personal.id, work.id])
    }

    @Test func anEmptyConfigClearsSavedCards() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = StateStore(file: folder.appendingPathComponent("state.json"))
        let personal = SeatID(rawValue: "personal")
        let work = SeatID(rawValue: "work")
        try store.update {
            $0.cards = CardArrangement(order: [work, personal], hidden: [work])
        }

        let mirror = GaugeMirror()
        mirror.readCards(store)
        let empty = try ConfigLoader.decode(Data(#"{"seats":[]}"#.utf8))
        mirror.apply(Snapshot(states: [:], order: []), seats: empty.seats)

        #expect(store.load().cards == CardArrangement())
    }

    @Test func aHiddenDormantSeatIsAvailableBeforeTheFirstPoll() async {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-cards-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let id = SeatID(rawValue: "work")
        let reading = PanelCardTests.reading("work", [PanelCardTests.weekly(used: 40)])
        let file = folder.appendingPathComponent("readings.json")
        let store = GaugeStore(file: file)
        _ = await store.apply(states: [id: .live(reading)], order: [id])
        _ = await store.apply(states: [id: .dormant(reason: "not logged in")], order: [id])

        let relaunched = GaugeStore(file: file)
        let startup = await relaunched.snapshot
        let model = PanelModel.make(
            snapshot: startup, seats: [PanelCardTests.seat("work", "Work")],
            now: PanelCardTests.now, hovered: nil, selected: nil, histories: [:],
            arrangement: CardArrangement(hidden: [id]))

        #expect(model.offstage.map(\.id) == [id])
    }
}
