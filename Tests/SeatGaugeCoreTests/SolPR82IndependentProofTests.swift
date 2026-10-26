import Foundation
import Testing
@testable import SeatGaugeCore

@Suite struct SolPR82IndependentProofTests {
    private func tokenLine(_ input: Int) -> Data {
        Data("""
        {"type":"session_meta","payload":{"id":"closed-999","cwd":"/work/project"}}
        {"type":"turn_context","payload":{"model":"gpt-6.1-sol"}}
        {"timestamp":"2026-10-15T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(input),"output_tokens":10,"total_tokens":\(input + 10)}}}}

        """.utf8)
    }

    private func scenario(restart: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let machines = (1...5).map { Machine(id: "m\($0)", label: "Machine", ssh: "m\($0)") }
        for machine in machines {
            let dir = root.appendingPathComponent(machine.id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let path = dir.appendingPathComponent("rollout-oldest.jsonl")
            try tokenLine(100).write(to: path)
            let observations = (0..<1000).map { i -> SessionObservation in
                var row = SessionRow(sessionId: "closed-\(i)", workspace: "PROJECT-Log-work", pane: "w1:p1",
                                     tool: "codex", status: "closed", asOf: now)
                row.closedAt = now.addingTimeInterval(-Double(i + 1) * 60)
                return SessionObservation(row: row, pid: i + 1, processStart: "start", paths: i == 999 ? [path.path] : [])
            }
            try SessionLedger(directory: dir).append(observations)
        }
        let runner = IndependentHelperRunner(root: root)
        let file = root.appendingPathComponent("log.json")
        let config = Config(seats: [], pollMinutes: 5, machines: machines)
        func monitor() -> SessionLogMonitor {
            SessionLogMonitor(prober: MachineProber(runner: runner, environment: [:]), file: file, config: { config })
        }
        let firstMonitor = monitor()
        let first = await firstMonitor.read()
        #expect(first.problems.isEmpty)
        #expect(first.sessions.count == 4000)
        #expect(!first.sessions.contains { $0.sessionId == "closed-999" })
        let dir = root.appendingPathComponent("m1")
        let source = dir.appendingPathComponent("rollout-oldest.jsonl")
        func checkpoint() throws -> SessionCheckpoint {
            try JSONDecoder().decode(SessionCheckpoint.self, from: Data(contentsOf: dir.appendingPathComponent("offsets.json")))
        }
        #expect(try checkpoint().files[source.path]?.total.input == 100)
        let writer = try FileHandle(forWritingTo: source)
        try writer.seekToEnd(); try writer.write(contentsOf: tokenLine(200)); try writer.close()
        let secondMonitor = restart ? monitor() : firstMonitor
        let second = await secondMonitor.read()
        #expect(second.problems.isEmpty)
        #expect(!second.sessions.contains { $0.sessionId == "closed-999" })
        let state = try checkpoint()
        print("restart=\(restart) public=\(second.sessions.count) ledgerOldest=\(try SessionLedger(directory: dir).rows()["closed-999"] != nil) checkpointInput=\(state.files[source.path]?.total.input ?? -1) commandsWithCutoff=\(runner.commands.filter { $0.contains("--closed-through") }.count)")
        #expect(try SessionLedger(directory: dir).rows()["closed-999"] == nil)
        #expect(state.files[source.path] == nil)
        #expect(state.owners[source.path] == nil)
    }

    @Test("Sol proof, criterion 1: combined-file eviction reaches real private probes on the next round")
    func globalEvictionWithoutRestart() async throws { try await scenario(restart: false) }

    @Test("Sol proof, criterion 1: combined-file eviction survives monitor recreation before the next round")
    func globalEvictionAcrossMonitorRestart() async throws { try await scenario(restart: true) }
}

private final class IndependentHelperRunner: ProcessRunning, @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var sent: [String] = []
    var commands: [String] { lock.withLock { sent } }
    init(root: URL) { self.root = root }
    func launch(_ spec: ProcessSpec) throws -> any ProcessSession {
        guard let index = spec.arguments.firstIndex(of: "--"), index + 1 < spec.arguments.count else {
            throw ProcessFailure("expected synthetic remote helper")
        }
        let directory = root.appendingPathComponent(spec.arguments[index + 1])
        return IndependentHelperSession { command in
            self.lock.withLock { self.sent.append(command) }
            let arguments = command.split(separator: " ").map(String.init)
            let options = SessionProbe.Arguments(Array(arguments.dropFirst(2)))
            let log = try await SessionProbe(runner: IndependentEmptyRunner(), directory: directory, home: self.root)
                .run(closedThrough: options.closedThrough)
            return String(decoding: try SessionLogFile.encoder().encode(log), as: UTF8.self)
        }
    }
}

private final class IndependentHelperSession: ProcessSession, @unchecked Sendable {
    let stdoutLines: AsyncThrowingStream<String, Error>
    let continuation: AsyncThrowingStream<String, Error>.Continuation
    let reply: @Sendable (String) async throws -> String
    init(reply: @escaping @Sendable (String) async throws -> String) {
        let stream = AsyncThrowingStream<String, Error>.makeStream()
        stdoutLines = stream.stream; continuation = stream.continuation; self.reply = reply
    }
    func send(_ line: String) throws {
        Task {
            do { continuation.yield(try await reply(line)); continuation.finish() }
            catch { continuation.finish(throwing: error) }
        }
    }
    func closeInput() {}
    func terminate() { continuation.finish() }
}

private struct IndependentEmptyRunner: ProcessRunning {
    func launch(_ spec: ProcessSpec) throws -> any ProcessSession {
        let line: String
        switch spec.arguments {
        case ["pane", "list"]: line = #"{"result":{"panes":[]}}"#
        case ["workspace", "list"]: line = #"{"result":{"workspaces":[]}}"#
        default: throw ProcessFailure("unexpected command")
        }
        return IndependentEmptySession(line: line)
    }
}

private struct IndependentEmptySession: ProcessSession {
    let stdoutLines: AsyncThrowingStream<String, Error>
    init(line: String) {
        stdoutLines = AsyncThrowingStream { continuation in continuation.yield(line); continuation.finish() }
    }
    func send(_ line: String) throws {}
    func closeInput() {}
    func terminate() {}
}
