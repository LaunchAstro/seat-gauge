import Foundation
import Testing
@testable import SeatGaugeCore

/// Issue #70: a closed session leaves `log.json`, the private ledger and the
/// pass on one rule, read from its `closed_at`, and `log.json` stays under
/// what a reader caps it at (issue #38's note: 4,000,000 bytes, 5,000 rows).
@Suite struct SessionRetentionTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func rollout(_ id: String) -> Data {
        Data("""
        {"type":"session_meta","payload":{"id":"\(id)","cwd":"/work/project"}}
        {"type":"turn_context","payload":{"model":"gpt-6.1-sol"}}
        {"timestamp":"2026-10-15T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":10,"total_tokens":110}}}}

        """.utf8)
    }

    private let week: TimeInterval = 7 * 86_400

    @Test func aClosedSessionLeavesTheLogTheLedgerAndThePassAWeekAfterItClosed() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-main.jsonl")
        try rollout("main").write(to: file)
        let directory = root.appendingPathComponent("private")
        let ledger = SessionLedger(directory: directory)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try await SessionProbe(runner: RetentionRunner(present: true, path: file.path), directory: directory, home: root)
            .run(now: start)
        let gone = SessionProbe(runner: RetentionRunner(present: false, path: file.path), directory: directory, home: root)
        let closed = try await gone.run(now: start.addingTimeInterval(30))
        let closedAt = try #require(closed.sessions.first?.closedAt)

        let lastDay = try await gone.run(now: closedAt.addingTimeInterval(week - 60))
        #expect(lastDay.sessions.map(\.sessionId) == ["main"])
        #expect(lastDay.sessions.first?.tokens?.input == 100)

        let after = try await gone.run(now: closedAt.addingTimeInterval(week))
        #expect(after.sessions.isEmpty)
        #expect(try ledger.rows().isEmpty)
        #expect(!String(decoding: try Data(contentsOf: ledger.file), as: UTF8.self).contains("\"main\""))
        func checkpoint() throws -> SessionCheckpoint {
            try JSONDecoder().decode(SessionCheckpoint.self,
                                     from: Data(contentsOf: directory.appendingPathComponent("offsets.json")))
        }
        #expect(try checkpoint().files[file.path] == nil)
        #expect(try checkpoint().owners[file.path] == nil)
        // The next pass does not read its transcript again.
        _ = try await gone.run(now: closedAt.addingTimeInterval(week + 30))
        #expect(try checkpoint().files.isEmpty)
    }

    @Test func eachMachineKeepsItsNewestThousandClosedSessionsAndEveryOpenOne() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var rows: [SessionRow] = []
        for index in 0..<1_005 {
            var row = SessionRow(sessionId: "closed-\(index)", workspace: "PROJECT-Log-work", pane: "w1:p1",
                                 tool: "codex", status: "closed", asOf: now)
            row.closedAt = now.addingTimeInterval(-Double(index) * 60)
            rows.append(row)
        }
        var old = SessionRow(sessionId: "old", workspace: "PROJECT-Log-work", pane: "w1:p1",
                             tool: "codex", status: "closed", asOf: now)
        old.closedAt = now.addingTimeInterval(-week)
        rows.append(old)
        for index in 0..<3 {
            // An open session is kept however long ago it was last seen.
            rows.append(SessionRow(sessionId: "open-\(index)", workspace: "PROJECT-Log-work", pane: "w1:p\(index)",
                                   tool: "codex", status: "working", asOf: now.addingTimeInterval(-30 * 86_400)))
        }
        let kept = Set(SessionRetention.kept(rows.shuffled(), row: { $0 }, now: now).map(\.sessionId))
        #expect(kept.count == 1_003)
        #expect(kept.isSuperset(of: ["open-0", "open-1", "open-2", "closed-0", "closed-999"]))
        #expect(!kept.contains("closed-1000"))
        #expect(!kept.contains("old"))
    }

    @Test func logJSONStaysUnderWhatAReaderAcceptsAndDropsTheOldestClosedRowsFirst() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        var rows: [SessionRow] = []
        for index in 0..<1_200 {
            // Long labels, so the byte limit binds before the row limit.
            var row = SessionRow(sessionId: "closed-\(index)", workspace: String(repeating: "w", count: 1_500) + "-Log-work",
                                 pane: "w1:p1", tool: "codex", status: "closed", asOf: now)
            row.closedAt = now.addingTimeInterval(-Double(index) * 60)
            rows.append(row)
        }
        var stale = SessionRow(sessionId: "eight-days", workspace: "PROJECT-Log-work", pane: "w1:p1",
                               tool: "codex", status: "closed", asOf: now)
        stale.closedAt = now.addingTimeInterval(-8 * 86_400)
        rows.append(stale)
        rows.append(SessionRow(sessionId: "open", workspace: "PROJECT-Log-work", pane: "w1:p2",
                               tool: "codex", status: "working", asOf: now))
        // An older probe on the far machine sends every closed session it has.
        let answer = String(decoding: try SessionLogFile.encoder().encode(SessionLogFile(updated: now, sessions: rows)),
                            as: UTF8.self)
        let machines = (1...5).map { Machine(id: "m\($0)", label: "M\($0)", ssh: "m\($0)") }
        let config = Config(seats: [], pollMinutes: 5, machines: machines)
        let file = root.appendingPathComponent("log.json")
        let monitor = SessionLogMonitor(prober: MachineProber(runner: AnswerRunner(line: answer), environment: [:]),
                                        file: file, config: { config })
        let log = await monitor.read()
        let size = try Data(contentsOf: file).count
        #expect(size <= SessionRetention.fileBytes)
        #expect(SessionRetention.fileBytes < 4_000_000)
        #expect(log.sessions.count <= SessionRetention.fileRows)
        #expect(SessionRetention.fileRows < 5_000)
        #expect(log.sessions.filter { $0.sessionId == "open" }.count == 5)
        #expect(!log.sessions.contains { $0.sessionId == "eight-days" })
        for machine in machines {
            let closed = log.sessions.filter { $0.machine == machine.id && $0.closedAt != nil }
            #expect(closed.count <= SessionRetention.closedPerMachine)
            // What is left of a machine's closed rows is its newest.
            let oldestKept = closed.compactMap(\.closedAt).min() ?? now
            #expect(!rows.contains { row in
                row.closedAt.map { $0 > oldestKept && $0 > now.addingTimeInterval(-week) } == true
                    && !closed.contains { $0.sessionId == row.sessionId }
            })
        }
    }
}

private struct RetentionRunner: ProcessRunning {
    let present: Bool
    let path: String

    func launch(_ spec: ProcessSpec) throws -> any ProcessSession {
        let lines: [String]
        switch spec.arguments {
        case ["pane", "list"]:
            lines = present
                ? [#"{"result":{"panes":[{"pane_id":"w1:p1","workspace_id":"w1","agent_status":"working"}]}}"#]
                : [#"{"result":{"panes":[]}}"#]
        case ["workspace", "list"]:
            lines = [#"{"result":{"workspaces":[{"workspace_id":"w1","label":"PROJECT-Log-work"}]}}"#]
        case ["pane", "process-info", "--pane", "w1:p1"]:
            lines = [#"{"result":{"process_info":{"foreground_processes":[{"argv":["codex"],"pid":123}]}}}"#]
        default:
            if spec.executable.lastPathComponent == "ps" { lines = ["Thu Oct 15 01:00:00 2026"] }
            else if spec.executable.lastPathComponent == "lsof" { lines = ["n" + path] }
            else { lines = [] }
        }
        return RetentionSession(lines: lines)
    }
}

private struct AnswerRunner: ProcessRunning {
    let line: String
    func launch(_ spec: ProcessSpec) throws -> any ProcessSession { RetentionSession(lines: [line]) }
}

private struct RetentionSession: ProcessSession {
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
