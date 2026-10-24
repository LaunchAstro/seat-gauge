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

    @Test func positionalPromptIsNotMetadata() {
        #expect(SessionProbe.options(["codex", "model_reasoning_effort=PRIVATE_CANARY"]).effort == nil)
        #expect(SessionProbe.options(["codex", "--", "-m", "PRIVATE_CANARY"]).model == nil)
    }

    @Test func budgetedResumeFilesMatchSpend() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("rollout-a.jsonl")
        let second = root.appendingPathComponent("rollout-b.jsonl")
        let padding = "{\"type\":\"response_item\",\"text\":\"" + String(repeating: "x", count: 700_000) + "\"}\n"
        try Data((codex("main", input: 100) + padding + codex("main", input: 200)).utf8).write(to: first)
        try Data(codex("main", input: 300).replacingOccurrences(of: "01:00:00", with: "02:00:00").utf8).write(to: second)
        let probe = SessionProbe(runner: LogProbeRunner(status: "working", paths: [first.path, second.path]),
                                 directory: root.appendingPathComponent("private"), home: root, byteBudget: 1024)
        _ = try await probe.run()
        let finished = try await probe.run()
        #expect(finished.sessions[0].tokens?.input == 300)
    }

    @Test func copiedResumeFilesMatchSpend() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let second = root.appendingPathComponent("rollout-b.jsonl")
        let first = root.appendingPathComponent("rollout-a.jsonl")
        try Data(codex("main", input: 150).replacingOccurrences(of: "01:00:00", with: "02:00:00").utf8).write(to: second)
        try Data(codex("main", input: 100).utf8).write(to: first)
        let probe = SessionProbe(runner: LogProbeRunner(status: "working", paths: [first.path, second.path]),
                                 directory: root.appendingPathComponent("private"), home: root)
        let result = try await probe.run()
        #expect(result.sessions[0].tokens?.input == 150)
    }

    @Test func replacementKeepsExistingSessionTotals() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-main.jsonl")
        let data = Data(codex("main", input: 100).utf8)
        try data.write(to: file)
        let probe = SessionProbe(runner: LogProbeRunner(status: "working", paths: [file.path]),
                                 directory: root.appendingPathComponent("private"), home: root)
        let before = try await probe.run()
        try data.write(to: file, options: .atomic)
        let after = try await probe.run()
        #expect(after.sessions[0].tokens == before.sessions[0].tokens)
    }

    @Test func tornLedgerTailKeepsCommittedRows() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = SessionLedger(directory: root)
        let row = SessionRow(sessionId: "main", workspace: "PROJECT-Log-work", pane: "w1:p1",
                             tool: "codex", status: "done", asOf: Date())
        let observation = SessionObservation(row: row, pid: 1, processStart: "start", paths: [])
        try ledger.append([observation])
        let handle = try FileHandle(forWritingTo: ledger.file); try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"row\":".utf8)); try handle.close()
        #expect(try ledger.rows()["main"]?.row.status == "done")
        try ledger.append([observation])
        #expect(try ledger.rows()["main"]?.row.status == "done")
    }

    func lines(_ file: URL) throws -> Int {
        try Data(contentsOf: file).filter { $0 == 0x0A }.count
    }

    @Test func passesThatChangeNothingAppendNothing() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-main.jsonl")
        try Data(codex("main", input: 100).utf8).write(to: file)
        let directory = root.appendingPathComponent("private")
        let ledger = SessionLedger(directory: directory)
        let working = SessionProbe(runner: LogProbeRunner(status: "working", paths: [file.path]), directory: directory, home: root)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try await working.run(now: start)
        let seen = try Data(contentsOf: ledger.file)
        for pass in 1...5 {
            let now = start.addingTimeInterval(Double(pass) * 30)
            let log = try await working.run(now: now)
            // The snapshot still says when the session was last seen.
            #expect(log.sessions.first?.asOf == now)
        }
        #expect(try Data(contentsOf: ledger.file) == seen)

        let gone = SessionProbe(runner: LogProbeRunner(status: nil, paths: [file.path]), directory: directory, home: root)
        let closed = try await gone.run(now: start.addingTimeInterval(300))
        #expect(closed.sessions.first?.status == "closed")
        let afterClose = try Data(contentsOf: ledger.file)
        #expect(afterClose.count > seen.count)
        for pass in 1...5 {
            let log = try await gone.run(now: start.addingTimeInterval(300 + Double(pass) * 30))
            #expect(log.sessions.first?.status == "closed")
        }
        #expect(try Data(contentsOf: ledger.file) == afterClose)
        #expect(try ledger.rows()["main"]?.row.closedAt == start.addingTimeInterval(300))
    }

    @Test func aLedgerOfChangingSessionsStaysBounded() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-main.jsonl")
        try Data(codex("main", input: 1).utf8).write(to: file)
        let directory = root.appendingPathComponent("private")
        let ledger = SessionLedger(directory: directory)
        let probe = SessionProbe(runner: LogProbeRunner(status: "working", paths: [file.path]), directory: directory, home: root)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var most = 0
        for pass in 1...300 {
            let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
            try handle.write(contentsOf: Data(codex("main", input: 1 + pass).utf8)); try handle.close()
            let log = try await probe.run(now: start.addingTimeInterval(Double(pass) * 30))
            #expect(log.sessions.first?.tokens?.input == 1 + pass)
            most = max(most, try lines(ledger.file))
        }
        // Every pass changed the session, so each wrote; compaction keeps
        // the file to a few lines per session however long it runs.
        #expect(most <= 4 * 64 + 2)
        #expect(try ledger.rows()["main"]?.row.tokens?.input == 301)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!names.contains { $0.hasPrefix("observations-before-compaction") })
    }

    @Test func compactingABigOldLedgerKeepsItBesideTheNewOne() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        var ledger = SessionLedger(directory: root)
        ledger.keepAbove = 1024
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        for pass in 0..<300 {
            let row = SessionRow(sessionId: pass % 2 == 0 ? "main" : "side", workspace: "PROJECT-Log-work",
                                 pane: "w1:p1", tool: "codex", status: pass < 298 ? "working" : "closed",
                                 asOf: start.addingTimeInterval(Double(pass)))
            try ledger.append([SessionObservation(row: row, pid: 1, processStart: "start", paths: [])])
        }
        let before = try Data(contentsOf: ledger.file)
        let read = try ledger.read()
        #expect(read.rows.count == 2)
        try ledger.compactIfLong(read.rows, lines: read.lines)

        let kept = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("observations-before-compaction") }
        #expect(kept.count == 1)
        #expect(try kept.first.map { try Data(contentsOf: root.appendingPathComponent($0)) } == before)
        #expect(try lines(ledger.file) == 2)
        #expect(try ledger.rows() == read.rows)
        #expect(try ledger.rows()["main"]?.row.status == "closed")
    }

    @Test func replacementKeepsClaudeTotalsAndContentIsNotDecoded() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("session.jsonl").path
        let line = #"{"type":"assistant","timestamp":"2026-10-15T01:00:00Z","requestId":"request-a","message":{"id":"msg_a","model":"claude-opus-5-5","content":{"model":"PRIVATE_CANARY"},"usage":{"input_tokens":100,"output_tokens":10}}}"# + "\n"
        let data = Data(line.utf8)
        let metadata = try #require(UsageMetadata.read(data, fields: ClaudeCollector.metadataFields))
        let message = try #require(metadata["message"] as? [String: Any])
        #expect(message["content"] == nil)
        let row = SessionRow(sessionId: "main", workspace: "PROJECT-Log-work", pane: "w1:p1",
                             tool: "claude", status: "working", asOf: Date())
        let probe = SessionProbe(directory: root, home: root)
        var checkpoint = SessionCheckpoint()
        try data.write(to: URL(fileURLWithPath: path))
        let first = probe.refreshed(row, paths: [path], checkpoint: &checkpoint, rates: .bundled)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        let second = probe.refreshed(row, paths: [path], checkpoint: &checkpoint, rates: .bundled)
        #expect(first.tokens?.input == 100)
        #expect(second.tokens == first.tokens)
        #expect(!String(decoding: try JSONEncoder().encode(checkpoint), as: UTF8.self).contains("CANARY"))
    }

    @Test func realSessionChangeKeepsBothSessions() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("rollout-first.jsonl")
        let second = root.appendingPathComponent("rollout-second.jsonl")
        try Data(codex("first", input: 100).utf8).write(to: first)
        try Data(codex("second", input: 40).utf8).write(to: second)
        let directory = root.appendingPathComponent("private")
        _ = try await SessionProbe(runner: LogProbeRunner(status: "working", paths: [first.path]), directory: directory, home: root).run()
        let probe = SessionProbe(runner: LogProbeRunner(status: "working", paths: [second.path]), directory: directory, home: root)
        let changed = try await probe.run()
        #expect(changed.sessions.count == 2)
        #expect(changed.sessions.first { $0.sessionId == "first" }?.tokens?.input == 100)
        #expect(changed.sessions.first { $0.sessionId == "second" }?.tokens?.input == 40)
        #expect(changed.sessions.first { $0.sessionId == "first" }?.closedAt == nil)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("offsets.json"))
        let rebuilt = try await probe.run()
        #expect(rebuilt.sessions.first { $0.sessionId == "first" }?.tokens?.input == 100)
        #expect(rebuilt.sessions.first { $0.sessionId == "second" }?.tokens?.input == 40)
    }

    @Test func duplicateClaudeOwnerSurvivesReplacement() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a.jsonl")
        let duplicate = root.appendingPathComponent("b.jsonl")
        func data(_ id: String, _ input: Int) -> Data {
            Data("""
            {"type":"assistant","timestamp":"2026-10-15T01:00:00Z","requestId":"request-\(id)","message":{"id":"msg_\(id)","model":"claude-opus-5-5","usage":{"input_tokens":\(input),"output_tokens":10}}}

            """.utf8)
        }
        try data("original", 100).write(to: first)
        try data("original", 100).write(to: duplicate)
        let row = SessionRow(sessionId: "main", workspace: "PROJECT-Log-work", pane: "w1:p1", tool: "claude", status: "working", asOf: Date())
        let probe = SessionProbe(directory: root, home: root)
        var checkpoint = SessionCheckpoint()
        #expect(probe.refreshed(row, paths: [first.path, duplicate.path], checkpoint: &checkpoint, rates: .bundled).tokens?.input == 100)
        try data("replacement", 40).write(to: first, options: .atomic)
        let result = probe.refreshed(row, paths: [first.path, duplicate.path], checkpoint: &checkpoint, rates: .bundled)
        #expect(result.tokens?.input == 140)
        #expect(!result.stale)
    }

    @Test func integerSessionCostSurvivesMetadataDecoder() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        try Data("{\"type\":\"cost-state\",\"sessionId\":\"main\",\"totalCostUSD\":2}\n".utf8).write(to: file)
        #expect(ClaudeCollector.read(file: file, primer: root.appendingPathComponent("primer")).sessionCosts["main"] == 2)
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
