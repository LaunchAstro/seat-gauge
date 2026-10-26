import Foundation
import Testing
@testable import SeatGaugeCore

@Suite struct SessionLedgerSolProofTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func codex(_ id: String, input: Int) -> Data {
        Data("""
        {"type":"session_meta","payload":{"id":"\(id)","cwd":"/work/project"}}
        {"type":"turn_context","payload":{"model":"gpt-6.1-sol"}}
        {"timestamp":"2026-10-15T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(input),"output_tokens":10,"total_tokens":\(input + 10)}}}}

        """.utf8)
    }

    @Test("Sol proof, criterion 2: compaction preserves the last committed observation")
    func compactionPreservesCommittedObservation() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("rollout-main.jsonl")
        try codex("main", input: 100).write(to: source)
        let directory = root.appendingPathComponent("private")
        let ledger = SessionLedger(directory: directory)
        let probe = SessionProbe(runner: SolLedgerRunner(paths: [source.path]), directory: directory, home: root)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try await probe.run(now: start)
        let initial = try #require(ledger.rows()["main"])
        for _ in 0..<130 { try ledger.append([initial]) }
        let committed = try ledger.rows()
        let later = start.addingTimeInterval(30)
        let snapshot = try await probe.run(now: later)
        #expect(snapshot.sessions.first?.asOf == later)
        #expect(try ledger.read().lines == 1)
        #expect(try ledger.rows() == committed)
    }

    @Test("Sol proof, criterion 5: unchanged observations preserve process selection")
    func unchangedObservationsPreserveProcessSelection() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let alpha = root.appendingPathComponent("rollout-alpha.jsonl")
        let zulu = root.appendingPathComponent("rollout-zulu.jsonl")
        try codex("alpha", input: 100).write(to: alpha)
        try codex("zulu", input: 40).write(to: zulu)
        let directory = root.appendingPathComponent("private")
        func probe(_ paths: [String]) -> SessionProbe {
            SessionProbe(runner: SolLedgerRunner(paths: paths), directory: directory, home: root)
        }
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try await probe([alpha.path]).run(now: start)
        _ = try await probe([zulu.path]).run(now: start.addingTimeInterval(30))
        let handle = try FileHandle(forWritingTo: alpha)
        try handle.seekToEnd()
        try handle.write(contentsOf: codex("alpha", input: 200))
        try handle.close()
        let stillZulu = try await probe([zulu.path]).run(now: start.addingTimeInterval(60))
        #expect(stillZulu.sessions.first { $0.sessionId == "alpha" }?.status == "idle")
        #expect(stillZulu.sessions.first { $0.sessionId == "zulu" }?.status == "working")
        #expect(stillZulu.sessions.first { $0.sessionId == "alpha" }?.tokens?.input == 200)
        let temporarilyNoPaths = try await probe([]).run(now: start.addingTimeInterval(90))
        #expect(temporarilyNoPaths.sessions.first { $0.sessionId == "zulu" }?.status == "working")
        #expect(temporarilyNoPaths.sessions.first { $0.sessionId == "alpha" }?.status == "idle")
    }

    @Test("Sol proof, criterion correctness: an unreadable ledger fails instead of publishing empty history")
    func unreadableLedgerMustFail() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledger = SessionLedger(directory: directory)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var row = SessionRow(sessionId: "main", workspace: "PROJECT-Log-work", pane: "w1:p1",
                             tool: "codex", status: "closed", asOf: now)
        row.closedAt = now
        try ledger.append([SessionObservation(row: row, pid: 123, processStart: "start", paths: [])])
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: ledger.file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledger.file.path) }
        #expect(!FileManager.default.isReadableFile(atPath: ledger.file.path))
        let probe = SessionProbe(runner: SolLedgerRunner(paths: [], present: false), directory: directory, home: root)
        await #expect(throws: (any Error).self) { _ = try await probe.run(now: now.addingTimeInterval(30)) }
    }

    // The copy this test once proved byte for byte is gone: a session that
    // leaves is deleted, not archived (issue #94, D2).
    @Test func realBackupThresholdKeepsNoCopyAndPrivateMode() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = SessionLedger(directory: root)
        let row = SessionRow(sessionId: "main", workspace: String(repeating: "x", count: 32 << 10),
                             pane: "w1:p1", tool: "codex", status: "done",
                             asOf: Date(timeIntervalSince1970: 1_790_000_000))
        let observation = SessionObservation(row: row, pid: 123, processStart: "start", paths: [])
        let line = try JSONEncoder().encode(observation) + Data([0x0A])
        let count = (64 << 20) / line.count + 1
        #expect(FileManager.default.createFile(atPath: ledger.file.path, contents: nil,
                                               attributes: [.posixPermissions: 0o600]))
        let writer = try FileHandle(forWritingTo: ledger.file)
        for _ in 0..<count { try writer.write(contentsOf: line) }
        try writer.synchronize(); try writer.close()
        let stored = try ledger.read()
        #expect(stored.lines == count)
        #expect(stored.rows == ["main": observation])
        try ledger.compactIfLong(stored.rows, lines: stored.lines)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["observations.jsonl"])
        #expect(try ledger.read().lines == 1)
        #expect(try ledger.rows() == stored.rows)
        let mode = try #require(FileManager.default.attributesOfItem(atPath: ledger.file.path)[.posixPermissions] as? Int)
        #expect(mode & 0o777 == 0o600)
    }

    @Test func failedCompactionLeavesLedgerAndPassIntact() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("private")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let active = SessionProbe(runner: SolLedgerRunner(paths: []), directory: directory, home: root)
        _ = try await active.run(now: now)
        let gone = SessionProbe(runner: SolLedgerRunner(paths: [], present: false), directory: directory, home: root)
        _ = try await gone.run(now: now.addingTimeInterval(30))
        let ledger = SessionLedger(directory: directory)
        let closed = try #require(ledger.rows().values.first)
        for _ in 0..<130 { try ledger.append([closed]) }
        let before = try Data(contentsOf: ledger.file)
        let blocked = directory.appendingPathComponent("observations.jsonl.new")
        #expect(FileManager.default.createFile(atPath: blocked.path, contents: Data("occupied".utf8)))
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: blocked.path) }
        let later = now.addingTimeInterval(60)
        let snapshot = try await gone.run(now: later)
        #expect(snapshot.sessions.count == 1)
        #expect(snapshot.sessions.first?.status == "closed")
        #expect(snapshot.sessions.first?.asOf == later)
        #expect(try Data(contentsOf: ledger.file) == before)
    }
}

private struct SolLedgerRunner: ProcessRunning {
    let paths: [String]
    var present = true

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
            lines = [#"{"result":{"process_info":{"foreground_processes":[{"argv":["codex","-m","gpt-6.1-sol"],"pid":123}]}}}"#]
        default:
            if spec.executable.lastPathComponent == "ps" { lines = ["Thu Oct 15 01:00:00 2026"] }
            else if spec.executable.lastPathComponent == "lsof" { lines = paths.map { "n" + $0 } }
            else { lines = [] }
        }
        return SolLedgerSession(lines: lines)
    }
}

private struct SolLedgerSession: ProcessSession {
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
