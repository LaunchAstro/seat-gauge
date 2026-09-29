import Foundation
import Testing

import SeatGaugeCore

/// The spend roll-up over the fixture tree: the walk, dedupe, buckets, prices,
/// the merge and sealing.
@Suite struct SpendRollupTests {

    // MARK: - The fixture tree

    /// The checkout this file was compiled from, so a run inside a worktree
    /// reads that worktree and not whatever is checked out beside it.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SeatGaugeCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // the repository

    static var fixtures: URL { root.appendingPathComponent("Tests/Fixtures/spend", isDirectory: true) }

    /// The two profile directories the fixture tree carries, named the way a
    /// real home names them.
    static var profiles: [SpendProfile] {
        [SpendProfile(seat: "default", projects: fixtures.appendingPathComponent("default/projects")),
         SpendProfile(seat: "team", projects: fixtures.appendingPathComponent("team/projects"))]
    }

    /// The `cwd` the fixture's primer line carries, which is the directory the
    /// gauge's own Claude calls run in.
    static var primer: URL {
        let line = try! String(contentsOf: fixtures.appendingPathComponent(
            "team/projects/-home-example-Desktop-work/session-b.jsonl"), encoding: .utf8)
            .split(separator: "\n")[0]
        let object = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        return URL(fileURLWithPath: object["cwd"] as! String, isDirectory: true)
    }

    static var namedFile: URL {
        fixtures.appendingPathComponent("default/projects/-home-example-Desktop-work/session-a.jsonl")
    }

    /// Buckets are local, so every case fixes the calendar to UTC and asserts
    /// the days and hours that follow from the fixture's own timestamps.
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

    /// A run of the roll-up against the fixture tree, into a scratch directory
    /// of its own, so no case writes where the app keeps its files.
    struct Scratch {
        let directory: URL
        let rollup: SpendCoordinator
        let lines: Log

        init(now: Date = SpendRollupTests.date("2026-09-22T08:00:00Z")) throws {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("seat-gauge-spend-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            lines = Log()
            let said = lines
            rollup = SpendCoordinator(csv: directory.appendingPathComponent("spend.csv"),
                                 state: directory.appendingPathComponent("state.json"),
                                 primer: SpendRollupTests.primer,
                                 codex: nil, calendar: SpendRollupTests.utc,
                                 log: { said.add($0) })
        }

        func run(now: Date = SpendRollupTests.date("2026-09-22T08:00:00Z"),
                 rates: RateCard = .bundled) async throws -> SpendRun {
            try #require(await rollup.run(profiles: SpendRollupTests.profiles, rates: rates, now: now))
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    /// What the roll-up said while it ran, kept where a case can read it back.
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var said: [String] = []
        func add(_ line: String) { lock.withLock { said.append(line) } }
        var all: [String] { lock.withLock { said } }
    }

    static func row(_ rows: [SpendRow], seat: String, model: String) -> SpendRow? {
        rows.first { $0.seat == seat && $0.model == model }
    }

    @Test("the walk reads both profile trees, subagent files and assistant lines only")
    func walksTheProfileTrees() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let run = try await scratch.run()

        // The subagent file under <session>/subagents/ is walked, and it is the
        // only place the fixture's Fable 5.1 response lives.
        #expect(Self.row(run.rows, seat: "default", model: "claude-fable-5-1") != nil)
        // The second profile directory is walked too.
        #expect(Self.row(run.rows, seat: "team", model: "claude-sonnet-5") != nil)
        // A user line, and an assistant line with no usage, carry no response.
        #expect(run.responses == 5)
        #expect(run.files == 3)
    }

    @Test("responses are deduped on (requestId, message.id) against an independent recount")
    func dedupesOnRequestAndMessage() throws {
        // The rule the check's jq line states, recounted here with the system
        // JSON reader rather than with the roll-up's own parser.
        let text = try String(contentsOf: Self.namedFile, encoding: .utf8)
        var pairs: Set<String> = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  message["usage"] is [String: Any],
                  let model = message["model"] as? String, model != "<synthetic>",
                  let request = object["requestId"] as? String,
                  let id = message["id"] as? String else { continue }
            pairs.insert("\(request) \(id)")
        }

        let reading = ClaudeCollector.read(file: Self.namedFile, primer: Self.primer)
        #expect(reading.responses.count == pairs.count)
        #expect(pairs.count == 3)
    }

    @Test("a synthetic model line and a primer-cwd line are both dropped")
    func dropsSyntheticAndPrimerLines() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let run = try await scratch.run()

        #expect(run.rows.allSatisfy { $0.model != "<synthetic>" })
        // The primer line is the fixture's only Fable 5 response, and it runs
        // in the gauge's own working directory, so nothing of it is kept.
        #expect(Self.row(run.rows, seat: "team", model: "claude-fable-5") == nil)
        #expect(run.rows.filter { $0.seat == "team" }.count == 1)
    }

    @Test("buckets are local seat, day, hour and model with [1m] stripped")
    func bucketsByLocalDayHourAndModel() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let run = try await scratch.run()

        // Two Opus responses in the same UTC hour, one of them written
        // `claude-opus-5[1m]`, are one cell of two responses.
        let opus = try #require(Self.row(run.rows, seat: "default", model: "claude-opus-5"))
        #expect(opus.day == "2026-09-20")
        #expect(opus.hour == "02")
        #expect(opus.responses == 2)
        #expect(opus.input == 3000)
        #expect(opus.output == 500)
        #expect(opus.thinking == 50)
        #expect(opus.cacheRead == 30000)
        #expect(opus.cacheWrite5m == 500)
        #expect(opus.cacheWrite1h == 100)
        #expect(run.rows.allSatisfy { !$0.model.contains("[1m]") })

        // The subagent response is in the following hour and stays its own cell.
        let fable = try #require(Self.row(run.rows, seat: "default", model: "claude-fable-5-1"))
        #expect(fable.hour == "03")
        #expect(run.rows.map(\.seat).contains("team"))
    }

    @Test("the bundled card is version 2026-09 and derives cache rates from input")
    func pricesFromTheRateCard() throws {
        let card = RateCard.bundled
        #expect(card.version == "2026-09")

        let opus = try #require(card.rate(for: "claude-opus-5"))
        #expect(opus.input == Decimal(5) && opus.output == Decimal(25))
        // No override, so cache read is a tenth of input, the 5-minute write
        // 1.25 times it and the 1-hour write twice it.
        #expect(opus.readCache == Decimal(string: "0.5"))
        #expect(opus.write5m == Decimal(string: "6.25"))
        #expect(opus.write1h == Decimal(10))

        // A million cache-read tokens is the two Fable ids' whole difference:
        // $1.00 against $0.25, priced apart and grouped together.
        let counts = TokenCounts(responses: 1, cacheRead: 1_000_000)
        #expect(card.usd(model: "claude-fable-5", counts: counts) == Decimal(1))
        #expect(card.usd(model: "claude-fable-5-1", counts: counts) == Decimal(string: "0.25"))
        #expect(card.group(for: "claude-fable-5") == "Fable")
        #expect(card.group(for: "claude-fable-5-1") == "Fable")
        #expect(card.group(for: "claude-opus-5") == "Opus")
        #expect(card.group(for: "claude-sonnet-5") == "Sonnet")
        #expect(card.group(for: "claude-haiku-4-5-20251001") == "other")

        // The whole of one fixture cell, priced end to end.
        let cell = TokenCounts(responses: 2, input: 3000, output: 500, thinking: 50,
                               cacheRead: 30000, cacheWrite5m: 500, cacheWrite1h: 100)
        #expect(card.usd(model: "claude-opus-5", counts: cell) == Decimal(string: "0.046625"))
    }

    @Test("a model the card does not carry is unpriced, not zero and not a neighbour")
    func leavesAnUnlistedModelUnpriced() async throws {
        let card = RateCard.bundled
        #expect(card.rate(for: "claude-opus-4-8") == nil)
        #expect(card.usd(model: "claude-opus-4-8", counts: TokenCounts(responses: 1, input: 1_000_000)) == nil)
        #expect(card.group(for: "claude-opus-4-8") == "unpriced")

        let scratch = try Scratch()
        defer { scratch.remove() }
        let run = try await scratch.run()
        let unlisted = try #require(Self.row(run.rows, seat: "default", model: "claude-opus-4-8"))
        #expect(unlisted.usd == nil)
        #expect(unlisted.responses == 1)
        // Blank in the file as well, rather than a zero a reader would total.
        let csv = try String(contentsOf: scratch.directory.appendingPathComponent("spend.csv"),
                            encoding: .utf8)
        #expect(csv.contains("claude-opus-4-8"))
        #expect(csv.split(separator: "\n").contains { $0.contains("claude-opus-4-8") && $0.contains(",,") })
    }

    @Test("the merge replaces unsealed cells, keeps sealed ones and drops nothing")
    func mergesWithoutTouchingSealedCells() throws {
        let now = Self.date("2026-09-22T08:00:00Z")
        let sealed = SpendRow(seat: "default", day: "2026-09-18", hour: "01", model: "claude-opus-5",
                              counts: TokenCounts(responses: 1, input: 10), usd: Decimal(1), sealed: true)
        let unsealed = SpendRow(seat: "default", day: "2026-09-22", hour: "05", model: "claude-opus-5",
                                counts: TokenCounts(responses: 1, input: 20), usd: Decimal(2), sealed: false)
        let untouched = SpendRow(seat: "personal", day: "2026-09-21", hour: "09", model: "claude-sonnet-5",
                                 counts: TokenCounts(responses: 3, input: 30), usd: Decimal(3), sealed: false)

        // The fresh walk reaches both cells the existing file holds, and one
        // it does not: the sealed one keeps its numbers all the same.
        let fresh = [
            SpendRow(seat: "default", day: "2026-09-18", hour: "01", model: "claude-opus-5",
                     counts: TokenCounts(responses: 9, input: 900), usd: Decimal(9), sealed: false),
            SpendRow(seat: "default", day: "2026-09-22", hour: "05", model: "claude-opus-5",
                     counts: TokenCounts(responses: 4, input: 40), usd: Decimal(4), sealed: false),
        ]
        let merged = SpendCSV.merge([sealed, unsealed, untouched], with: fresh, now: now, calendar: Self.utc)

        let kept = try #require(merged.first { $0.day == "2026-09-18" })
        #expect(kept.responses == 1 && kept.input == 10 && kept.sealed)
        let replaced = try #require(merged.first { $0.day == "2026-09-22" })
        #expect(replaced.responses == 4 && replaced.input == 40 && !replaced.sealed)
        // A cell the walk did not reach is still in the file: the roll-up
        // merges and never regenerates.
        let survivor = try #require(merged.first { $0.seat == "personal" })
        #expect(survivor.responses == 3)
        #expect(merged.count == 3)

        // And the same through a real file, header and all.
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-csv-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: file) }
        try SpendCSV.write(merged, to: file)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.hasPrefix(SpendCSV.header + "\n"))
        #expect(SpendCSV.read(file) == merged)
    }

    @Test("a cell seals 48 h after its hour ends, and session costs land in state.json")
    func sealsAfterFortyEightHoursAndRecordsCostState() async throws {
        // The 05:00 hour of the 20th ends at 06:00, so it seals at 06:00 on
        // the 22nd and not a second before.
        #expect(!SpendCSV.sealed(day: "2026-09-20", hour: "05",
                                 now: Self.date("2026-09-22T05:59:59Z"), calendar: Self.utc))
        #expect(SpendCSV.sealed(day: "2026-09-20", hour: "05",
                                now: Self.date("2026-09-22T06:00:00Z"), calendar: Self.utc))

        let scratch = try Scratch()
        defer { scratch.remove() }
        let run = try await scratch.run()
        // The fixture's own cells are all older than 48 h at the run's `now`.
        #expect(run.rows.allSatisfy { $0.sealed })

        let state = StateStore(file: scratch.directory.appendingPathComponent("state.json")).load()
        #expect(state.sessionCosts["session-a"] == 1.5)
        #expect(state.sessionCosts["session-b"] == 0.25)
        #expect(state.rolledUpAt != nil)
        #expect(state.timeZone.isEmpty == false)
    }

    @Test("the roll-up runs at launch and every sixth poll, off the main actor")
    func runsAtLaunchAndEverySixthPoll() async throws {
        #expect(SpendSchedule.everyNthPoll == 6)
        #expect(SpendSchedule.due(poll: 0))
        #expect(!SpendSchedule.due(poll: 1))
        #expect(!SpendSchedule.due(poll: 5))
        #expect(SpendSchedule.due(poll: 6))
        #expect(SpendSchedule.due(poll: 12))

        let runs = Counter()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-poll-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(ConfigLoader.template.utf8).write(to: directory.appendingPathComponent("seats.json"))

        let watcher = try ConfigWatcher(loader: ConfigLoader(file: directory.appendingPathComponent("seats.json")))
        let poller = Poller(
            watcher: watcher,
            service: RefreshService(clock: ContinuousClock(), gap: .zero,
                                    fetcher: { _ in DormantFetcher() }),
            store: GaugeStore(file: directory.appendingPathComponent("readings.json")),
            clock: ContinuousClock(),
            rollup: { await runs.add(main: Self.onMainThread()) },
            log: { _ in })
        for _ in 0 ..< 7 { await poller.poll() }

        #expect(await runs.count == 2)
        #expect(await runs.onMain == 0)
    }

    /// `Thread.isMainThread` is unavailable from an async context, so the
    /// roll-up's own thread is read here, where it is not one.
    nonisolated static func onMainThread() -> Bool { Thread.isMainThread }

    actor Counter {
        private(set) var count = 0
        private(set) var onMain = 0
        func add(main: Bool) { count += 1; if main { onMain += 1 } }
    }

    struct DormantFetcher: SeatFetching {
        func fetch(_ seat: Seat, now: Date, last: Reading?) async -> Fetched {
            Fetched(state: .dormant(reason: "not in this case"), lines: [])
        }
    }

    @Test("Fails closed: an unreadable line is skipped and a missing rates.json falls back")
    func failsClosedOnBadLinesAndAMissingCard() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let run = try await scratch.run()

        // The fixture's truncated line is skipped, said out loud, and the rest
        // of that file is still counted.
        #expect(run.skipped == 1)
        #expect(scratch.lines.all.contains { $0.contains("skipped") })
        #expect(Self.row(run.rows, seat: "team", model: "claude-sonnet-5") != nil)

        // A rates.json that is not there, and one that will not decode, both
        // leave the bundled card in use rather than pricing nothing.
        let missing = scratch.directory.appendingPathComponent("no-such-rates.json")
        #expect(RateCard.load(missing) == RateCard.bundled)
        let broken = scratch.directory.appendingPathComponent("broken-rates.json")
        try Data("{ not json".utf8).write(to: broken)
        #expect(RateCard.load(broken) == RateCard.bundled)

        // And the written card reads back as itself.
        let written = scratch.directory.appendingPathComponent("rates.json")
        try RateCard.bundled.write(to: written)
        #expect(RateCard.load(written) == RateCard.bundled)
    }
}
