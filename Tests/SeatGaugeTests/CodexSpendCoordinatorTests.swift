import Foundation
import Testing

import SeatGaugeCore
import SeatGaugeTestSupport

/// Codex spend collected beside Claude's by one coordinator. Codex rollouts are written by hand with made-up session ids; the Claude
/// rows come from the committed fixture tree.
@Suite struct CodexSpendCoordinatorTests {

    // MARK: - Fixtures

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SeatGaugeTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // the repository

    static var claudeProfiles: [SpendProfile] {
        let fixtures = root.appendingPathComponent("Tests/Fixtures/spend", isDirectory: true)
        return [SpendProfile(seat: "default", projects: fixtures.appendingPathComponent("default/projects")),
                SpendProfile(seat: "team", projects: fixtures.appendingPathComponent("team/projects"))]
    }

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

    static func usage(_ input: Int, _ output: Int) -> [String: Int] {
        ["input_tokens": input, "cached_input_tokens": 0, "cache_write_input_tokens": 0,
         "output_tokens": output, "reasoning_output_tokens": 0, "total_tokens": input + output]
    }

    static func line(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func meta(_ id: String, at: String, cwd: String = "/work/project") -> String {
        line(["timestamp": at, "type": "session_meta",
              "payload": ["id": id, "session_id": id, "timestamp": at, "cwd": cwd, "source": "cli"]])
    }

    static func context(_ model: String, at: String) -> String {
        line(["timestamp": at, "type": "turn_context", "payload": ["model": model, "cwd": "/work/project"]])
    }

    static func tokens(at: String, total: [String: Int], last: [String: Int]) -> String {
        line(["timestamp": at, "type": "event_msg",
              "payload": ["type": "token_count",
                          "info": ["total_token_usage": total, "last_token_usage": last]]])
    }

    /// A scratch record, state, lock and sessions directory, removed at the end.
    final class Scratch {
        let directory: URL
        var csv: URL { directory.appendingPathComponent("spend.csv") }
        var state: URL { directory.appendingPathComponent("state.json") }
        var lock: URL { directory.appendingPathComponent("spend.csv.lock") }
        var sessions: URL { directory.appendingPathComponent("sessions", isDirectory: true) }
        var support: URL { directory.appendingPathComponent("Application Support", isDirectory: true) }
        var codexPrimer: URL { support.appendingPathComponent("\(AppPaths.bundleID)/codex-primer") }

        init() throws {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("seat-gauge-coordinator-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        @discardableResult
        func rollout(_ path: String, _ lines: [String]) throws -> URL {
            let url = sessions.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
            return url
        }

        func append(_ url: URL, _ lines: [String]) throws {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
            try handle.close()
        }

        func touch(_ url: URL, _ at: String) throws {
            try FileManager.default.setAttributes([.modificationDate: CodexSpendCoordinatorTests.date(at)],
                                                  ofItemAtPath: url.path)
        }

        /// The Claude primer, inside the case's own directory, so no home path
        /// enters a fixture.
        var claudePrimer: URL { support.appendingPathComponent("\(AppPaths.bundleID)/primer") }

        var collector: CodexCollector { CodexCollector(sessions: sessions, primer: codexPrimer) }

        func coordinator(codex: CodexCollector?, lockTimeout: Duration = .seconds(10)) -> SpendCoordinator {
            SpendCoordinator(csv: csv, state: state, primer: claudePrimer,
                             codex: codex, calendar: CodexSpendCoordinatorTests.utc,
                             lockTimeout: lockTimeout, log: { _ in })
        }

        /// The record's rows as fields, read without the app's own reader.
        func records() throws -> [[String]] {
            let text = try String(contentsOf: csv, encoding: .utf8)
            return text.split(separator: "\n").dropFirst()
                .map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        }

        func seats() throws -> Set<String> { Set(try records().map { $0[0] }) }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    static let now = date("2026-09-22T08:00:00Z")

    /// One small session: 1,000 in and 100 out at 10:00 on 20 Sep.
    static func oneSession(_ scratch: Scratch, id: String = "session-one",
                             path: String = "2026/09/20/rollout-one.jsonl") throws {
        try scratch.rollout(path, [
            meta(id, at: "2026-09-20T10:00:00Z"),
            context("gpt-6-sol", at: "2026-09-20T10:00:01Z"),
            tokens(at: "2026-09-20T10:01:00Z", total: usage(1000, 100), last: usage(1000, 100)),
        ])
    }

    // MARK: - Cases

    @Test func codexCellsLandBesideClaudeRows() async throws {
        let scratch = try Scratch()
        try Self.oneSession(scratch)
        try scratch.rollout("2026/09/21/rollout-second.jsonl", [
            Self.meta("session-second", at: "2026-09-21T09:00:00Z"),
            Self.context("gpt-5.5", at: "2026-09-21T09:00:01Z"),
            Self.tokens(at: "2026-09-21T09:30:00Z", total: Self.usage(200, 20), last: Self.usage(200, 20)),
        ])
        let run = try await scratch.coordinator(codex: scratch.collector)
            .run(profiles: Self.claudeProfiles, rates: .bundled, now: Self.now)
        #expect(run != nil)
        #expect(try scratch.seats() == ["default", "team", "codex"])
        let codex = try scratch.records().filter { $0[0] == "codex" }
        #expect(codex.map { Array($0[1 ... 6]) } == [
            ["2026-09-20", "10", "gpt-6-sol", "1", "1000", "100"],
            ["2026-09-21", "09", "gpt-5.5", "1", "200", "20"],
        ])
        #expect(codex.allSatisfy { $0[11].isEmpty })
    }

    @Test func sessionsSealAndAreReadWholeOrNotAtAll() async throws {
        let scratch = try Scratch()
        let opened = Self.usage(1000, 100)
        let first = try scratch.rollout("2026/09/20/rollout-a1.jsonl", [
            Self.meta("session-a", at: "2026-09-20T10:00:00Z"),
            Self.context("model-a", at: "2026-09-20T10:00:01Z"),
            Self.tokens(at: "2026-09-20T10:01:00Z", total: opened, last: opened),
        ])
        // The resume opens by repeating the total it left off at.
        let resumed = try scratch.rollout("2026/09/23/rollout-a2.jsonl", [
            Self.meta("session-a", at: "2026-09-23T11:00:00Z"),
            Self.context("model-a", at: "2026-09-23T11:00:01Z"),
            Self.tokens(at: "2026-09-23T11:01:00Z", total: opened, last: opened),
            Self.tokens(at: "2026-09-23T11:02:00Z", total: Self.usage(1600, 160), last: Self.usage(600, 60)),
        ])
        let quiet = try scratch.rollout("2026/09/20/rollout-b.jsonl", [
            Self.meta("session-b", at: "2026-09-20T10:30:00Z"),
            Self.context("model-b", at: "2026-09-20T10:30:01Z"),
            Self.tokens(at: "2026-09-20T10:31:00Z", total: Self.usage(50, 5), last: Self.usage(50, 5)),
        ])
        try scratch.touch(first, "2026-09-20T12:00:00Z")
        try scratch.touch(quiet, "2026-09-20T12:00:00Z")
        try scratch.touch(resumed, "2026-09-23T12:00:00Z")
        let coordinator = scratch.coordinator(codex: scratch.collector)
        let once = try await coordinator.run(profiles: [], rates: .bundled, now: Self.date("2026-09-23T13:00:00Z"))
        #expect(once?.files == 3)

        try scratch.append(resumed, [
            Self.tokens(at: "2026-09-23T14:00:00Z", total: Self.usage(1900, 190), last: Self.usage(300, 30)),
        ])
        try scratch.touch(resumed, "2026-09-23T14:30:00Z")
        let twice = try await coordinator.run(profiles: [], rates: .bundled, now: Self.date("2026-09-23T15:00:00Z"))
        #expect(twice?.files == 2)
        #expect(try scratch.records().map { [$0[1], $0[2], $0[3], $0[5], $0[6], $0[12]] } == [
            ["2026-09-20", "10", "model-a", "1000", "100", "true"],
            ["2026-09-20", "10", "model-b", "50", "5", "true"],
            ["2026-09-23", "11", "model-a", "600", "60", "false"],
            ["2026-09-23", "14", "model-a", "300", "30", "false"],
        ])
    }

    @Test func oneCoordinatorCollectsBoth() async throws {
        let scratch = try Scratch()
        try Self.oneSession(scratch)
        let run = try await scratch.coordinator(codex: scratch.collector)
            .run(profiles: Self.claudeProfiles, rates: .bundled, now: Self.now)
        #expect(run != nil)
        #expect(try scratch.seats() == ["default", "team", "codex"])
    }

    @Test func twoCoordinatorsLoseNoProvidersCells() async throws {
        for _ in 0 ..< 5 {
            let scratch = try Scratch()
            try Self.oneSession(scratch)
            let claude = scratch.coordinator(codex: nil)
            let codex = scratch.coordinator(codex: scratch.collector)
            async let one = claude.run(profiles: Self.claudeProfiles, rates: .bundled, now: Self.now)
            async let two = codex.run(profiles: [], rates: .bundled, now: Self.now)
            let (a, b) = try await (one, two)
            #expect(a != nil && b != nil)
            #expect(try scratch.seats() == ["default", "team", "codex"])
        }
    }

    @Test func busyLockSkipsTheRunAndTouchesNothing() async throws {
        let scratch = try Scratch()
        try Self.oneSession(scratch)
        try Data((SpendCSV.header + "\nkept,2026-09-01,00,m,1,1,1,0,0,0,0,,true\n").utf8).write(to: scratch.csv)
        try Data(#"{"timeZone":"UTC"}"#.utf8).write(to: scratch.state)
        let csvBefore = try Data(contentsOf: scratch.csv)
        let stateBefore = try Data(contentsOf: scratch.state)

        let held = open(scratch.lock.path, O_CREAT | O_RDWR, 0o644)
        #expect(held >= 0)
        #expect(flock(held, LOCK_EX) == 0)
        let skipped = try await scratch.coordinator(codex: scratch.collector, lockTimeout: .milliseconds(300))
            .run(profiles: Self.claudeProfiles, rates: .bundled, now: Self.now)
        #expect(skipped == nil)
        #expect(try Data(contentsOf: scratch.csv) == csvBefore)
        #expect(try Data(contentsOf: scratch.state) == stateBefore)

        flock(held, LOCK_UN)
        close(held)
        let ran = try await scratch.coordinator(codex: scratch.collector, lockTimeout: .milliseconds(300))
            .run(profiles: Self.claudeProfiles, rates: .bundled, now: Self.now)
        #expect(ran != nil)
        #expect(try scratch.seats() == ["kept", "default", "team", "codex"])
    }

    @Test func codexPollsRunInTheirOwnPrimer() async throws {
        let primer = AppPaths.codexPrimer
        #expect(primer.lastPathComponent == "codex-primer")
        #expect(primer.deletingLastPathComponent().standardizedFileURL
            == AppPaths.primer.deletingLastPathComponent().standardizedFileURL)
        let runner = ScriptedRunner()
        let scratch = try Scratch()
        _ = await CodexFetcher(runner: runner, timeout: .milliseconds(200),
                               authFile: scratch.directory.appendingPathComponent("auth.json"))
            .fetch(Seat(id: SeatID(rawValue: "codex"), label: "Codex", kind: .codex), now: Self.now, last: nil)
        #expect(runner.launched.first?.currentDirectory?.standardizedFileURL == primer.standardizedFileURL)
        var directory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: primer.path, isDirectory: &directory) && directory.boolValue)
    }

    @Test func aGaugePollAddsZeroSpend() async throws {
        let scratch = try Scratch()
        try Self.oneSession(scratch)
        let coordinator = scratch.coordinator(codex: scratch.collector)
        _ = try await coordinator.run(profiles: [], rates: .bundled, now: Self.now)
        let before = try Data(contentsOf: scratch.csv)

        let otherBuild = scratch.support.appendingPathComponent("\(AppPaths.bundleID).dev/codex-primer")
        for (name, cwd) in [("rollout-poll.jsonl", scratch.codexPrimer), ("rollout-dev-poll.jsonl", otherBuild)] {
            try scratch.rollout("2026/09/20/\(name)", [
                Self.meta("session-\(name)", at: "2026-09-20T10:05:00Z", cwd: cwd.path),
                Self.context("gpt-6-sol", at: "2026-09-20T10:05:01Z"),
                Self.tokens(at: "2026-09-20T10:06:00Z", total: Self.usage(4000, 400), last: Self.usage(4000, 400)),
            ])
        }
        _ = try await coordinator.run(profiles: [], rates: .bundled, now: Self.now)
        #expect(try Data(contentsOf: scratch.csv) == before)
    }

    @Test func familyIsReadFromTheModelName() {
        let cases: [(String, ModelFamily)] = [
            ("claude-opus-5", .opus), ("claude-fable-5", .fable), ("claude-fable-5-1", .fable),
            ("claude-sonnet-5", .sonnet), ("gpt-6-sol", .sol), ("GPT-5.6-SOL", .sol),
            ("gpt-5.5", .other), ("claude-haiku-4-5-20251001", .other), ("unknown", .other),
            ("opus-sonnet-sol", .opus), ("sonnet-fable", .fable),
        ]
        for (model, family) in cases { #expect(ModelFamily(model: model) == family, "\(model)") }
        #expect(ModelFamily.allCases.map(\.rawValue) == ["Opus", "Fable", "Sonnet", "Sol", "other"])
    }

    @Test func priceStatusComesOnlyFromTheRateTable() {
        let table = RateCard.bundled
        #expect(table.version == "2026-09")
        for model in ["gpt-6-sol", "gpt-5.6-sol", "gpt-5.5", "unknown"] {
            #expect(table.priceStatus(for: model) == .unpriced, "\(model)")
            #expect(table.usd(model: model, counts: TokenCounts(responses: 1, input: 10)) == nil)
        }
        #expect(ModelFamily(model: "gpt-6-sol") == .sol)
        #expect(table.priceStatus(for: "claude-opus-5") == .priced)
        #expect(table.priceStatus(for: "claude-haiku-4-5-20251001") == .priced)
        #expect(ModelFamily(model: "claude-haiku-4-5-20251001") == .other)
        let solPriced = RateCard(version: "test", models: ["gpt-6-sol": Rate(input: 1, output: 2, group: "Sol")])
        #expect(solPriced.priceStatus(for: "gpt-6-sol") == .priced)
        #expect(solPriced.priceStatus(for: "gpt-5.6-sol") == .unpriced)
    }

    @Test func failsClosedWithoutSessionsOrAMeta() async throws {
        let bare = try Scratch()
        let alone = try await bare.coordinator(codex: nil)
            .run(profiles: Self.claudeProfiles, rates: .bundled, now: Self.now)

        let missing = try Scratch()
        let run = try await missing.coordinator(codex: missing.collector)
            .run(profiles: Self.claudeProfiles, rates: .bundled, now: Self.now)
        #expect(run != nil)
        #expect(try missing.seats() == ["default", "team"])

        let unkeyed = try Scratch()
        try unkeyed.rollout("2026/09/20/rollout-unkeyed.jsonl", [
            Self.context("gpt-6-sol", at: "2026-09-20T10:00:01Z"),
            Self.tokens(at: "2026-09-20T10:01:00Z", total: Self.usage(900, 90), last: Self.usage(900, 90)),
        ])
        let counted = try await unkeyed.coordinator(codex: unkeyed.collector)
            .run(profiles: Self.claudeProfiles, rates: .bundled, now: Self.now)
        #expect(try unkeyed.seats() == ["default", "team"])
        #expect(counted?.skipped == (alone?.skipped ?? -1) + 1)
    }
}
