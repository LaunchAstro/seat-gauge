import Foundation
import Testing

@testable import SeatGaugeCore

/// The first roll-up at or after a cell's seal instant must not empty it.
///
/// The walk passes a transcript by once every cell it can feed has sealed. A
/// merge that decided sealed-ness from the flag the CSV was last written with
/// would, for exactly that one run, read the clock differently from the walk. A file that
/// ended inside the cell's own hour is already skipped, a file that ran on past
/// the hour is still walked and carries its own share of it, and the stored row
/// still says `sealed=false` because no run has recomputed the flag yet, so the
/// walked file's share would replace the cell and close it. A subagent transcript
/// ending inside its hour while its parent writes on past it is the ordinary
/// shape of that pair, not a corner of it.
@Suite struct SpendSealCrossingTests {

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

    /// A profile tree of one session, each transcript carrying the mtime the
    /// case names, since the walk reads the file's last write and not the
    /// clock the case was run on.
    struct Tree {
        let directory: URL
        let profiles: [SpendProfile]
        let rollup: SpendCoordinator

        init() throws {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("seat-gauge-seal-\(UUID().uuidString)", isDirectory: true)
            let session = directory.appendingPathComponent(".claude/projects/repo/session",
                                                           isDirectory: true)
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            profiles = [SpendProfile(seat: "default",
                                     projects: directory.appendingPathComponent(".claude/projects",
                                                                                isDirectory: true))]
            rollup = SpendCoordinator(csv: directory.appendingPathComponent("spend.csv"),
                                 state: directory.appendingPathComponent("state.json"),
                                 primer: directory.appendingPathComponent("primer", isDirectory: true),
                                 codex: nil, calendar: SpendSealCrossingTests.utc,
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

        /// What the file holds, which is what a later run has to live with.
        func onDisk(hour: String) -> SpendRow? {
            SpendCSV.read(directory.appendingPathComponent("spend.csv"))
                .first { $0.seat == "default" && $0.day == "2026-09-22" && $0.hour == hour
                    && $0.model == "claude-opus-5" }
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    /// The seal crossing, end to end. `a.jsonl` ends at 10:26 inside the 10:00
    /// cell; `b.jsonl` is still writing at 11:30 and carries a 10:15 response
    /// of its own. The 10:00 cell of the 22nd seals at 11:00 on the 24th: one
    /// run before that instant, one run five minutes after it, and the cell
    /// has to close holding both files.
    @Test func theRunThatSealsACellKeepsTheFilesItStoppedWalking() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try tree.write("a.jsonl", Self.line(request: "req-a", id: "msg-a",
                                            at: "2026-09-22T10:05:00Z", input: 100, output: 10),
                       lastWrite: Self.date("2026-09-22T10:26:00Z"))
        try tree.write("b.jsonl", Self.line(request: "req-b", id: "msg-b",
                                            at: "2026-09-22T10:15:00Z", input: 200, output: 20)
            + Self.line(request: "req-c", id: "msg-c",
                        at: "2026-09-22T11:30:00Z", input: 400, output: 40),
                       lastWrite: Self.date("2026-09-22T11:30:00Z"))

        let first = try await tree.run(now: Self.date("2026-09-22T12:00:00Z"))
        #expect(first.files == 2)
        #expect(tree.onDisk(hour: "10")?.responses == 2)
        #expect(tree.onDisk(hour: "10")?.input == 300)
        #expect(tree.onDisk(hour: "10")?.sealed == false)

        // 11:05 on the 24th. `a.jsonl` last wrote in the 10:00 hour, which has
        // just sealed, so the walk passes it by; `b.jsonl` last wrote in the
        // 11:00 hour, which does not seal until noon, so it is walked and
        // offers the 10:00 cell its 200 input alone.
        let second = try await tree.run(now: Self.date("2026-09-24T11:05:00Z"))
        #expect(second.files == 1)

        let sealed = try #require(tree.onDisk(hour: "10"))
        #expect(sealed.responses == 2)
        #expect(sealed.input == 300)
        #expect(sealed.sealed == true)

        // The hour that is still open is still the walk's to replace.
        #expect(tree.onDisk(hour: "11")?.responses == 1)
        #expect(tree.onDisk(hour: "11")?.input == 400)
        #expect(tree.onDisk(hour: "11")?.sealed == false)
    }

    /// The refusal is about a cell the CSV already holds. A cell it does not
    /// hold takes the fresh row however long ago its hour sealed, because the
    /// first run is the walk that reads all 28 days and there is no history
    /// yet for a partial walk to damage. Refusing on the clock alone would
    /// leave that run writing the last 48 h and nothing else.
    @Test func aFirstRunKeepsCellsWhoseHourSealedLongAgo() async throws {
        let tree = try Tree()
        defer { tree.remove() }
        try tree.write("old.jsonl", Self.line(request: "req-a", id: "msg-a",
                                              at: "2026-09-22T10:05:00Z", input: 100, output: 10),
                       lastWrite: Self.date("2026-09-22T10:05:00Z"))

        let only = try await tree.run(now: Self.date("2026-09-30T09:00:00Z"))
        #expect(only.files == 1)
        let row = try #require(tree.onDisk(hour: "10"))
        #expect(row.responses == 1)
        #expect(row.input == 100)
        #expect(row.sealed == true)
    }

    /// The disagreement itself, one layer down: a stored row flagged `false`
    /// whose hour the clock says is closed. The flag is what the last run
    /// wrote; the clock is what the walk is skipping on now.
    @Test func mergeRefusesACellTheClockHasClosedWhateverTheFlagSays() {
        let stored = SpendRow(seat: "default", day: "2026-09-22", hour: "10",
                              model: "claude-opus-5",
                              counts: TokenCounts(responses: 2, input: 300, output: 30),
                              usd: nil, sealed: false)
        let fresh = SpendRow(seat: "default", day: "2026-09-22", hour: "10",
                             model: "claude-opus-5",
                             counts: TokenCounts(responses: 1, input: 200, output: 20),
                             usd: nil, sealed: false)

        let open = SpendCSV.merge([stored], with: [fresh],
                                  now: Self.date("2026-09-24T10:59:00Z"), calendar: Self.utc)
        #expect(open.first?.input == 200)
        #expect(open.first?.sealed == false)

        let closed = SpendCSV.merge([stored], with: [fresh],
                                    now: Self.date("2026-09-24T11:00:00Z"), calendar: Self.utc)
        #expect(closed.first?.responses == 2)
        #expect(closed.first?.input == 300)
        #expect(closed.first?.sealed == true)
    }
}
