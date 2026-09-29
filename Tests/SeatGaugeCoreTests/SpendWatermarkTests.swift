import Foundation
import Testing

@testable import SeatGaugeCore

/// A second roll-up must not empty a cell.
///
/// A cell is `(seat, day, hour, model)` and every session writing in that hour
/// shares it, so the merge replacing an unsealed cell is only right when the
/// run behind it walked every transcript feeding that cell. A walk that
/// skipped everything untouched since the last roll-up, which on a live
/// machine is most files, would drop a quiet session's tokens on the next run,
/// and the cell would seal that way 48 h later. These cases hold the walk to
/// the only cutoff that is safe, which is the sealing rule itself.
@Suite struct SpendWatermarkTests {

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func date(_ text: String) -> Date {
        let reader = ISO8601DateFormatter()
        reader.formatOptions = [.withInternetDateTime]
        return reader.date(from: text)!
    }

    /// One assistant line, as a transcript writes it.
    static func line(request: String, id: String, at: String, input: Int, output: Int) -> String {
        "{\"type\":\"assistant\",\"requestId\":\"\(request)\",\"timestamp\":\"\(at)\","
            + "\"message\":{\"id\":\"\(id)\",\"model\":\"claude-opus-5\","
            + "\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output)}}}\n"
    }

    /// A profile tree of one session with two transcripts in it, each with the
    /// mtime the case names, since the walk reads the file's last write and
    /// not the clock the case was run on.
    struct Tree {
        let directory: URL
        let profiles: [SpendProfile]
        let rollup: SpendCoordinator

        init() throws {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("seat-gauge-watermark-\(UUID().uuidString)", isDirectory: true)
            let session = directory.appendingPathComponent(".claude/projects/repo/session",
                                                           isDirectory: true)
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            profiles = [SpendProfile(seat: "default",
                                     projects: directory.appendingPathComponent(".claude/projects",
                                                                                isDirectory: true))]
            rollup = SpendCoordinator(csv: directory.appendingPathComponent("spend.csv"),
                                 state: directory.appendingPathComponent("state.json"),
                                 primer: directory.appendingPathComponent("primer", isDirectory: true),
                                 codex: nil, calendar: SpendWatermarkTests.utc,
                                 log: { _ in })
        }

        func write(_ name: String, _ text: String, lastWrite: Date) throws {
            let file = directory.appendingPathComponent(".claude/projects/repo/session/\(name)")
            try Data(text.utf8).write(to: file, options: .atomic)
            try touch(name, lastWrite: lastWrite)
        }

        func touch(_ name: String, lastWrite: Date) throws {
            let file = directory.appendingPathComponent(".claude/projects/repo/session/\(name)")
            try FileManager.default.setAttributes([.modificationDate: lastWrite],
                                                  ofItemAtPath: file.path)
        }

        func run(now: Date) async throws -> SpendRun {
            try #require(await rollup.run(profiles: profiles, rates: .bundled, now: now))
        }

        func cell(_ rows: [SpendRow]) -> SpendRow? {
            rows.first { $0.seat == "default" && $0.day == "2026-09-22" && $0.hour == "10"
                && $0.model == "claude-opus-5" }
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    /// Two sessions in one hour and model, the second still writing after the
    /// first roll-up: the cell keeps both. Before the fix the second run
    /// skipped the quiet transcript and wrote the cell as the busy one alone.
    @Test func secondRunKeepsAQuietTranscriptsTokens() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try tree.write("a.jsonl", Self.line(request: "req-a", id: "msg-a",
                                            at: "2026-09-22T10:05:00Z", input: 100, output: 10),
                       lastWrite: Self.date("2026-09-22T10:05:00Z"))
        try tree.write("b.jsonl", Self.line(request: "req-b", id: "msg-b",
                                            at: "2026-09-22T10:15:00Z", input: 200, output: 20),
                       lastWrite: Self.date("2026-09-22T10:15:00Z"))

        let first = try await tree.run(now: Self.date("2026-09-22T10:20:00Z"))
        #expect(tree.cell(first.rows)?.responses == 2)
        #expect(tree.cell(first.rows)?.input == 300)

        // Session A has ended. Session B writes on and is touched after the
        // first roll-up, so a walk of changed files alone would read only B.
        try tree.write("b.jsonl", Self.line(request: "req-b", id: "msg-b",
                                            at: "2026-09-22T10:15:00Z", input: 200, output: 20)
            + Self.line(request: "req-c", id: "msg-c",
                        at: "2026-09-22T10:50:00Z", input: 300, output: 30),
                       lastWrite: Self.date("2026-09-22T10:50:00Z"))

        let second = try await tree.run(now: Self.date("2026-09-22T11:00:00Z"))
        let cell = try #require(tree.cell(second.rows))
        #expect(cell.responses == 3)
        #expect(cell.input == 600)
        #expect(cell.sealed == false)
    }

    /// The walk is still allowed to pass a file by, and the rule it passes it
    /// by is the CSV's own: everything the file can feed has sealed, so the
    /// merge would refuse its rows anyway. With no roll-up behind it there is
    /// no history yet to refuse anything, so the first walk takes the lot.
    @Test func onlyAFileWhoseEveryCellHasSealedIsPassedBy() throws {
        let tree = try Tree()
        defer { tree.remove() }
        try tree.write("old.jsonl", Self.line(request: "req-a", id: "msg-a",
                                              at: "2026-09-22T10:05:00Z", input: 100, output: 10),
                       lastWrite: Self.date("2026-09-22T10:05:00Z"))
        try tree.write("new.jsonl", Self.line(request: "req-b", id: "msg-b",
                                              at: "2026-09-22T10:15:00Z", input: 200, output: 20),
                       lastWrite: Self.date("2026-09-24T09:00:00Z"))
        let late = Self.date("2026-09-24T11:01:00Z")

        // No roll-up behind it: 28 days, however old the files are.
        let first = ClaudeCollector.transcripts(tree.profiles, rolledUpAt: nil, now: late,
                                            calendar: Self.utc)
        #expect(first.count == 2)

        // 2026-09-24T10:59Z: the 10:00 cell of the 22nd seals at 11:00 on the
        // 24th, one minute later, so both files are still in the walk.
        let ran = Self.date("2026-09-22T10:20:00Z")
        let before = ClaudeCollector.transcripts(tree.profiles, rolledUpAt: ran,
                                             now: Self.date("2026-09-24T10:59:00Z"),
                                             calendar: Self.utc)
        #expect(before.count == 2)

        // One minute after it, the older file's every cell is closed.
        let after = ClaudeCollector.transcripts(tree.profiles, rolledUpAt: ran, now: late,
                                            calendar: Self.utc)
        #expect(after.map { $0.1.lastPathComponent } == ["new.jsonl"])
    }
}
