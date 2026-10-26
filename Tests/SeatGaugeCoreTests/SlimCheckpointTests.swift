import Foundation
import Testing
@testable import SeatGaugeCore

/// Issue #120: the log's checkpoint keeps only what resumes a read, and the
/// totals it gives are the ones the per-message checkpoint gave.
@Suite struct SlimCheckpointTests {
    func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func claude(_ id: String, input: Int, request: String? = nil) -> String {
        #"{"type":"assistant","timestamp":"2026-10-15T01:00:00Z","requestId":"\#(request ?? "request-" + id)","message":{"id":"msg_\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":\#(input),"output_tokens":10}}}"#
            + "\n"
    }

    func row(_ tool: String) -> SessionRow {
        SessionRow(sessionId: "main", workspace: "PROJECT-Log-work", pane: "w1:p1", tool: tool, status: "working", asOf: Date())
    }

    func inode(_ url: URL) throws -> UInt64 {
        try #require((FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    @Test("a Claude checkpoint keeps each message once, as a digest, and no per-message record")
    func claudeCheckpointKeepsDigestsOnly() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        // Each message is written on two lines, as Claude writes one line per
        // content block.
        let text = (0 ..< 500).map { claude("m\($0)", input: $0 + 1) + claude("m\($0)", input: $0 + 1) }.joined()
        try Data(text.utf8).write(to: file)
        let probe = SessionProbe(directory: root, home: root)
        var checkpoint = SessionCheckpoint()
        let read = probe.refreshed(row("claude"), paths: [file.path], checkpoint: &checkpoint, rates: .bundled)
        let expected = ClaudeCollector.read(file: file, primer: root.appendingPathComponent("primer"))
            .responses.map(\.counts).reduce(TokenCounts(), +)
        #expect(read.tokens == expected)
        #expect(expected.responses == 500)
        let encoded = try JSONEncoder().encode(checkpoint)
        let text2 = String(decoding: encoded, as: UTF8.self)
        for key in ["msg_", "\"responses\":[", "\"seen\"", "messageOwners", "\"events\""] { #expect(!text2.contains(key)) }
        // Eight bytes a message, written as base64, and a little for the file.
        #expect(encoded.count < 500 * 11 + 1_000)
        let again = try JSONDecoder().decode(SessionCheckpoint.self, from: encoded)
        var resumed = again
        try Data((text + claude("m0", input: 1) + claude("late", input: 7)).utf8).write(to: file)
        let next = probe.refreshed(row("claude"), paths: [file.path], checkpoint: &resumed, rates: .bundled)
        #expect(next.tokens?.input == expected.input + 7)
        #expect(next.tokens?.responses == 501)
    }

    @Test("an old checkpoint migrates on first read with the totals it gave, and reads nothing again")
    func oldCheckpointMigratesWithoutRecounting() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a.jsonl")
        let second = root.appendingPathComponent("b.jsonl")
        try Data((claude("shared", input: 100) + claude("a-own", input: 20)).utf8).write(to: first)
        try Data((claude("shared", input: 100) + claude("b-own", input: 3)).utf8).write(to: second)
        // The old file's counts differ from the transcripts, so a re-read would show.
        func response(_ id: String, _ input: Int) -> [String: Any] {
            ["requestID": "request-" + id, "messageID": "msg_" + id, "model": "claude-opus-5-5", "at": 0,
             "counts": ["responses": 1, "input": input, "output": 10, "thinking": 0, "cacheRead": 0, "cacheWrite5m": 0, "cacheWrite1h": 0]]
        }
        func file(_ url: URL, _ responses: [[String: Any]]) throws -> [String: Any] {
            ["offset": try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int, "identity": try inode(url),
             "model": "unknown", "seen": responses.map { $0["messageID"]! }, "models": [:] as [String: Any],
             "events": [] as [Any], "responses": responses, "complete": true]
        }
        // Codex: a resume in a second file, whose first event is measured
        // against the first file's last total.
        let rollouts = [root.appendingPathComponent("rollout-a.jsonl"), root.appendingPathComponent("rollout-b.jsonl")]
        let rolloutText = [
            Self.rollout("resumed", [(1, 100, nil), (2, 150, nil)]),
            Self.rollout("resumed", [(3, 180, 30), (4, 200, nil)]),
        ]
        for (url, text) in zip(rollouts, rolloutText) { try Data(text.utf8).write(to: url) }
        func event(_ at: Int, _ input: Int, _ last: Int?) -> [String: Any] {
            var event: [String: Any] = ["at": Double(at * 3600), "model": "gpt-6.1-sol",
                                        "total": ["input_tokens": input, "output_tokens": 10, "total_tokens": input + 10]]
            if let last { event["last"] = ["input_tokens": last, "output_tokens": 1, "total_tokens": last + 1] }
            return event
        }
        func codexFile(_ url: URL, _ events: [[String: Any]]) throws -> [String: Any] {
            ["offset": try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int, "identity": try inode(url),
             "session": "resumed", "cwd": "/work/project", "firstToken": events[0]["at"]!, "model": "gpt-6.1-sol",
             "seen": [] as [Any], "models": [:] as [String: Any], "responses": [] as [Any], "events": events, "complete": true]
        }
        let legacy: [String: Any] = [
            "files": [
                first.path: try file(first, [response("shared", 7), response("a-own", 20)]),
                second.path: try file(second, [response("shared", 7), response("b-own", 3)]),
                rollouts[0].path: try codexFile(rollouts[0], [event(1, 100, nil), event(2, 150, nil)]),
                rollouts[1].path: try codexFile(rollouts[1], [event(3, 180, 30), event(4, 200, nil)]),
            ],
            "owners": [first.path: "main", second.path: "main", rollouts[0].path: "main", rollouts[1].path: "main"],
            // The second file was the one counting the shared message.
            "messageOwners": ["msg_shared": second.path, "msg_a-own": first.path, "msg_b-own": second.path],
        ]
        var checkpoint = try JSONDecoder().decode(SessionCheckpoint.self,
                                                  from: JSONSerialization.data(withJSONObject: legacy))
        let probe = SessionProbe(directory: root, home: root)
        let claudeRow = probe.refreshed(row("claude"), paths: [first.path, second.path], checkpoint: &checkpoint, rates: .bundled)
        #expect(claudeRow.tokens?.input == 7 + 20 + 3)
        #expect(claudeRow.tokens?.responses == 3)
        #expect(!claudeRow.stale)
        let codexRow = probe.refreshed(row("codex"), paths: rollouts.map(\.path), checkpoint: &checkpoint, rates: .bundled)
        let spend = CodexRollout.read(files: rollouts, calendar: .current).cells.values.reduce(TokenCounts(), +)
        #expect(codexRow.tokens == spend)
        #expect(spend.input == 100 + 50 + 30 + 20)
        // Written again, it is the new shape alone, and the shared message
        // passes to the first file once the second no longer has it.
        let written = String(decoding: try JSONEncoder().encode(checkpoint), as: UTF8.self)
        for key in ["msg_", "messageOwners", "\"events\"", "\"seen\""] { #expect(!written.contains(key)) }
        var reread = try JSONDecoder().decode(SessionCheckpoint.self, from: Data(written.utf8))
        try Data(claude("b-new", input: 1).utf8).write(to: second, options: .atomic)
        let moved = probe.refreshed(row("claude"), paths: [first.path, second.path], checkpoint: &reread, rates: .bundled)
        #expect(moved.tokens?.input == 7 + 20 + 1)
    }

    /// One rollout: `(hour, input total, last input)` per usage event.
    static func rollout(_ session: String, _ events: [(Int, Int, Int?)], padding: Int = 0) -> String {
        var text = #"{"type":"session_meta","payload":{"id":"\#(session)","cwd":"/work/project"}}"# + "\n"
            + #"{"type":"turn_context","payload":{"model":"gpt-6.1-sol"}}"# + "\n"
        for (hour, input, last) in events {
            if padding > 0 { text += #"{"type":"response_item","text":""# + String(repeating: "x", count: padding) + "\"}\n" }
            let lastText = last.map { #","last_token_usage":{"input_tokens":\#($0),"output_tokens":1,"total_tokens":\#($0 + 1)}"# } ?? ""
            text += #"{"timestamp":"2026-10-15T\#(String(format: "%02d", hour)):00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"output_tokens":10,"total_tokens":\#(input + 10)}\#(lastText)}}}"#
                + "\n"
        }
        return text
    }

    @Test("Codex totals from the slim checkpoint match Spend across resumes, forks, resets and read budgets")
    func codexTotalsMatchSpend() async throws {
        var random = SplitMix(seed: 120)
        for _ in 0 ..< 60 {
            let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
            var hour = 0
            var urls: [URL] = []
            for index in 0 ..< Int.random(in: 1 ... 4, using: &random) {
                // Mostly one session and its resumes, sometimes a fork.
                let session = Int.random(in: 0 ..< 4, using: &random) == 0 ? "fork" : "main"
                var input = Int.random(in: 0 ... 50, using: &random)
                var events: [(Int, Int, Int?)] = []
                for _ in 0 ..< Int.random(in: 0 ... 5, using: &random) {
                    hour += 1
                    // A total that falls is a reset.
                    input = Int.random(in: 0 ..< 6, using: &random) == 0
                        ? Int.random(in: 0 ... 20, using: &random) : input + Int.random(in: 0 ... 90, using: &random)
                    events.append((hour, input, Bool.random(using: &random) ? Int.random(in: 0 ... 40, using: &random) : nil))
                }
                let url = root.appendingPathComponent("rollout-\(index).jsonl")
                try Data(Self.rollout(session, events, padding: Bool.random(using: &random) ? 900 : 0).utf8).write(to: url)
                urls.append(url)
            }
            let budget = [256, 1_024, 32 << 20][Int.random(in: 0 ..< 3, using: &random)]
            let probe = SessionProbe(directory: root, home: root, byteBudget: budget)
            var checkpoint = SessionCheckpoint()
            var shown = row("codex")
            for _ in 0 ..< 40 {
                shown = probe.refreshed(row("codex"), paths: urls.map(\.path), checkpoint: &checkpoint, rates: .bundled)
                // Through the file, as the probe's next pass reads it.
                checkpoint = try JSONDecoder().decode(SessionCheckpoint.self, from: JSONEncoder().encode(checkpoint))
                if !shown.stale { break }
            }
            let spend = CodexRollout.read(files: urls, calendar: .current).cells.values.reduce(TokenCounts(), +)
            #expect(!shown.stale)
            #expect(shown.tokens ?? TokenCounts() == spend)
        }
    }

    @Test("a resumed file whose usage fields change inside it keeps its tokens pending rather than guess")
    func unevenResumeIsPending() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("rollout-a.jsonl")
        let second = root.appendingPathComponent("rollout-b.jsonl")
        try Data(Self.rollout("main", [(1, 100, nil)]).utf8).write(to: first)
        // The second file's later event carries a field its first did not.
        let uneven = Self.rollout("main", [(2, 150, nil)])
            + #"{"timestamp":"2026-10-15T03:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":170,"cached_input_tokens":5,"output_tokens":10,"total_tokens":180}}}}"#
            + "\n"
        try Data(uneven.utf8).write(to: second)
        let probe = SessionProbe(directory: root, home: root)
        var checkpoint = SessionCheckpoint()
        let shown = probe.refreshed(row("codex"), paths: [first.path, second.path], checkpoint: &checkpoint, rates: .bundled)
        #expect(shown.stale)
        #expect(shown.usd == nil)
        // Alone, the same file is exact.
        var alone = SessionCheckpoint()
        let single = probe.refreshed(row("codex"), paths: [second.path], checkpoint: &alone, rates: .bundled)
        #expect(!single.stale)
        #expect(single.tokens == CodexRollout.read(files: [second], calendar: .current).cells.values.reduce(TokenCounts(), +))
    }

    @Test("the roll-up keeps a session's cost only while log.json shows the session")
    func sessionCostsFollowTheLog() async throws {
        let scratch = try SpendRollupTests.Scratch()
        defer { scratch.remove() }
        let state = StateStore(file: scratch.directory.appendingPathComponent("state.json"))
        try state.update { $0.sessionCosts = ["gone": 9, "session-a": 0.5] }
        let shown = SessionLogFile(updated: Date(), sessions: [
            SessionRow(sessionId: "session-a", workspace: "", pane: "w1:p1", tool: "claude", status: "closed", asOf: Date()),
        ])
        try SessionLogFile.encoder().encode(shown).write(to: scratch.directory.appendingPathComponent("log.json"))
        _ = try await scratch.run()
        #expect(state.load().sessionCosts == ["session-a": 1.5])
        try FileManager.default.removeItem(at: scratch.directory.appendingPathComponent("log.json"))
        _ = try await scratch.run()
        #expect(state.load().sessionCosts.isEmpty)
    }
}

/// A seeded generator, so a failing case can be run again.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
