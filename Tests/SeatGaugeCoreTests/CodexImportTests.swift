import Foundation
import Testing

@testable import SeatGaugeCore

/// The one-off Codex import: every rollout still on disk, read into the cells
/// the record lacks. A second import adds nothing and a sealed cell is never
/// changed. Rollouts are written by hand with made-up session ids.
@Suite struct CodexImportTests {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("seat-gauge-import-\(UUID().uuidString)", isDirectory: true)
    var csv: URL { folder.appendingPathComponent("spend.csv") }
    var sessions: URL { folder.appendingPathComponent("sessions", isDirectory: true) }
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    let now = ISO8601DateFormatter().date(from: "2026-09-29T00:00:00Z")!

    var coordinator: SpendCoordinator {
        SpendCoordinator(csv: csv, state: folder.appendingPathComponent("state.json"), primer: folder,
                         codex: CodexCollector(sessions: sessions, primer: folder.appendingPathComponent("codex-primer")),
                         calendar: calendar, log: { _ in })
    }

    func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    func usage(_ input: Int, _ output: Int) -> [String: Int] {
        ["input_tokens": input, "cached_input_tokens": 0, "output_tokens": output,
         "reasoning_output_tokens": 0, "total_tokens": input + output]
    }

    /// One session on 5 May: two responses in the 10:00 hour, 300 in and 30 out.
    func session() throws {
        let day = sessions.appendingPathComponent("2026/05/05", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let lines = [
            line(["timestamp": "2026-05-05T10:00:00Z", "type": "session_meta",
                  "payload": ["id": "s-one", "timestamp": "2026-05-05T10:00:00Z", "cwd": "/work/project"]]),
            line(["timestamp": "2026-05-05T10:00:01Z", "type": "turn_context",
                  "payload": ["model": "gpt-5", "cwd": "/work/project"]]),
            line(["timestamp": "2026-05-05T10:01:00Z", "type": "event_msg",
                  "payload": ["type": "token_count",
                              "info": ["total_token_usage": usage(100, 10), "last_token_usage": usage(100, 10)]]]),
            line(["timestamp": "2026-05-05T10:02:00Z", "type": "event_msg",
                  "payload": ["type": "token_count",
                              "info": ["total_token_usage": usage(300, 30), "last_token_usage": usage(200, 20)]]]),
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: day.appendingPathComponent("rollout-2026-05-05T10-00-00-s-one.jsonl"))
    }

    func row(day: String, counts: TokenCounts, sealed: Bool) -> SpendRow {
        SpendRow(seat: CodexRollout.seat, day: day, hour: "10", model: "gpt-5",
                 counts: counts, usd: nil, sealed: sealed)
    }

    @Test func theFirstImportAddsTheOldSessionBesideTheRecord() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try session()
        let live = row(day: "2026-09-27", counts: TokenCounts(responses: 1, input: 5, output: 1), sealed: true)
        try SpendCSV.write([live], to: csv)

        let added = try #require(try await coordinator.importCodex(rates: .bundled, now: now))
        #expect(added.map(\.day) == ["2026-05-05"])
        #expect(added.first?.responses == 2)
        #expect(added.first?.output == 30)
        #expect(added.first?.sealed == true)
        #expect(SpendCSV.read(csv).count == 2)
        #expect(SpendCSV.read(csv).contains(live))
    }

    @Test func aSecondImportAddsNothing() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try session()
        _ = try await coordinator.importCodex(rates: .bundled, now: now)
        let before = FileManager.default.contents(atPath: csv.path)

        let again = try #require(try await coordinator.importCodex(rates: .bundled, now: now))
        #expect(again.isEmpty)
        #expect(FileManager.default.contents(atPath: csv.path) == before)
    }

    @Test func aSealedCellIsLeftAsItWas() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try session()
        let sealed = row(day: "2026-05-05", counts: TokenCounts(responses: 9, input: 9, output: 9), sealed: true)
        try SpendCSV.write([sealed], to: csv)

        let added = try #require(try await coordinator.importCodex(rates: .bundled, now: now))
        #expect(added.isEmpty)
        #expect(SpendCSV.read(csv) == [sealed])
    }

    @Test func importCompletesAnOpenCell() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try session()
        try SpendCSV.write([
            row(day: "2026-05-05",
                counts: TokenCounts(responses: 1, input: 100, output: 10),
                sealed: false)
        ], to: csv)

        let at = ISO8601DateFormatter().date(from: "2026-05-05T10:03:00Z")!
        _ = try #require(try await coordinator.importCodex(rates: .bundled, now: at))
        let stored = try #require(SpendCSV.read(csv).first)
        #expect(stored.responses == 2)
        #expect(stored.input == 300)
        #expect(stored.output == 30)
    }

    @Test func importDoesNotDuplicateARecordedResponseAfterTimeZoneChange() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try session()
        let original = row(day: "2026-05-05",
                           counts: TokenCounts(responses: 2, input: 300, output: 30),
                           sealed: true)
        try SpendCSV.write([original], to: csv)
        let state = folder.appendingPathComponent("state.json")
        try StateStore(file: state).update {
            $0.timeZone = "UTC"
            $0.rolledUpAt = now
        }

        var movedCalendar = calendar
        movedCalendar.timeZone = TimeZone(secondsFromGMT: 32400)!
        let moved = SpendCoordinator(
            csv: csv, state: state, primer: folder,
            codex: CodexCollector(
                sessions: sessions,
                primer: folder.appendingPathComponent("codex-primer")),
            calendar: movedCalendar, log: { _ in })
        let added = try #require(try await moved.importCodex(rates: .bundled, now: now))
        #expect(added.isEmpty)
        #expect(SpendCSV.read(csv) == [original])
    }

    @Test func completedCellReportsOnlyNewTokens() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try session()
        try SpendCSV.write([
            row(day: "2026-05-05",
                counts: TokenCounts(responses: 1, input: 100, output: 10),
                sealed: false)
        ], to: csv)

        let at = ISO8601DateFormatter().date(from: "2026-05-05T10:03:00Z")!
        let reported = try #require(try await coordinator.importCodex(rates: .bundled, now: at))
        let tokens = reported.reduce(0) {
            $0 + $1.input + $1.output + $1.cacheRead + $1.cacheWrite5m + $1.cacheWrite1h
        }
        #expect(tokens == 220)
        #expect(SpendCSV.read(csv).first?.input == 300)
    }

    @Test func secondImportAfterTimeZoneMoveAddsNothing() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try session()
        _ = try #require(try await coordinator.importCodex(rates: .bundled, now: now))
        let before = try Data(contentsOf: csv)

        var movedCalendar = calendar
        movedCalendar.timeZone = TimeZone(secondsFromGMT: 32400)!
        let moved = SpendCoordinator(
            csv: csv, state: folder.appendingPathComponent("state.json"),
            primer: folder,
            codex: CodexCollector(
                sessions: sessions,
                primer: folder.appendingPathComponent("codex-primer")),
            calendar: movedCalendar, log: { _ in })
        let again = try #require(try await moved.importCodex(rates: .bundled, now: now))
        #expect(again.isEmpty)
        #expect(try Data(contentsOf: csv) == before)
    }
}
