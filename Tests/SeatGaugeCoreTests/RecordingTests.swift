import Foundation
import Testing

import SeatGaugeCore
import SeatGaugeTestSupport

/// What `seatgauge-cli record` keeps of a seat's reply, and where it puts it.
/// A recording is a real seat's own usage, so only what the parsers read
/// survives, credentials never do, and the file is the user's alone, outside
/// every tracked folder of the clone.
@Suite struct RecordingTests {
    static func scratch() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-recording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func mode(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test("credential fields go, nested, escaped or in free text, and so does everything the parsers never read")
    func credentialsAndUnreadFieldsGo() {
        let lines = [
            #"{"token":"opaque-secret-a","authorization":"Bearer opaque-secret-b"}"#,
            #"{"type":"result","is_error":true,"result":"failed: {\"token\":\"opaque-secret-c\",\"authorization\":\"Bearer opaque-secret-d\"} and Authorization: Bearer opaque-secret-e, password=opaque-secret-f","nested":{"password":"opaque-secret-g","deeper":[{"api_key":"opaque-secret-h","cookie":"opaque-secret-i"}]},"refresh_token":"opaque-secret-j","access_token":"opaque-secret-k","secret":"opaque-secret-l","client_secret":"opaque-secret-m"}"#,
            #"{"type":"system","subtype":"init","organization":"Invented Widgets Pty Ltd","userId":"invented-user-7","chatgptAccountId":"invented-account-8","skills":["invented-skill"],"agents":["invented-agent"],"slash_commands":["/invented-command"],"mcp_servers":[{"name":"invented-server"}],"model":"claude-haiku-4-5"}"#,
            "Authorization: Bearer opaque-secret-n printed as plain text",
        ]
        let clean = lines.map(FixtureRecording.redact)
        let all = clean.joined(separator: "\n")
        // Compared through Bools, so a failure never prints a planted value.
        let leaked = all.contains("opaque-secret")
        #expect(!leaked)
        for unread in ["Invented Widgets", "invented-user", "invented-account", "invented-skill",
                       "invented-agent", "invented-command", "invented-server"] {
            let kept = all.contains(unread)
            #expect(!kept, "\(unread)")
        }
        // What the parsers read is kept, one line for each line read.
        #expect(clean.count == lines.count)
        #expect(clean[1].contains(#""is_error":true"#))
        #expect(clean[1].contains("failed:"))
        #expect(clean[2].contains(#""subtype":"init""#))
        #expect(clean[2].contains("claude-haiku-4-5"))
    }

    @Test("a redacted transcript still reads to the same windows for every fixture seat")
    func redactedTranscriptsReadTheSame() async throws {
        let profile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("seat-gauge-recording-profile")
        let work = Seat(id: SeatID(rawValue: "work"), label: "Work", kind: .claude(profileDir: profile))
        let primer = URL(fileURLWithPath: "/tmp/seat-gauge-primer")
        for redacted in [false, true] {
            let batches = RunnerTests.batches(try Fixture.lines("own"),
                                              waitingFor: ["\"request_id\": \"1\"", "\"request_id\":\"2\""])
            let runner = ScriptedRunner(replies: redacted ? batches.map { $0.map(FixtureRecording.redact) } : batches)
            let claude = await ClaudeFetcher(runner: runner, primer: primer).fetch(work, now: .now, last: nil)
            #expect(RunnerTests.windows(claude.state).map(\.kind) == [.fiveHour, .weekly, .fable], "redacted: \(redacted)")
            #expect(RunnerTests.windows(claude.state).map(\.usedPercent).count == 3)

            let codexBatches = RunnerTests.batches(try Fixture.lines("codex"), waitingFor: ["\"id\":1", nil, "\"id\":2"])
            let codexRunner = ScriptedRunner(replies: redacted ? codexBatches.map { $0.map(FixtureRecording.redact) } : codexBatches)
            let codex = await CodexFetcher(runner: codexRunner, authFile: RunnerTests.authFile)
                .fetch(RunnerTests.codex, now: .now, last: nil)
            #expect(RunnerTests.windows(codex.state).map(\.usedPercent) == [90], "redacted: \(redacted)")
        }
        let raw = try Fixture.lines("own")
        let plain = await ClaudeFetcher(runner: ScriptedRunner(replies: RunnerTests.batches(raw, waitingFor: ["\"request_id\": \"1\"", "\"request_id\":\"2\""])), primer: primer).fetch(work, now: .now, last: nil)
        let clean = await ClaudeFetcher(runner: ScriptedRunner(replies: RunnerTests.batches(raw, waitingFor: ["\"request_id\": \"1\"", "\"request_id\":\"2\""]).map { $0.map(FixtureRecording.redact) }), primer: primer).fetch(work, now: .now, last: nil)
        #expect(RunnerTests.windows(plain.state) == RunnerTests.windows(clean.state))
    }

    @Test("a recording goes to .scratch/recordings, private to the user, and replaces only its own file")
    func recordingsAreOwnerOnlyAndOutsideTheFixtures() throws {
        let clone = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: clone) }
        let folder = FixtureRecording.directory(in: clone)
        #expect(folder.path == clone.appendingPathComponent(".scratch/recordings").path)

        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 12))!
        let written = try FixtureRecording.write(["{}"], seat: SeatID(rawValue: "work"), date: day, into: folder)
        #expect(written.deletingLastPathComponent().path == folder.path)
        #expect(written.lastPathComponent == "work-2026-09-22.jsonl")
        #expect(try Self.mode(written) == 0o600)
        #expect(try Self.mode(folder) == 0o700)
        // A second recording that day replaces the first, still private.
        _ = try FixtureRecording.write(["{\"type\":\"result\"}"], seat: SeatID(rawValue: "work"), date: day, into: folder)
        #expect(try String(contentsOf: written, encoding: .utf8) == "{\"type\":\"result\"}\n")
        #expect(try Self.mode(written) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["work-2026-09-22.jsonl"])
    }

    @Test("a seat id that would leave the recordings folder writes nothing")
    func aClimbingIDWritesNothing() throws {
        let clone = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: clone) }
        let folder = FixtureRecording.directory(in: clone)
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 12))!
        for id in ["../../escaped", "a/b", "/abs", ""] {
            #expect(throws: (any Error).self, "\(id)") {
                try FixtureRecording.write(["{}"], seat: SeatID(rawValue: id), date: day, into: folder)
            }
        }
        let left = FileManager.default.enumerator(atPath: clone.path)?.allObjects as? [String] ?? []
        #expect(left.allSatisfy { !$0.hasSuffix(".jsonl") })
    }
}
