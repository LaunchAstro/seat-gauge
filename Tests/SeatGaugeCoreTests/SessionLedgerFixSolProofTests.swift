import Foundation
import Testing
@testable import SeatGaugeCore

@Suite struct SessionLedgerFixSolProofTests {
    private func rollout(_ id: String, input: Int) -> Data {
        Data("""
        {"type":"session_meta","payload":{"id":"\(id)","cwd":"/work/project"}}
        {"type":"turn_context","payload":{"model":"gpt-6.1-sol"}}
        {"timestamp":"2026-10-15T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(input),"output_tokens":10,"total_tokens":\(input + 10)}}}}

        """.utf8)
    }

    @Test("Sol proof, criterion 1: a closed session is not rewritten for a live peer")
    func closedSessionIsNotRewrittenForLivePeer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let alpha = root.appendingPathComponent("rollout-alpha.jsonl")
        let beta = root.appendingPathComponent("rollout-beta.jsonl")
        try rollout("alpha", input: 100).write(to: alpha)
        try rollout("beta", input: 40).write(to: beta)
        let directory = root.appendingPathComponent("private")
        let ledger = SessionLedger(directory: directory)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        func probe(_ path: String?) -> SessionProbe {
            SessionProbe(runner: SolFixLedgerRunner(path: path), directory: directory, home: root)
        }
        _ = try await probe(alpha.path).run(now: start)
        // A pass loses the pane listing; the same process is listed again
        // later, now reporting a different session.
        _ = try await probe(nil).run(now: start.addingTimeInterval(30))
        let closed = try #require(ledger.rows()["alpha"])
        #expect(closed.row.closedAt == start.addingTimeInterval(30))
        _ = try await probe(beta.path).run(now: start.addingTimeInterval(60))
        #expect(try ledger.rows()["alpha"]?.matches(closed) == true)
        #expect(try ledger.rows()["alpha"] == closed)
        let before = try Data(contentsOf: ledger.file)
        let writer = try FileHandle(forWritingTo: beta)
        try writer.seekToEnd()
        try writer.write(contentsOf: rollout("beta", input: 80))
        try writer.close()
        let snapshot = try await probe(beta.path).run(now: start.addingTimeInterval(90))
        let closedNow = try #require(snapshot.sessions.first { $0.sessionId == "alpha" })
        #expect(closedNow.closedAt == closed.row.closedAt)
        #expect(closedNow.tokens == closed.row.tokens)
        #expect(try ledger.rows()["alpha"]?.matches(closed) == true)
        #expect(try ledger.rows()["alpha"] == closed)
        let appended = try Data(contentsOf: ledger.file).dropFirst(before.count)
        let observations = appended.split(separator: 0x0A).compactMap {
            try? JSONDecoder().decode(SessionObservation.self, from: Data($0))
        }
        #expect(observations.map(\.row.sessionId).sorted() == ["beta"])
    }
}

private struct SolFixLedgerRunner: ProcessRunning {
    let path: String?

    func launch(_ spec: ProcessSpec) throws -> any ProcessSession {
        let lines: [String]
        switch spec.arguments {
        case ["pane", "list"]:
            lines = path == nil
                ? [#"{"result":{"panes":[]}}"#]
                : [#"{"result":{"panes":[{"pane_id":"w1:p1","workspace_id":"w1","agent_status":"working"}]}}"#]
        case ["workspace", "list"]:
            lines = [#"{"result":{"workspaces":[{"workspace_id":"w1","label":"PROJECT-Log-work"}]}}"#]
        case ["pane", "process-info", "--pane", "w1:p1"]:
            lines = [#"{"result":{"process_info":{"foreground_processes":[{"argv":["codex","-m","gpt-6.1-sol"],"pid":123}]}}}"#]
        default:
            if spec.executable.lastPathComponent == "ps" { lines = ["Thu Oct 15 01:00:00 2026"] }
            else if spec.executable.lastPathComponent == "lsof" { lines = path.map { ["n" + $0] } ?? [] }
            else { lines = [] }
        }
        return SolFixLedgerSession(lines: lines)
    }
}

private struct SolFixLedgerSession: ProcessSession {
    let stdoutLines: AsyncThrowingStream<String, Error>
    init(lines: [String]) {
        stdoutLines = AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
    func send(_ line: String) throws {}
    func closeInput() {}
    func terminate() {}
}
