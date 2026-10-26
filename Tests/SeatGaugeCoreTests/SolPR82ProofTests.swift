import Foundation
import Testing
@testable import SeatGaugeCore

/// Sol's two findings on PR 82 (S82-1, S82-2), as tests.
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

    @Test("S82-2: the monitor tells each probe which closed rows log.json no longer shows")
    func theFileCapReachesTheProbes() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        var rows = (0..<SessionRetention.closedPerMachine).map { index in
            closed("closed-\(index)", at: now.addingTimeInterval(-Double(index + 1) * 60))
        }
        rows.append(SessionRow(sessionId: "open", workspace: "PROJECT-Log-work", pane: "w1:p2",
                               tool: "codex", status: "working", asOf: now))
        let answer = String(decoding: try SessionLogFile.encoder().encode(SessionLogFile(updated: now, sessions: rows)),
                            as: UTF8.self)
        let machines = (1...5).map { Machine(id: "m\($0)", label: "M\($0)", ssh: "m\($0)") }
        let config = Config(seats: [], pollMinutes: 5, machines: machines)
        let runner = SentLines(answer: answer)
        let monitor = SessionLogMonitor(prober: MachineProber(runner: runner, environment: [:]),
                                        file: root.appendingPathComponent("log.json"), config: { config })
        let first = await monitor.read()
        #expect(first.sessions.count <= SessionRetention.fileRows)
        #expect(runner.lines.allSatisfy { !$0.contains("--closed-through") })
        let shown = first.sessions.compactMap(\.closedAt).min()!
        let hidden = rows.compactMap(\.closedAt).filter { $0 < shown }
        #expect(!hidden.isEmpty)
        _ = await monitor.read()
        // The second round names the newest hidden second to every probe.
        let through = Int(hidden.max()!.timeIntervalSince1970.rounded(.down))
        let sent = runner.lines.suffix(machines.count)
        #expect(sent.count == machines.count)
        #expect(sent.allSatisfy { $0.hasSuffix(" log-probe --closed-through \(through)") })
    }

    @Test("S82-2: a probe told a cut-off drops what is at or before it, by the second log.json shows")
    func aProbeDropsWhatTheFileNoLongerShows() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("private")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let path = root.appendingPathComponent("rollout-oldest.jsonl").path
        try seed(directory, count: 3, now: now, path: path)
        // closed-1 closed at now - 120 s, as `log.json` shows it; anything
        // in that second or before has gone from the file.
        let through = now.addingTimeInterval(-120).addingTimeInterval(0.9)
        let log = try await SessionProbe(runner: EmptyPanes(), directory: directory, home: root)
            .run(now: now, closedThrough: through)
        #expect(log.sessions.map(\.sessionId) == ["closed-0"])
        #expect(Set(try SessionLedger(directory: directory).rows().keys) == ["closed-0"])
        #expect(try checkpoint(directory).files[path] == nil)
    }

    @Test func theProbeReadsItsArgumentsAndPassesOverOnesItDoesNotKnow() {
        let both = SessionProbe.Arguments(["--directory", "/tmp/private", "--closed-through", "1790000000"])
        #expect(both.directory?.path == "/tmp/private")
        #expect(both.closedThrough == Date(timeIntervalSince1970: 1_790_000_000))
        let later = SessionProbe.Arguments(["--some-later-flag", "x", "--closed-through", "12"])
        #expect(later.directory == nil)
        #expect(later.closedThrough == Date(timeIntervalSince1970: 12))
        #expect(SessionProbe.Arguments(["--closed-through", "soon"]).closedThrough == nil)
        #expect(SessionProbe.Arguments([]).directory == nil)
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

/// Answers every probe with `answer` and keeps the command each was sent.
private final class SentLines: ProcessRunning, @unchecked Sendable {
    let answer: String
    private let lock = NSLock()
    private var sent: [String] = []
    var lines: [String] { lock.withLock { sent } }
    init(answer: String) { self.answer = answer }
    func launch(_ spec: ProcessSpec) throws -> any ProcessSession {
        ProofSession(lines: [answer]) { line in self.lock.withLock { self.sent.append(line) } }
    }
}

private struct ProofSession: ProcessSession {
    let stdoutLines: AsyncThrowingStream<String, Error>
    let sent: @Sendable (String) -> Void
    init(lines: [String], sent: @escaping @Sendable (String) -> Void = { _ in }) {
        self.sent = sent
        stdoutLines = AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
    func send(_ line: String) throws { sent(line) }
    func closeInput() {}
    func terminate() {}
}
