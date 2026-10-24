import Foundation
import Testing
@testable import SeatGaugeCore

@Suite struct SessionLedgerRoundThreeSolProofTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Sol proof, criterion 1: an unseen open session retains its last-seen time and is not written for time or a changed peer")
    func unseenOpenDoesNotWriteForTimeOrPeer() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("rollout-main.jsonl")
        try Data("""
        {"type":"session_meta","payload":{"id":"main","cwd":"/work/project"}}
        {"type":"turn_context","payload":{"model":"gpt-6.1-sol"}}
        {"timestamp":"2026-10-15T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":10,"total_tokens":110}}}}

        """.utf8).write(to: source)
        let directory = root.appendingPathComponent("private")
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        func probe(_ uncertain: Bool) -> SessionProbe {
            SessionProbe(runner: RoundThreeLedgerRunner(path: source.path, uncertain: uncertain), directory: directory, home: root)
        }
        _ = try await probe(false).run(now: start)
        let ledger = SessionLedger(directory: directory)
        let beforeStale = try Data(contentsOf: ledger.file)
        let first = try await probe(true).run(now: start.addingTimeInterval(30))
        #expect(first.sessions.first?.stale == true)
        #expect(first.sessions.first?.asOf == start)
        let staleBytes = try Data(contentsOf: ledger.file)
        #expect(staleBytes.count > beforeStale.count)
        for seconds: Double in [600, 1200, 3600] {
            let log = try await probe(true).run(now: start.addingTimeInterval(seconds))
            #expect(log.sessions.first?.asOf == start)
            #expect(try Data(contentsOf: ledger.file) == staleBytes)
        }
        // A closed peer changes on summarisation, but the unseen open row
        // must still stay at its last actual sighting.
        var peer = SessionRow(sessionId: "closed-peer", workspace: "PROJECT-Log-work", pane: "w1:p1",
                              tool: "codex", status: "closed", asOf: start)
        peer.closedAt = start
        try ledger.append([SessionObservation(row: peer, pid: 123,
            processStart: "Thu Oct 15 01:00:00 2026", paths: [])])
        let beforePeer = try Data(contentsOf: ledger.file)
        _ = try await probe(true).run(now: start.addingTimeInterval(7200))
        let appended = try Data(contentsOf: ledger.file).dropFirst(beforePeer.count)
        let rows = appended.split(separator: 0x0A).compactMap {
            try? JSONDecoder().decode(SessionObservation.self, from: Data($0))
        }
        #expect(rows.map(\.row.sessionId) == ["closed-peer"])
        #expect(try ledger.rows()["main"]?.row.asOf == start)
    }

    @Test("Sol proof, criterion 1: mixed sightings, closures, changes and heartbeats obey both directions of the write rule")
    func mixedPassesObeyWriteRule() async throws {
        for seed in 0..<4 {
            let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
            let directory = root.appendingPathComponent("private")
            let ledger = SessionLedger(directory: directory)
            let start = Date(timeIntervalSince1970: 1_790_000_000)
            var random = UInt64(seed + 1)
            for pass in 0..<40 {
                random = random &* 6364136223846793005 &+ 1442695040888963407
                let choice = Int(random >> 32)
                let id = ["alpha", "middle", "zulu"][choice % 3]
                let source = root.appendingPathComponent("rollout-\(id).jsonl")
                let input = (pass + 1) * 100
                try Data("""
                {"type":"session_meta","payload":{"id":"\(id)","cwd":"/work/project"}}
                {"type":"turn_context","payload":{"model":"gpt-6.1-sol"}}
                {"timestamp":"2026-10-15T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(input),"output_tokens":10,"total_tokens":\(input + 10)}}}}

                """.utf8).write(to: source)
                let runner = MatrixLedgerRunner(path: source.path, id: id, choice: choice)
                let probe = SessionProbe(runner: runner, directory: directory, home: root)
                let previous = try ledger.rows()
                let before = (try? Data(contentsOf: ledger.file)) ?? Data()
                let now = start.addingTimeInterval(Double(pass) * 137)
                let snapshot = try await probe.run(now: now)
                let after = (try? Data(contentsOf: ledger.file)) ?? Data()
                #expect(after.starts(with: before))
                let written = after.dropFirst(before.count).split(separator: 0x0A).compactMap {
                    try? JSONDecoder().decode(SessionObservation.self, from: Data($0))
                }
                #expect(Set(written.map(\.row.sessionId)).count == written.count)
                func sameProcess(_ a: SessionObservation, _ b: SessionObservation) -> Bool {
                    a.pid == b.pid && SessionProbe.start(a.processStart) == SessionProbe.start(b.processStart)
                        && a.row.pane == b.row.pane
                }
                for observation in written {
                    let old = previous[observation.row.sessionId]
                    let changed = old.map { !$0.matches(observation) } ?? true
                    let seen = observation.row.closedAt == nil && observation.row.asOf == now
                    let heartbeat = seen && old.map { now.timeIntervalSince($0.row.asOf) >= 600 } == true
                    let peer = seen && written.contains {
                        $0.row.sessionId != observation.row.sessionId && sameProcess($0, observation)
                    }
                    #expect(changed || heartbeat || peer)
                }
                for row in snapshot.sessions {
                    let old = previous[row.sessionId]
                    var comparable = row
                    if let old { comparable.asOf = old.row.asOf }
                    let changed = old.map { $0.row != comparable } ?? true
                    let seen = row.closedAt == nil && row.asOf == now
                    let heartbeat = seen && old.map { now.timeIntervalSince($0.row.asOf) >= 600 } == true
                    let peer = seen && old.map { old in
                        written.contains { $0.row.sessionId != row.sessionId && sameProcess($0, old) }
                    } == true
                    if changed || heartbeat || peer {
                        #expect(written.contains { $0.row.sessionId == row.sessionId })
                    }
                }
            }
        }
    }

    @Test("Sol proof, criterion 2: compaction above the 64-session floor preserves all 65 last rows")
    func compactionBeyondFloorPreservesRows() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = SessionLedger(directory: root)
        var expected: [String: SessionObservation] = [:]
        for pass in 0..<6 {
            var batch: [SessionObservation] = []
            for index in 0..<65 {
                let id = "session-\(index)"
                var row = SessionRow(sessionId: id, workspace: "PROJECT-Log-work", pane: "w1:p\(index)",
                                     tool: "codex", status: "working", asOf: Date(timeIntervalSince1970: Double(pass)))
                row.tokens = TokenCounts(input: pass + index)
                let observation = SessionObservation(row: row, pid: index, processStart: "start", paths: [])
                expected[id] = observation
                batch.append(observation)
            }
            try ledger.append(batch)
            let read = try ledger.read()
            #expect(read.rows == expected)
            try ledger.compactIfLong(read.rows, lines: read.lines)
            #expect(try ledger.rows() == expected)
            #expect(try ledger.read().lines <= 4 * 65)
        }
    }

    @Test("Sol proof, criterion 2: compaction preserves a complete tail committed by the append separator")
    func compactionPreservesTailSealedByAppend() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var anchor = SessionRow(sessionId: "anchor", workspace: "PROJECT-Log-work", pane: "w1:p1",
                                tool: "codex", status: "working", asOf: start)
        anchor.stale = true
        let committed = SessionObservation(row: anchor, pid: 123, processStart: "Thu Oct 15 01:00:00 2026", paths: [])
        var tail = committed
        tail.row.sessionId = "tail-session"
        tail.row.pane = "w1:p2"
        tail.pid = 456
        var results: [[String: SessionObservation]] = []
        for blockCompaction in [true, false] {
            let directory = root.appendingPathComponent(blockCompaction ? "uncompacted" : "compacted")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ledger = SessionLedger(directory: directory)
            for _ in 0..<128 { try ledger.append([committed]) }
            let handle = try FileHandle(forWritingTo: ledger.file)
            try handle.seekToEnd()
            // A torn append can leave all JSON bytes but lose the final LF.
            try handle.write(contentsOf: JSONEncoder().encode(tail))
            try handle.close()
            #expect(try ledger.read().lines == 256)
            #expect(try ledger.rows() == ["anchor": committed])
            let blocker = directory.appendingPathComponent("observations.jsonl.new")
            if blockCompaction {
                #expect(FileManager.default.createFile(atPath: blocker.path, contents: Data("occupied".utf8)))
                try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: blocker.path)
            }
            defer {
                if blockCompaction { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: blocker.path) }
            }
            let probe = SessionProbe(runner: MatrixLedgerRunner(path: "", id: "", choice: 0),
                                     directory: directory, home: root)
            _ = try await probe.run(now: start.addingTimeInterval(30))
            results.append(try ledger.rows())
        }
        #expect(results[0]["tail-session"] == tail)
        // Compaction must have the same read result as the ledger it replaces.
        #expect(results[1] == results[0])
    }

    @Test("Sol proof, criterion 3: malformed lines and a complete JSON tail without newline cannot replace committed rows")
    func malformedAndUnterminatedRowsAreIgnored() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        var ledger = SessionLedger(directory: root)
        ledger.chunk = 7
        let row = SessionRow(sessionId: "main", workspace: "PROJECT-Log-work", pane: "w1:p1",
                             tool: "codex", status: "working", asOf: Date(timeIntervalSince1970: 100))
        let observation = SessionObservation(row: row, pid: 123, processStart: "start", paths: [])
        try ledger.append([observation])
        var replacement = observation
        replacement.row.status = "closed"
        let handle = try FileHandle(forWritingTo: ledger.file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("broken\n\n".utf8))
        try handle.write(contentsOf: JSONEncoder().encode(replacement))
        try handle.close()
        #expect(try ledger.rows() == ["main": observation])
        #expect(try ledger.read().lines == 4)
    }
}

private struct RoundThreeLedgerRunner: ProcessRunning {
    let path: String
    let uncertain: Bool
    func launch(_ spec: ProcessSpec) throws -> any ProcessSession {
        let lines: [String]
        switch spec.arguments {
        case ["pane", "list"]:
            lines = [#"{"result":{"panes":[{"pane_id":"w1:p1","workspace_id":"w1","agent_status":"working"}]}}"#]
        case ["workspace", "list"]:
            lines = [#"{"result":{"workspaces":[{"workspace_id":"w1","label":"PROJECT-Log-work"}]}}"#]
        case ["pane", "process-info", "--pane", "w1:p1"]:
            lines = uncertain ? [#"{"result":{}}"#]
                : [#"{"result":{"process_info":{"foreground_processes":[{"argv":["codex","-m","gpt-6.1-sol"],"pid":123}]}}}"#]
        default:
            if spec.executable.lastPathComponent == "ps" { lines = ["Thu Oct 15 01:00:00 2026"] }
            else if spec.executable.lastPathComponent == "lsof" { lines = ["n" + path] }
            else { lines = [] }
        }
        return RoundThreeLedgerSession(lines: lines)
    }
}

private struct RoundThreeLedgerSession: ProcessSession {
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

private struct MatrixLedgerRunner: ProcessRunning {
    let path: String
    let id: String
    let choice: Int
    var present: Bool { choice % 7 != 0 }
    var uncertain: Bool { choice % 5 == 0 }
    var pid: Int { choice % 11 == 0 ? 456 : 123 }
    func launch(_ spec: ProcessSpec) throws -> any ProcessSession {
        let lines: [String]
        switch spec.arguments {
        case ["pane", "list"]:
            let statuses = ["working", "done", "idle"]
            lines = present ? ["{\"result\":{\"panes\":[{\"pane_id\":\"w1:p1\",\"workspace_id\":\"w1\",\"agent_status\":\"\(statuses[choice % 3])\",\"agent_session\":{\"kind\":\"id\",\"value\":\"\(id)\"}}]}}"]
                : [#"{"result":{"panes":[]}}"#]
        case ["workspace", "list"]:
            lines = [#"{"result":{"workspaces":[{"workspace_id":"w1","label":"PROJECT-Log-work"}]}}"#]
        case ["pane", "process-info", "--pane", "w1:p1"]:
            lines = uncertain ? [#"{"result":{}}"#]
                : ["{\"result\":{\"process_info\":{\"foreground_processes\":[{\"argv\":[\"codex\",\"-m\",\"gpt-6.1-sol\"],\"pid\":\(pid)}]}}}"]
        default:
            if spec.executable.lastPathComponent == "ps" {
                lines = spec.arguments.contains(String(pid)) ? ["Thu Oct 15 01:00:00 2026"] : []
            } else if spec.executable.lastPathComponent == "lsof" { lines = choice % 4 == 0 ? [] : ["n" + path] }
            else { lines = [] }
        }
        return RoundThreeLedgerSession(lines: lines)
    }
}
