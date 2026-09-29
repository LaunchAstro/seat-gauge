import Foundation
import Testing

import SeatGaugeCore

@Suite struct HeadroomTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let utcPlus10 = TimeZone(secondsFromGMT: 36000)!

    static func seat(_ id: String, codex: Bool = false, plan: String? = nil) -> Seat {
        Seat(id: SeatID(rawValue: id), label: id.capitalized,
             kind: codex ? .codex : .claude(profileDir: URL(fileURLWithPath: "/tmp/profile-\(id)")),
             account: "someone", plan: plan)
    }

    static func reading(_ id: String, used: [WindowKind: Int], at taken: Date = now) -> Reading {
        Reading(seat: SeatID(rawValue: id),
                windows: used.keys.sorted().map {
                    Window(kind: $0, usedPercent: used[$0]!, resetsAt: taken.addingTimeInterval(3600),
                           length: .seconds(18000))
                },
                takenAt: taken, plan: "max")
    }

    static func json(_ headroom: Headroom) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: headroom.data()) as! [String: Any]
    }

    static func rows(_ object: [String: Any]) -> [[String: Any]] { object["seats"] as! [[String: Any]] }

    @Test("headroom.json lists every seat in config order with only what the cards show")
    func shape() throws {
        let seats = [Self.seat("work", plan: "Max 20x"), Self.seat("codex", codex: true)]
        let snapshot = Snapshot(states: [
            SeatID(rawValue: "work"): .live(Self.reading("work", used: [.fiveHour: 30, .weekly: 55, .fable: 10])),
            SeatID(rawValue: "codex"): .dormant(reason: "not logged in"),
        ], order: seats.map(\.id))
        let object = try Self.json(Headroom(snapshot: snapshot, seats: seats, pollMinutes: 5,
                                            now: Self.now, timeZone: Self.utcPlus10))

        // Data per seat and no single pick, so a reader spreads the work.
        #expect(Set(object.keys) == ["updated", "seats"])
        #expect(object["updated"] as? String == "2026-09-22T00:13:20+10:00")

        let rows = Self.rows(object)
        #expect(rows.map { $0["id"] as? String } == ["work", "codex"])
        let work = rows[0]
        #expect(Set(work.keys) == ["id", "kind", "plan", "stale", "read_at", "five_hour", "weekly", "fable"])
        #expect(work["read_at"] as? String == "2026-09-22T00:13:20+10:00")
        #expect(work["kind"] as? String == "claude")
        #expect(work["plan"] as? String == "Max 20x")
        #expect(work["stale"] as? Bool == false)
        let weekly = work["weekly"] as! [String: Any]
        #expect(weekly["used"] as? Int == 55)
        #expect(weekly["left"] as? Int == 45)
        #expect(weekly["resets"] as? String == "2026-09-22T01:13:20+10:00")

        // Dormant: no windows, and a missing plan or reading is said as null.
        let codex = rows[1]
        #expect(Set(codex.keys) == ["id", "kind", "plan", "stale", "read_at"])
        #expect(codex["read_at"] is NSNull)
        #expect(codex["kind"] as? String == "codex")
        #expect(codex["plan"] is NSNull)
        #expect(codex["stale"] as? Bool == true)
    }

    @Test("a seat is stale when its last read failed, it was never read, or it is two polls old")
    func stale() throws {
        let seats = ["fresh", "failed", "old", "never"].map { Self.seat($0) }
        let snapshot = Snapshot(states: [
            SeatID(rawValue: "fresh"): .live(Self.reading("fresh", used: [.weekly: 20],
                                                          at: Self.now.addingTimeInterval(-9 * 60))),
            SeatID(rawValue: "failed"): .unreadable(reason: "timed out",
                                                    last: Self.reading("failed", used: [.weekly: 40])),
            SeatID(rawValue: "old"): .live(Self.reading("old", used: [.weekly: 20],
                                                        at: Self.now.addingTimeInterval(-11 * 60))),
        ], order: seats.map(\.id))
        let rows = Self.rows(try Self.json(Headroom(snapshot: snapshot, seats: seats, pollMinutes: 5,
                                                    now: Self.now)))

        #expect(rows.map { $0["stale"] as? Bool } == [false, true, true, true])
        // A failed read keeps its last windows, as its dimmed card does.
        #expect((rows[1]["weekly"] as? [String: Any])?["used"] as? Int == 40)
        #expect(rows[3]["weekly"] == nil)
    }

    @Test("GaugeStore writes headroom.json beside readings.json on every apply")
    func written() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-headroom-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = GaugeStore(file: folder.appendingPathComponent("readings.json"))
        let seat = Self.seat("work")
        _ = await store.apply(states: [seat.id: .live(Self.reading("work", used: [.weekly: 25]))],
                              order: [seat.id], seats: [seat], pollMinutes: 5, now: Self.now)

        #expect(store.headroomFile == folder.appendingPathComponent("headroom.json"))
        let data = try #require(FileManager.default.contents(atPath: store.headroomFile.path))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(Self.rows(object).map { $0["id"] as? String } == ["work"])
        #expect(await store.problem == nil)
    }
}
