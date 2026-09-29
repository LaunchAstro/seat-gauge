import Foundation
import Testing

import SeatGaugeCore
import SeatGaugeTestSupport

/// The fetchers run through `ScriptedRunner`, fixture recording, and what
/// fails closed.
@Suite struct RunnerTests {

    // MARK: - Reading the fixtures under test

    /// The checkout this file was compiled from, so a run inside a worktree
    /// reads that worktree and not whatever is checked out beside it.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SeatGaugeCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // the repository

    /// A fixture transcript cut into one batch per `send`, at the lines the
    /// recipe waits for. A `nil` mark is a send the seat does not answer.
    /// Everything left over goes in the last batch.
    static func batches(_ lines: [String], waitingFor marks: [String?]) -> [[String]] {
        var rest = lines[...]
        var cut: [[String]] = []
        for mark in marks {
            guard let mark, let at = rest.firstIndex(where: { $0.contains(mark) }) else {
                cut.append([]); continue
            }
            cut.append(Array(rest[..<rest.index(after: at)]))
            rest = rest[rest.index(after: at)...]
        }
        if !rest.isEmpty { cut[cut.count - 1] += Array(rest) }
        return cut
    }

    static let profile = home.appendingPathComponent("profile", isDirectory: true)
    static let work = Seat(id: SeatID(rawValue: "work"), label: "Work", kind: .claude(profileDir: profile))
    static let codex = Seat(id: SeatID(rawValue: "codex"), label: "Codex", kind: .codex)
    static let primer = URL(fileURLWithPath: "/tmp/seat-gauge-primer")
    /// An invented home that holds no login, so a scripted fetch never reads a real one.
    static let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("seat-gauge-runner-home-\(UUID().uuidString)")
    static let authFile = home.appendingPathComponent(".codex/auth.json")

    static func windows(_ state: SeatState) -> [Window] {
        guard case let .live(reading) = state else { return [] }
        return reading.windows
    }

    // MARK: - Scripted fetches

    @Test("ScriptedRunner answers each send from fixture lines, so no CLI is spawned")
    func scriptedRunnerAnswersEachSend() async throws {
        // Claude, own login: the recipe waits at the initialize reply and at
        // the matching control_response, and asks for no turn.
        let claudeRunner = ScriptedRunner(replies: Self.batches(
            try Fixture.lines("own"),
            waitingFor: ["\"request_id\": \"1\"", "\"request_id\":\"2\""]))
        let claude = await ClaudeFetcher(runner: claudeRunner, primer: Self.primer)
            .fetch(Self.work, now: .now, last: nil)
        #expect(Self.windows(claude.state).map(\.kind) == [.fiveHour, .weekly, .fable])

        let claudeSpec = try #require(claudeRunner.launched.first)
        #expect(claudeRunner.launched.count == 1)
        #expect(claudeSpec.arguments.first == "claude")
        #expect(claudeSpec.arguments.contains("--input-format"))
        #expect(claudeSpec.arguments.contains("stream-json"))
        #expect(!claudeSpec.arguments.contains("--max-turns"))
        #expect(!claudeSpec.arguments.contains("haiku"))
        #expect(claudeSpec.currentDirectory == Self.primer)
        #expect(claudeSpec.environment["CLAUDE_CONFIG_DIR"] == Self.profile.path)
        #expect(claudeRunner.sent.count == 2)
        #expect(claudeRunner.sent[0].contains("\"subtype\":\"initialize\""))
        #expect(claudeRunner.sent[1].contains("\"subtype\":\"get_usage\""))
        #expect(claudeRunner.sent[1].contains("\"request_id\":\"2\""))
        #expect(!claudeRunner.sent.contains { $0.contains("\"type\":\"user\"") })

        // Claude, token seat: one Haiku turn, then the usage request, so the
        // transcript cuts in three.
        try FileManager.default.createDirectory(at: Self.home, withIntermediateDirectories: true)
        let tokenFile = Self.home.appendingPathComponent("work.token")
        try Data("not-a-real-token".utf8).write(to: tokenFile)
        let tokenSeat = Seat(id: Self.work.id, label: "Work", kind: Self.work.kind, tokenFile: tokenFile)
        let tokenRunner = ScriptedRunner(replies: Self.batches(
            try Fixture.lines("work"),
            waitingFor: ["\"request_id\": \"1\"", "\"type\":\"result\"", "\"request_id\":\"2\""]))
        let token = await ClaudeFetcher(runner: tokenRunner, primer: Self.primer)
            .fetch(tokenSeat, now: .now, last: nil)
        #expect(!Self.windows(token.state).isEmpty)
        let tokenSpec = try #require(tokenRunner.launched.first)
        #expect(tokenSpec.arguments.contains("--max-turns"))
        #expect(tokenSpec.arguments.contains("haiku"))
        #expect(tokenRunner.sent.count == 3)
        #expect(tokenRunner.sent[1].contains("\"type\":\"user\""))
        #expect(tokenRunner.sent[2].contains("\"subtype\":\"get_usage\""))

        // Codex: the recipe waits once, at the id 2 reply.
        let codexRunner = ScriptedRunner(replies: Self.batches(
            try Fixture.lines("codex"), waitingFor: ["\"id\":1", nil, "\"id\":2"]))
        let codex = await CodexFetcher(runner: codexRunner, authFile: Self.authFile)
            .fetch(Self.codex, now: .now, last: nil)
        #expect(Self.windows(codex.state).map(\.kind) == [.weekly])
        #expect(Self.windows(codex.state).first?.usedPercent == 90)

        let codexSpec = try #require(codexRunner.launched.first)
        #expect(codexRunner.launched.count == 1)
        #expect(codexSpec.arguments == ["codex", "app-server"])
        #expect(codexRunner.sent.count == 3)
        #expect(codexRunner.sent[0].contains("\"method\":\"initialize\""))
        #expect(codexRunner.sent[0].contains("clientInfo"))
        #expect(codexRunner.sent[1].contains("\"method\":\"initialized\""))
        #expect(codexRunner.sent[2].contains("account/rateLimits/read"))
        #expect(codexRunner.sent[2].contains("\"excludeResetCreditDetails\":true"))
        // Stdin stays open until the id 2 reply has arrived.
        #expect(codexRunner.closedInputAfter == 3)
    }

    // MARK: - Recording a fixture

    @Test("record writes redacted stdout lines to Tests/Fixtures/<seat>-<date>.jsonl")
    func recordWritesRedactedLines() throws {
        // The address and the home path the redactor must take out are put
        // together at run time, so this file carries neither for the privacy
        // check to find.
        let address = ["someone", "example.org"].joined(separator: "@")
        let users = "/" + "Users"
        let raw = [
            "{\"accountId\":\"6f1b2d0e-1111-2222-3333-444455556666\",\"email\":\"\(address)\"}",
            "{\"session_id\":\"9a7c4e21-aaaa-bbbb-cccc-ddddeeeeffff\",\"cwd\":\"\(users)/someone/code\"}",
            "{\"access_token\":\"sk-seat-aaaa\",\"refresh_token\":\"sk-seat-bbbb\"}",
        ]
        let clean = raw.map(FixtureRecording.redact)
        #expect(clean[0].contains("\"accountId\":\"\""))
        #expect(clean[1].contains("00000000-0000-0000-0000-000000000000"))
        #expect(clean[1].contains("/home/seat/code"))
        #expect(clean[2].contains("\"access_token\":\"\""))
        #expect(clean[2].contains("\"refresh_token\":\"\""))

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-record-\(UUID().uuidString)")
        // Built in the local calendar, since the name is the local day, so the
        // case reads the same wherever the Mac is set.
        let day = Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: 22, hour: 12))!
        let written = try FixtureRecording.write(clean, seat: SeatID(rawValue: "codex"),
                                                 date: day, into: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(written.lastPathComponent == "codex-2026-09-22.jsonl")
        #expect(written.deletingLastPathComponent().lastPathComponent
                == directory.lastPathComponent)
        // No address, key or token value in the file that was written.
        let text = try String(contentsOf: written, encoding: .utf8)
        #expect(!text.contains("@"))
        #expect(!text.contains("sk-"))
        #expect(text.range(of: "\"(access_token|refresh_token)\":\"[^\"]",
                           options: .regularExpression) == nil)
        #expect(text.split(separator: "\n").count == 3)
    }

    // MARK: - Fails closed

    @Test("Fails closed: a parse failure, a missing CLI and a timeout all read unreadable")
    func failsClosed() async throws {
        let last = Reading(seat: Self.work.id,
                           windows: [Window(kind: .fiveHour, usedPercent: 12,
                                            resetsAt: Date(timeIntervalSince1970: 1_790_000_000),
                                            length: .seconds(5 * 60 * 60))],
                           takenAt: Date(timeIntervalSince1970: 1_789_990_000), plan: "max")

        // A capture no parser can read. The reason is the parser's own.
        let noise = ScriptedRunner(replies: [["not json at all"], ["{\"type\":\"result\"}", "{}"]],
                                   endsWithScript: true)
        let unread = await ClaudeFetcher(runner: noise, primer: Self.primer)
            .fetch(Self.work, now: .now, last: last)
        guard case let .unreadable(reason, carried) = unread.state else {
            Issue.record("a capture no parser can read must be unreadable"); return
        }
        #expect(reason.contains("control_response"))
        #expect(carried == last)

        // A CLI that is not there at all. The reason is the runner's own.
        let absent = ScriptedRunner(launchFailure: "claude is not on PATH")
        let missing = await ClaudeFetcher(runner: absent, primer: Self.primer)
            .fetch(Self.work, now: .now, last: last)
        guard case let .unreadable(why, stillThere) = missing.state else {
            Issue.record("a CLI that will not launch must be unreadable"); return
        }
        #expect(why.contains("not on PATH"))
        #expect(stillThere == last)

        // A seat that answers nothing before its timeout runs out.
        let silent = ScriptedRunner(replies: [])
        let late = await CodexFetcher(runner: silent, timeout: .milliseconds(120), authFile: Self.authFile)
            .fetch(Self.codex, now: .now, last: nil)
        guard case let .unreadable(timedOut, nothing) = late.state else {
            Issue.record("a fetch past the timeout must be unreadable"); return
        }
        #expect(timedOut.contains("timed out"))
        #expect(nothing == nil)
        // Never a fabricated zero: an unreadable seat carries no windows.
        #expect(Self.windows(late.state).isEmpty)
    }
}
