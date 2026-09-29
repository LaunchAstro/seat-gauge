import Foundation
import Testing

@testable import SeatGaugeCore

/// The gap in roll-ups, which is just the app not running: a crash, a quit, a
/// machine asleep from Friday to Monday. The roll-up runs at launch and every
/// sixth poll, so the run after a gap is the one that has to recover it.
///
/// The walk narrowed to files whose cells are still open, and on a returning
/// run that is not enough. A transcript the last roll-up never saw can have
/// sealed while the app was down, and then it is passed by with its tokens
/// never counted: the cell it fed closes one feeder short, and one run later,
/// once every feeder has sealed, the cell is not written at all. The fix is to
/// conjoin the two tests rather than swap one for the other, so a file written
/// since the last roll-up is always walked however old its cells are.
@Suite struct SpendRollupGapTests {

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

    static func line(request: String, id: String, at: String, input: Int, output: Int) -> String {
        "{\"type\":\"assistant\",\"requestId\":\"\(request)\",\"timestamp\":\"\(at)\","
            + "\"message\":{\"id\":\"\(id)\",\"model\":\"claude-opus-5\","
            + "\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output)}}}\n"
    }

    /// A profile tree whose transcripts carry the mtime the case names, since
    /// the walk reads a file's last write and not the clock it was run on.
    struct Tree {
        let directory: URL
        let profiles: [SpendProfile]
        let rollup: SpendCoordinator

        init() throws {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("seat-gauge-gap-\(UUID().uuidString)", isDirectory: true)
            let session = directory.appendingPathComponent(".claude/projects/repo/session",
                                                           isDirectory: true)
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            profiles = [SpendProfile(seat: "default",
                                     projects: directory.appendingPathComponent(".claude/projects",
                                                                                isDirectory: true))]
            rollup = SpendCoordinator(csv: directory.appendingPathComponent("spend.csv"),
                                 state: directory.appendingPathComponent("state.json"),
                                 primer: directory.appendingPathComponent("primer", isDirectory: true),
                                 codex: nil, calendar: SpendRollupGapTests.utc,
                                 log: { _ in })
        }

        func write(_ name: String, _ text: String, lastWrite: Date) throws {
            let file = directory.appendingPathComponent(".claude/projects/repo/session/\(name)")
            try Data(text.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: lastWrite],
                                                  ofItemAtPath: file.path)
        }

        func run(now: Date) async throws -> SpendRun {
            try #require(await rollup.run(profiles: profiles, rates: .bundled, now: now))
        }

        /// What the file holds, which is what any later run has to live with.
        func onDisk(hour: String) -> SpendRow? {
            SpendCSV.read(directory.appendingPathComponent("spend.csv"))
                .first { $0.seat == "default" && $0.day == "2026-09-22" && $0.hour == hour
                    && $0.model == "claude-opus-5" }
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    /// One roll-up on an unrelated transcript at 09:30 on the 22nd, which sets
    /// `rolledUpAt` and leaves the 10:00 cell out of the CSV. Then the two
    /// transcripts that feed it: `a.jsonl` ends at 10:26 inside the hour,
    /// `b.jsonl` writes on to 11:30 and carries a 10:15 response of its own.
    /// Neither is seen again until the app comes back, and both were written
    /// after that roll-up, so both belong in the walk however old their cells.
    static func treeAfterAGap() async throws -> Tree {
        let tree = try Tree()
        try tree.write("unrelated.jsonl", line(request: "req-z", id: "msg-z",
                                               at: "2026-09-21T08:00:00Z", input: 50, output: 5),
                       lastWrite: date("2026-09-22T09:20:00Z"))
        _ = try await tree.run(now: date("2026-09-22T09:30:00Z"))
        #expect(tree.onDisk(hour: "10") == nil)

        try tree.write("a.jsonl", line(request: "req-a", id: "msg-a",
                                       at: "2026-09-22T10:05:00Z", input: 100, output: 10),
                       lastWrite: date("2026-09-22T10:26:00Z"))
        try tree.write("b.jsonl", line(request: "req-b", id: "msg-b",
                                       at: "2026-09-22T10:15:00Z", input: 200, output: 20)
            + line(request: "req-c", id: "msg-c",
                   at: "2026-09-22T11:30:00Z", input: 400, output: 40),
                       lastWrite: date("2026-09-22T11:30:00Z"))
        return tree
    }

    /// The app is back at 11:05 on the 24th, five minutes after the 10:00 cell
    /// of the 22nd sealed. `a.jsonl` last wrote inside that hour, so the
    /// sealing test alone would pass it by, and with no stored row to fall back
    /// on the cell would close on `b.jsonl`'s 200 input alone.
    @Test func aReturningRunClosesTheCellOnEveryTranscriptThatFedIt() async throws {
        let tree = try await Self.treeAfterAGap()
        defer { tree.remove() }

        let back = try await tree.run(now: Self.date("2026-09-24T11:05:00Z"))
        #expect(back.files == 2)

        let sealed = try #require(tree.onDisk(hour: "10"))
        #expect(sealed.responses == 2)
        #expect(sealed.input == 300)
        #expect(sealed.sealed == true)
    }

    /// The same gap one run later, at 13:00 on the 24th, by which time the
    /// 11:00 cell has sealed too and the sealing test alone would pass both
    /// files by. There is no stored row for either hour, so the session is not
    /// written one feeder short, it is not written at all.
    @Test func aRunAfterEveryFeederSealedStillWritesTheCell() async throws {
        let tree = try await Self.treeAfterAGap()
        defer { tree.remove() }

        let back = try await tree.run(now: Self.date("2026-09-24T13:00:00Z"))
        #expect(back.files == 2)

        let sealed = try #require(tree.onDisk(hour: "10"))
        #expect(sealed.responses == 2)
        #expect(sealed.input == 300)
        #expect(sealed.sealed == true)

        let later = try #require(tree.onDisk(hour: "11"))
        #expect(later.responses == 1)
        #expect(later.input == 400)
        #expect(later.sealed == true)
    }
}
