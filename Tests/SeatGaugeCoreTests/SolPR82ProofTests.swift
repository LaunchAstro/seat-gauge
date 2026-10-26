import Foundation
import Testing
@testable import SeatGaugeCore

/// Sol's finding S82-1 on PR 82, as a test. S82-2's file-wide cap left the
/// pull request with its design (see docs/session-log.md).
@Suite struct SolPR82ProofTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func closed(_ id: String, at date: Date, machine: String = "") -> SessionRow {
        var row = SessionRow(machine: machine, sessionId: id, workspace: "PROJECT-Log-work", pane: "w1:p1",
                             tool: "codex", status: "closed", asOf: date)
        row.closedAt = date
        return row
    }

    private func checkpoint(_ directory: URL) throws -> SessionCheckpoint {
        try JSONDecoder().decode(SessionCheckpoint.self, from: Data(contentsOf: directory.appendingPathComponent("offsets.json")))
    }

    /// Seeds `count` closed sessions, one a minute before `now`, the oldest
    /// holding `path` in the ledger and checkpoint.
    private func seed(_ directory: URL, count: Int, now: Date, path: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledger = SessionLedger(directory: directory)
        let oldest = count - 1
        try ledger.append((0..<count).map { index in
            SessionObservation(row: closed("closed-\(index)", at: now.addingTimeInterval(-Double(index + 1) * 60)),
                               pid: 1_000 + index, processStart: "start", paths: index == oldest ? [path] : [])
        })
        var state = SessionCheckpoint()
        state.files[path] = SessionTokens(); state.owners[path] = "closed-\(oldest)"
        try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("offsets.json"))
    }

    @Test("S82-1: a session the cap retires at the end of a pass leaves the checkpoint and the output too")
    func capRetiredAtTheEndOfAPassLeavesEverything() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("private")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let path = root.appendingPathComponent("rollout-oldest.jsonl").path
        try seed(directory, count: SessionRetention.closedPerMachine, now: now, path: path)
        // One more session, open, whose pane has gone: this pass closes it,
        // which puts the machine one over its cap.
        let open = SessionRow(sessionId: "open", workspace: "PROJECT-Log-work", pane: "w9:p9",
                              tool: "codex", status: "working", asOf: now)
        try SessionLedger(directory: directory).append([SessionObservation(row: open, pid: 9, processStart: "start", paths: [])])
        let probe = SessionProbe(runner: EmptyPanes(), directory: directory, home: root)
        let log = try await probe.run(now: now)
        let oldest = "closed-\(SessionRetention.closedPerMachine - 1)"
        #expect(log.sessions.first { $0.sessionId == "open" }?.closedAt == now)
        #expect(!log.sessions.contains { $0.sessionId == oldest })
        #expect(log.sessions.count == SessionRetention.closedPerMachine)
        #expect(try SessionLedger(directory: directory).rows()[oldest] == nil)
        #expect(try checkpoint(directory).files[path] == nil)
        #expect(try checkpoint(directory).owners[path] == nil)
    }
}

private struct EmptyPanes: ProcessRunning {
    func launch(_ spec: ProcessSpec) throws -> any ProcessSession {
        switch spec.arguments {
        case ["pane", "list"]: return ProofSession(lines: [#"{"result":{"panes":[]}}"#])
        case ["workspace", "list"]: return ProofSession(lines: [#"{"result":{"workspaces":[]}}"#])
        default: return ProofSession(lines: [])
        }
    }
}

private struct ProofSession: ProcessSession {
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
