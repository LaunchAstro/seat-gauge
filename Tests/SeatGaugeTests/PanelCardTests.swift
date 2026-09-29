import AppKit
import Foundation
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// The cards the panel draws. Every case builds a snapshot by hand or through
/// `GaugeStore`, turns it into a `PanelModel` at a named instant and reads the
/// card off that model, so nothing here needs a screen, a font or a poll.
@Suite(.sharedMirror) @MainActor struct PanelCardTests {

    // MARK: - A fixed clock and a seat or two

    /// One instant every case reads from, on a minute boundary so a countdown
    /// over the boundary is arithmetic rather than rounding.
    static let now = Date(timeIntervalSince1970: 1_758_500_100)
    static let week: Duration = .seconds(7 * 86_400)
    static let fiveHours: Duration = .seconds(5 * 3600)

    static func seat(_ id: String, _ label: String) -> Seat {
        Seat(id: SeatID(rawValue: id), label: label, kind: .codex)
    }

    /// A window used `percent`, resetting `seconds` after the fixed instant.
    static func window(_ kind: WindowKind, used percent: Int, in seconds: Double,
                       length: Duration) -> Window {
        Window(kind: kind, usedPercent: percent,
               resetsAt: now.addingTimeInterval(seconds), length: length)
    }

    static func reading(_ id: String, _ windows: [Window], ago: TimeInterval = 0) -> Reading {
        Reading(seat: SeatID(rawValue: id), windows: windows,
                takenAt: now.addingTimeInterval(-ago), plan: "max")
    }

    static func model(_ states: [SeatID: SeatState], _ seats: [Seat],
                      at instant: Date = PanelCardTests.now) -> PanelModel {
        PanelModel.make(snapshot: Snapshot(states: states, order: seats.map(\.id)),
                        seats: seats, now: instant)
    }

    /// A weekly window of the given usage with one day of the week left, which
    /// is the shape the three pace verdicts are read from.
    static func weekly(used percent: Int) -> Window {
        window(.weekly, used: percent, in: 86_400, length: week)
    }

    // MARK: - One line per window, in WindowKind order

    @Test func cardDrawsOneLinePerWindowInOrder() {
        let seats = [Self.seat("work", "Work")]
        // Out of order into the reading, so the order on the card is the
        // model's doing rather than the caller's.
        let read = Self.reading("work", [
            Self.window(.fable, used: 39, in: 6 * 86_400, length: Self.week),
            Self.window(.fiveHour, used: 42, in: 90 * 60, length: Self.fiveHours),
            Self.window(.weekly, used: 88, in: 6 * 86_400, length: Self.week),
        ])
        let card = Self.model([read.seat: .live(read)], seats).cards[0]

        #expect(card.lines.map(\.name) == ["5H", "WK", "FABLE"])
        #expect(card.lines.map(\.usedPercent) == [42, 88, 39])
        #expect(card.lines[0].countdown == "1:30")
        #expect(card.lines[1].countdown == "6d 0h")
        #expect(card.lines[0].fill == 0.42)
        // The meter tone: green, amber from 60, red from 85.
        #expect(card.lines.map(\.tone) == [.good, .danger, .good])
        #expect(MeterTone.of(usedPercent: 60) == .warning)

        // The ported pieces are built over those lines.
        #expect(ComboLayout(cards: [card]).cards.count == 1)
        #expect(Meter(line: card.lines[0]).line.usedPercent == 42)
        #expect(SeatGauge.Label(text: "5h").text == "5h")
    }

    // MARK: - The greater minimum headroom carries ▲ USE

    @Test func headroomAloneCarriesTheUsePill() {
        let seats = [Self.seat("work", "Work"), Self.seat("codex", "Codex")]
        // Work has the most headroom and the worst pace, a fifth of the
        // week gone on its first day; Codex has less headroom and is on pace.
        // Headroom alone decides.
        let work = Self.reading("work", [
            Self.window(.weekly, used: 20, in: 6 * 86_400, length: Self.week),
        ])
        let codex = Self.reading("codex", [Self.weekly(used: 86)])
        let cards = Self.model([work.seat: .live(work), codex.seat: .live(codex)], seats).cards

        #expect(cards.filter(\.isBest).map(\.label) == ["Work"])
        #expect(cards[0].pace?.tone == .amber)
        #expect(cards[1].pace?.tone == .green)
    }

    // MARK: - The minute boundary drives the countdowns

    @Test func countdownsChangeOnTheMinuteAndNeverShowSeconds() {
        let odd = Self.now.addingTimeInterval(37.4)
        let next = PanelClock.nextMinute(after: odd)
        #expect(next > odd)
        #expect(next.timeIntervalSince(odd) <= 60)
        #expect(Calendar.current.component(.second, from: next) == 0)
        #expect(next.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0)

        let seats = [Self.seat("work", "Work")]
        let read = Self.reading("work", [
            Self.window(.fiveHour, used: 42, in: 2 * 3600, length: Self.fiveHours),
            Self.window(.weekly, used: 31, in: 42 * 60, length: Self.week),
            Self.window(.fable, used: 39, in: 6 * 86_400 + 2 * 3600, length: Self.week),
        ])
        let states: [SeatID: SeatState] = [read.seat: .live(read)]
        let before = Self.model(states, seats).cards[0].lines.map(\.countdown)
        let after = Self.model(states, seats, at: Self.now.addingTimeInterval(60))
            .cards[0].lines.map(\.countdown)

        #expect(before == ["2:00", "42m", "6d 2h"])
        #expect(after == ["1:59", "41m", "6d 1h"])
        // Minutes, hours and minutes, or days and hours. Never a seconds field.
        for text in before + after {
            #expect(text.wholeMatch(of: /\d+m|\d+:\d\d|\d+d \d+h/) != nil)
        }
    }

    // MARK: - A seat dropped from the config loses its card

    @Test func droppingASeatFromTheConfigRemovesItsCard() async {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-cards-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let both = [Self.seat("work", "Work"), Self.seat("codex", "Codex")]
        let work = Self.reading("work", [Self.weekly(used: 31)])
        let codex = Self.reading("codex", [Self.weekly(used: 96)])
        let states: [SeatID: SeatState] = [work.seat: .live(work), codex.seat: .live(codex)]
        let store = GaugeStore(file: file, order: both.map(\.id))

        let first = await store.apply(states: states, order: both.map(\.id))
        #expect(PanelModel.make(snapshot: first, seats: both, now: Self.now).cards.count == 2)

        // The next poll after the config file loses a seat asks for one seat,
        // so the snapshot is keyed by one and the card goes with it.
        let kept = [both[0]]
        let second = await store.apply(states: [work.seat: .live(work)], order: kept.map(\.id))
        let cards = PanelModel.make(snapshot: second, seats: kept, now: Self.now).cards
        #expect(cards.map(\.label) == ["Work"])
    }

    // MARK: - Fails closed: stale, dormant and nothing readable

    @Test func staleIsDimmedDormantIsNotDrawnAndNothingReadableSaysSo() {
        let seats = [Self.seat("work", "Work"), Self.seat("codex", "Codex"),
                     Self.seat("team", "Team"), Self.seat("personal", "Personal")]
        // The stale seat has the most headroom and must still not be picked.
        let stale = Self.reading("work", [Self.weekly(used: 5)], ago: 23 * 60)
        let live = Self.reading("codex", [Self.weekly(used: 96)])
        let model = Self.model([
            stale.seat: .unreadable(reason: "timed out after 60s", last: stale),
            live.seat: .live(live),
            SeatID(rawValue: "team"): .dormant(reason: "not logged in"),
            SeatID(rawValue: "personal"): .unreadable(reason: "claude is not installed", last: nil),
        ], seats)

        #expect(model.cards.map(\.label) == ["Work", "Codex"])
        #expect(model.cards[0].stale == "stale · 23m")
        #expect(model.cards[0].isDimmed)
        #expect(model.cards[0].pace == nil)
        #expect(model.cards.filter(\.isBest).map(\.label) == ["Codex"])
        #expect(model.notes == ["Team: not logged in", "Personal: claude is not installed"])
        #expect(model.emptyMessage == nil)

        // Nothing readable at all: one line, and every reason under it.
        let empty = Self.model([
            SeatID(rawValue: "team"): .dormant(reason: "not logged in"),
            SeatID(rawValue: "personal"): .unreadable(reason: "claude is not installed", last: nil),
        ], [seats[2], seats[3]])
        #expect(empty.cards.isEmpty)
        #expect(empty.emptyMessage == "no seat is readable")
        #expect(empty.notes.count == 2)
    }
}
