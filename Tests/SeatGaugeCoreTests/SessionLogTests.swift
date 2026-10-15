import Foundation
import Testing
@testable import SeatGaugeCore

@Suite struct SessionLogTests {
    func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func codex(_ id: String, input: Int, output: Int = 10) -> String {
        """
        {"type":"session_meta","payload":{"id":"\(id)","cwd":"/work/project"}}
        {"type":"turn_context","payload":{"model":"gpt-6.1-sol"}}
        {"timestamp":"2026-10-15T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(input),"output_tokens":\(output),"total_tokens":\(input + output)}}}}

        """
    }

    @Test func sharedCodexAccountingAndIndependentFork() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let files = [root.appendingPathComponent("rollout-parent.jsonl"), root.appendingPathComponent("rollout-child.jsonl")]
        try Data(codex("parent", input: 100).utf8).write(to: files[0])
        try Data(codex("child", input: 40).utf8).write(to: files[1])
        let spend = CodexRollout.read(files: files, calendar: .current).cells.values.reduce(TokenCounts(), +)
        var states = [SessionTokens(), SessionTokens()]
        for i in files.indices { try states[i].read(files[i], tool: "codex") }
        #expect(states.map(\.total).reduce(TokenCounts(), +) == spend)
        #expect(spend.input == 140)
        for i in files.indices { try states[i].read(files[i], tool: "codex") }
        #expect(states.map(\.total).reduce(TokenCounts(), +) == spend)
    }

    @Test func incrementalClaudeCountsMessageOnceAndRetainsNoText() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let line = #"{"type":"assistant","timestamp":"2026-10-15T01:00:00Z","requestId":"request-a","message":{"id":"msg_a","model":"claude-opus-5-5","content":[{"text":"PRIVATE MESSAGE CANARY"}],"usage":{"input_tokens":100,"output_tokens":10}}}"# + "\n"
        try Data(line.utf8).write(to: file)
        var state = SessionTokens(); try state.read(file, tool: "claude")
        let firstOffset = state.offset
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.replacingOccurrences(of: "request-a", with: "request-b").utf8)); try handle.close()
        try state.read(file, tool: "claude")
        #expect(state.total.input == 100)
        #expect(state.offset > firstOffset)
        #expect(state.total == ClaudeCollector.read(file: file, primer: root.appendingPathComponent("primer")).responses.map(\.counts).reduce(TokenCounts(), +))
        #expect(!String(decoding: try JSONEncoder().encode(state), as: UTF8.self).contains("CANARY"))
    }

    @Test func partialLineRestartAndTruncation() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout.jsonl")
        let bytes = Data(codex("main", input: 100).utf8)
        try bytes.dropLast(8).write(to: file)
        var state = SessionTokens(); try state.read(file, tool: "codex")
        #expect(!state.complete)
        let checkpoint = try JSONEncoder().encode(state)
        state = try JSONDecoder().decode(SessionTokens.self, from: checkpoint)
        try bytes.write(to: file)
        try state.read(file, tool: "codex")
        #expect(state.total.input == 100)
        try Data(codex("new", input: 5).utf8).write(to: file)
        try state.read(file, tool: "codex")
        #expect(state.total.input == 5)
    }

    @Test func longLineMakesProgressPastReadBudget() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout.jsonl")
        let text = "{\"type\":\"response_item\",\"text\":\"" + String(repeating: "x", count: 700_000) + "\"}\n"
        try Data((text + codex("main", input: 100)).utf8).write(to: file)
        var state = SessionTokens()
        try state.read(file, tool: "codex", budget: 1024)
        #expect(state.offset >= 700_000)
        try state.read(file, tool: "codex", budget: 1024)
        #expect(state.total.input == 100)
    }

    @Test func publicSchemaHasStableKeyAndNoPrivateFields() throws {
        var row = SessionRow(machine: "desk", sessionId: "one", workspace: "REPO-WITH-DASH-Log-work",
                             pane: "w1:p1", tool: "codex", status: "done", asOf: Date())
        row.model = "gpt-6.1-sol"; row.tokens = TokenCounts(input: 100)
        let data = try SessionLogFile.encoder().encode(SessionLogFile(updated: Date(), sessions: [row]))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("session_id"))
        let decoded = try SessionLogFile.decoder().decode(SessionLogFile.self, from: data)
        #expect(decoded.sessions.first?.id == "desk:one")
        #expect(row.repo == "REPO-WITH-DASH")
        #expect(row.section == "Log")
        #expect(row.seat == "work")
        #expect(!text.contains("paths")); #expect(!text.contains("argv")); #expect(!text.contains("pid"))
    }

    @Test func shortProcessOutputIsDrainedBeforeCompletion() async throws {
        let runner = RealProcessRunner()
        let child = try runner.launch(ProcessSpec(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "i=0; while [ $i -lt 3000 ]; do echo metadata; i=$((i+1)); done; echo final"],
            environment: ChildEnvironment.make(from: ProcessInfo.processInfo.environment)))
        child.closeInput()
        var lines: [String] = []
        for try await line in child.stdoutLines { lines.append(line) }
        #expect(lines.count == 3001)
        #expect(lines.last == "final")
    }

    @Test func modelAndEffortOnlyComeFromNamedOptions() {
        let options = SessionProbe.options(["codex", "-m", "gpt-6.1-sol", "-c", "model_reasoning_effort=high", "private prompt"])
        #expect(options.model == "gpt-6.1-sol"); #expect(options.effort == "high")
    }

    @Test func doneIsNotClosedAndLedgerRebuildKeepsFinalTokens() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-main.jsonl")
        try Data(codex("main", input: 100).utf8).write(to: file)
        let directory = root.appendingPathComponent("private")
        func probe(_ status: String?) -> SessionProbe {
            SessionProbe(runner: LogProbeRunner(status: status, paths: [file.path, file.path]), directory: directory, home: root)
        }
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let working = try await probe("working").run(now: start)
        #expect(working.sessions.count == 1)
        #expect(working.sessions[0].tokens?.input == 100)
        let done = try await probe("done").run(now: start.addingTimeInterval(30))
        #expect(done.sessions[0].closedAt == nil)
        #expect(done.sessions[0].status == "done")
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: Data(codex("main", input: 200).utf8)); try handle.close()
        let closed = try await probe(nil).run(now: start.addingTimeInterval(60))
        #expect(closed.sessions[0].status == "closed")
        #expect(closed.sessions[0].closedAt == start.addingTimeInterval(60))
        #expect(closed.sessions[0].tokens?.input == 200)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("offsets.json"))
        let rebuilt = try await probe(nil).run(now: start.addingTimeInterval(90))
        #expect(rebuilt.sessions[0].tokens == closed.sessions[0].tokens)
        #expect(rebuilt.sessions[0].startedAt == start)
        #expect(rebuilt.sessions[0].closedAt == closed.sessions[0].closedAt)
    }

    @Test func failedMachineReadPreservesRowsAsStale() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("log.json")
        let row = SessionRow(machine: "studio", sessionId: "main", workspace: "PROJECT-Log-work",
                             pane: "w1:p1", tool: "codex", status: "done", asOf: Date())
        try SessionLogFile.encoder().encode(SessionLogFile(updated: Date(), sessions: [row])).write(to: file)
        let config = Config(seats: [], pollMinutes: 5, machines: [Machine(id: "studio", label: "Studio", ssh: "studio")])
        let monitor = SessionLogMonitor(prober: MachineProber(runner: LogProbeRunner(status: nil, paths: [])),
                                        file: file, config: { config })
        let failed = await monitor.read()
        #expect(failed.sessions.count == 1)
        #expect(failed.sessions[0].stale)
        #expect(failed.sessions[0].closedAt == nil)
        #expect(failed.problems["studio"] != nil)
    }

    @Test func probeSumsForkFilesOnceAndResumesShareTheirBaseline() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("rollout-a.jsonl")
        let resume = root.appendingPathComponent("rollout-b.jsonl")
        let child = root.appendingPathComponent("rollout-c.jsonl")
        try Data(codex("main", input: 100).utf8).write(to: parent)
        try Data(codex("main", input: 150).utf8).write(to: resume)
        try Data(codex("fork", input: 40).utf8).write(to: child)
        let files = [parent, resume, child]
        let expected = CodexRollout.read(files: files, calendar: .current).cells.values.reduce(TokenCounts(), +)
        let probe = SessionProbe(runner: LogProbeRunner(status: "working", paths: files.map(\.path) + [child.path]),
                                 directory: root.appendingPathComponent("private"), home: root)
        let first = try await probe.run()
        #expect(first.sessions.count == 1)
        #expect(first.sessions[0].tokens == expected)
        let second = try await probe.run()
        #expect(second.sessions[0].tokens == expected)
        #expect(expected.input == 190)
    }
}

private struct LogProbeRunner: ProcessRunning {
    let status: String?
    let paths: [String]

    func launch(_ spec: ProcessSpec) throws -> any ProcessSession {
        var lines: [String] = []
        let args = spec.arguments
        if args == ["pane", "list"] {
            let panes: [[String: String]] = status.map { [["pane_id": "w1:p1", "workspace_id": "w1", "agent_status": $0]] } ?? []
            lines = [String(decoding: try JSONSerialization.data(withJSONObject: ["result": ["panes": panes]]), as: UTF8.self)]
        } else if args == ["workspace", "list"] {
            lines = [#"{"result":{"workspaces":[{"workspace_id":"w1","label":"PROJECT-Log-work"}]}}"#]
        } else if args == ["pane", "process-info", "--pane", "w1:p1"] {
            lines = [#"{"result":{"process_info":{"foreground_processes":[{"argv":["codex","-m","gpt-6.1-sol"],"pid":123}]}}}"#]
        } else if spec.executable.lastPathComponent == "ps" {
            lines = ["Thu Oct 15 01:00:00 2026"]
        } else if spec.executable.lastPathComponent == "lsof" { lines = paths.map { "n" + $0 } }
        return LogProbeSession(lines: lines)
    }
}

private struct LogProbeSession: ProcessSession {
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
