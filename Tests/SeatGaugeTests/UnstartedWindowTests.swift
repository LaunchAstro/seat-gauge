import Foundation
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// A Claude seat nobody has used for five hours replies with no 5-hour reset,
/// and the card draws that window at 0% with all five hours ahead.
@Suite(.sharedMirror) @MainActor struct UnstartedWindowTests {

    static let now = Date(timeIntervalSince1970: 1_758_500_100)

    static func card(_ kind: SeatKind) -> CardModel? {
        let seat = Seat(id: SeatID(rawValue: "work"), label: "Work", kind: kind)
        let weekly = Window(kind: .weekly, usedPercent: 40, resetsAt: now.addingTimeInterval(86_400),
                            length: .seconds(7 * 86_400))
        let reading = Reading(seat: seat.id, windows: [weekly], takenAt: now, plan: "max")
        return PanelModel.make(snapshot: Snapshot(states: [seat.id: .live(reading)], order: [seat.id]),
                               seats: [seat], now: now).cards.first
    }

    @Test func aClaudeSeatWithNoFiveHourWindowDrawsItAtZero() {
        let lines = Self.card(.claude(profileDir: URL(fileURLWithPath: "/tmp/work")))?.lines ?? []
        #expect(lines.map(\.kind) == [.fiveHour, .weekly])
        #expect(lines.first?.usedPercent == 0)
        #expect(lines.first?.countdown == "5:00")
    }

    @Test func aCodexSeatHasNoFiveHourRowToFill() {
        #expect(Self.card(.codex)?.lines.map(\.kind) == [.weekly])
    }
}
