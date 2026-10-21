import Foundation
import Testing

import SeatGaugeCore

/// What a seat shows, decided once in Core for the card, `headroom.json` and
/// `seatgauge-cli`.
@Suite struct SeatViewTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func seat(_ id: String, codex: Bool = false, token: Bool = false, label: String? = nil) -> Seat {
        Seat(id: SeatID(rawValue: id), label: label ?? id,
             kind: codex ? .codex : .claude(profileDir: URL(fileURLWithPath: "/tmp/profile-\(id)")),
             tokenFile: token ? URL(fileURLWithPath: "/tmp/\(id).token") : nil)
    }

    static func reading(_ id: String, used: [WindowKind: Int], at taken: Date = now) -> Reading {
        Reading(seat: SeatID(rawValue: id),
                windows: used.keys.sorted().map {
                    Window(kind: $0, usedPercent: used[$0]!, resetsAt: taken.addingTimeInterval(3600),
                           length: .seconds(7 * 86_400))
                },
                takenAt: taken, plan: "max")
    }

    static func view(_ seat: Seat, _ state: SeatState?, now: Date = now, pollMinutes: Int = 5) -> SeatView {
        SeatView(id: seat.id, seat: seat,
                 snapshot: Snapshot(states: state.map { [seat.id: $0] } ?? [:], order: [seat.id]),
                 now: now, pollMinutes: pollMinutes)
    }

    @Test("a Claude reading with no 5-hour window shows one at 0% with no reset and the whole five hours ahead")
    func unstartedFiveHourIsAWindow() {
        let claude = Self.view(Self.seat("work"), .live(Self.reading("work", used: [.weekly: 40])))
        let five = claude.windows.first
        #expect(claude.windows.map(\.kind) == [.fiveHour, .weekly])
        #expect(five?.usedPercent == 0)
        #expect(five?.left == 100)
        #expect(five?.resetsAt == nil)
        #expect(five?.countdown(now: Self.now) == "5:00")
        // A Codex seat has no 5-hour window to start.
        let codex = Self.view(Self.seat("codex", codex: true), .live(Self.reading("codex", used: [.weekly: 40])))
        #expect(codex.windows.map(\.kind) == [.weekly])
    }

    @Test("headroom.json writes the view's windows, the unstarted one included, and the same plan")
    func cardFileAndCLIListTheSameWindows() throws {
        let seat = Self.seat("work")
        let snapshot = Snapshot(states: [seat.id: .live(Self.reading("work", used: [.weekly: 40, .fable: 5]))],
                                order: [seat.id])
        let view = SeatView(id: seat.id, seat: seat, snapshot: snapshot, now: Self.now)
        let data = try Headroom(snapshot: snapshot, seats: [seat], pollMinutes: 5, now: Self.now).data()
        let row = try #require(((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["seats"]
            as? [[String: Any]])?.first)
        let keys = ["five_hour": WindowKind.fiveHour, "weekly": .weekly, "fable": .fable]
        let written = keys.filter { row[$0.key] != nil }.map(\.value).sorted()
        #expect(written == view.windows.map(\.kind))
        #expect(row["plan"] as? String == view.plan)
    }

    @Test("a reading is fresh until it is two poll intervals old, and the synced line and the file agree on it")
    func staleAfterTwoPollIntervals() {
        let seat = Self.seat("work")
        let edge = Self.now.addingTimeInterval(-10 * 60)
        let fresh = SeatState.live(Self.reading("work", used: [.weekly: 20], at: edge.addingTimeInterval(1)))
        let old = SeatState.live(Self.reading("work", used: [.weekly: 20], at: edge))
        #expect(fresh.isFresh(now: Self.now, pollMinutes: 5))
        #expect(!old.isFresh(now: Self.now, pollMinutes: 5))
        #expect(!SeatState.unreadable(reason: "timed out", last: Self.reading("work", used: [.weekly: 20]))
            .isFresh(now: Self.now, pollMinutes: 5))
        #expect(!SeatState.dormant(reason: "not logged in").isFresh(now: Self.now, pollMinutes: 5))

        func synced(_ state: SeatState) -> String {
            GaugeView(snapshot: Snapshot(states: [seat.id: state], order: [seat.id]), seats: [seat],
                      now: Self.now, pollMinutes: 5).synced
        }
        #expect(synced(fresh) == "all seats synced 9m ago")
        #expect(synced(old) == "0 of 1 synced")
        #expect(Self.view(seat, fresh).fresh)
        #expect(!Self.view(seat, old).fresh)
    }

    @Test("the seat meters' 60 and 85 lines are the lines a machine's room turns busy and full on")
    func meterLinesAreTheRoomLines() {
        func room(cpu: Int) -> Room {
            MachineSummary(reading: MachineReading(takenAt: Self.now, cpuUsed: cpu, load: [1, 1, 1], cores: 8,
                                                   ramUsed: 10, ramBytes: 1, diskUsed: 50,
                                                   diskFreeBytes: 500_000_000_000, agents: nil),
                           samples: [], now: Self.now).room
        }
        #expect(MeterLines.warning == 60)
        #expect(MeterLines.danger == 85)
        #expect(room(cpu: MeterLines.warning - 1) == .free)
        #expect(room(cpu: MeterLines.warning) == .busy)
        #expect(room(cpu: MeterLines.danger) == .full)
    }

    @Test("the best seat, the offstage reasons and the sign-in offer are decided in the view")
    func pickOffstageAndSignIn() {
        let seats = [Self.seat("one"), Self.seat("two"), Self.seat("off"), Self.seat("out"), Self.seat("new"),
                     Self.seat("gone")]
        let snapshot = Snapshot(states: [
            seats[0].id: .live(Self.reading("one", used: [.fiveHour: 50, .weekly: 50])),
            seats[1].id: .live(Self.reading("two", used: [.fiveHour: 10, .weekly: 10])),
            seats[2].id: .dormant(reason: "switched off"),
            seats[3].id: .dormant(reason: "not logged in"),
            seats[5].id: .live(Self.reading("gone", used: [.fiveHour: 0, .weekly: 0])),
        ], order: seats.map(\.id))
        // The hidden seat has the most room, and is never the pick.
        let gauge = GaugeView(snapshot: snapshot, seats: seats, now: Self.now,
                              arrangement: CardArrangement(hidden: [seats[5].id]))
        #expect(gauge.seats.map(\.isBest) == [false, true, false, false, false, false])
        #expect(gauge.seats.map(\.offstage) == [nil, nil, "switched off", nil, "not read yet", "hidden"])
        #expect(gauge.seats[3].signsIn)
        #expect(gauge.seats[3].stale == SeatView.signedOut)
        #expect(gauge.seats.filter(\.signsIn).count == 1)
    }

    @Test("a token seat is dated on its own and left out of the synced line")
    func tokenSeatIsDated() {
        let seats = [Self.seat("work"), Self.seat("pinned", token: true)]
        let snapshot = Snapshot(states: [
            seats[0].id: .live(Self.reading("work", used: [.weekly: 20], at: Self.now.addingTimeInterval(-60))),
            seats[1].id: .live(Self.reading("pinned", used: [.weekly: 20], at: Self.now.addingTimeInterval(-5400))),
        ], order: seats.map(\.id))
        let gauge = GaugeView(snapshot: snapshot, seats: seats, now: Self.now)
        #expect(gauge.seats.map(\.dated) == [nil, "synced 1:30 ago"])
        #expect(gauge.synced == "all seats synced 1m ago")
    }

    @Test("a stale card keeps its last figures and has no pace; a live one has the weekly verdict")
    func staleHasNoPace() {
        let seat = Self.seat("work")
        let reading = Self.reading("work", used: [.weekly: 50], at: Self.now.addingTimeInterval(-3600))
        let live = Self.view(seat, .live(reading))
        let failed = Self.view(seat, .unreadable(reason: "timed out", last: reading))
        #expect(live.pace != nil)
        #expect(live.stale == nil)
        #expect(failed.pace == nil)
        #expect(failed.stale == "stale · 1:00")
        #expect(failed.windows == live.windows)
    }
}
