import Foundation
import Testing
@testable import SeatGaugeCore

/// Issue #57 split `SessionProbe.collect` into named steps. Every pass of a
/// scenario that opens, supersedes, holds git, loses a pane, closes and
/// retires sessions keeps the ledger's privacy: nothing private reaches the
/// rows, and the private files stay owner-only.
@Suite struct SessionProbeStepsTests {
    @Test func everyStepKeepsPathsProcessesAndArgumentsOutOfTheRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func codex(_ id: String, _ input: Int) -> Data {
            Data("""
            {"type":"session_meta","payload":{"id":"\(id)","cwd":"/work/project"}}
            {"type":"turn_context","payload":{"model":"gpt-6.1-sol"}}
            {"timestamp":"2026-10-15T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(input),"output_tokens":10,"total_tokens":\(input + 10)}}}}

            """.utf8)
        }
        let claudeDir = root.appendingPathComponent(".claude/projects/x")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let claude = claudeDir.appendingPathComponent("cl-1.jsonl")
        try Data(#"{"type":"assistant","timestamp":"2026-10-15T01:00:00Z","requestId":"r","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":7,"output_tokens":3}}}"#.utf8 + [0x0A]).write(to: claude)
        let a = root.appendingPathComponent("rollout-a.jsonl"); try codex("alpha", 100).write(to: a)
        let b = root.appendingPathComponent("rollout-b.jsonl"); try codex("beta", 40).write(to: b)
        let directory = root.appendingPathComponent("private")
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var statuses: Set<String> = []
        let scenes: [StepsScene] = [
            .init(p1: .paths([]), p2: .claude(claude.path), status: "working"),
            .init(p1: .paths([a.path]), p2: .claude(claude.path), status: "working"),
            .init(p1: .paths([a.path]), p2: .claude(claude.path), status: "done", git: .held),
            .init(p1: .paths([a.path, b.path]), p2: .gone, status: "done"),
            .init(p1: .uncertain, p2: .gone, status: "working"),
            .init(p1: .paths([b.path]), p2: .gone, status: "working", reported: "beta"),
            .init(p1: .gone, p2: .gone, status: "working"),
            .init(p1: .gone, p2: .gone, status: "working"),
        ]
        for (index, scene) in scenes.enumerated() {
            let now = start.addingTimeInterval(Double(index) * 300 + (index == 7 ? 8 * 86_400 : 0))
            if index == 3 {
                let handle = try FileHandle(forWritingTo: a); try handle.seekToEnd()
                try handle.write(contentsOf: codex("alpha", 200)); try handle.close()
            }
            let log = try await SessionProbe(runner: StepsRunner(scene: scene, home: root), directory: directory, home: root)
                .run(now: now)
            let text = String(decoding: try SessionLogFile.encoder().encode(log), as: UTF8.self)
            // A session id may be a `process:` placeholder, as before the split;
            // paths, folders and arguments never appear.
            for secret in [root.path, "rollout-", ".jsonl", "PRIVATE", "/work/"] {
                #expect(!text.contains(secret), "pass \(index) published \(secret)")
            }
            statuses.formUnion(log.sessions.map(\.status))
            let ledger = try String(contentsOf: directory.appendingPathComponent("observations.jsonl"), encoding: .utf8)
            if index == 1 { #expect(ledger.contains("rollout-a.jsonl")) }
            for (name, mode) in [("", 0o700), ("observations.jsonl", 0o600), ("offsets.json", 0o600)] {
                let path = name.isEmpty ? directory.path : directory.appendingPathComponent(name).path
                let found = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
                #expect(found.map { $0 & 0o777 } == mode, "pass \(index): \(name) is not owner-only")
            }
        }
        #expect(statuses.isSuperset(of: ["working", "done", "closed"]))
    }
}

private struct StepsScene: Sendable {
    enum Pane: Sendable { case paths([String]), claude(String), uncertain, gone }
    enum Git: Sendable { case answer, held }
    var p1: Pane; var p2: Pane; var status: String; var git: Git = .answer; var reported: String? = nil
}

private struct StepsRunner: ProcessRunning {
    let scene: StepsScene; let home: URL
    func launch(_ spec: ProcessSpec) throws -> any ProcessSession {
        let args = spec.arguments
        func json(_ o: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self) }
        switch spec.executable.lastPathComponent {
        case "git": return scene.git == .held ? StepsSession([], ProcessFailure.timedOut(after: spec.timeout)) : StepsSession(["main"])
        case "ps":
            let pid = args[1]
            return StepsSession([pid == "200" ? "Thu Oct 15 02:00:00 2026" : "Thu Oct 15 01:00:00 2026"])
        case "lsof":
            let pid = args[args.firstIndex(of: "-p")! + 1]
            if pid == "48213", case let .paths(p) = scene.p1 { return StepsSession(p.map { "n" + $0 }) }
            return StepsSession([])
        default: break
        }
        if args == ["pane", "list"] {
            var panes: [[String: Any]] = []
            if case .gone = scene.p1 {} else {
                var p: [String: Any] = ["pane_id": "w1:p1", "workspace_id": "w1", "agent_status": scene.status, "cwd": "/work/one"]
                if let r = scene.reported { p["agent_session"] = ["kind": "id", "value": r] }
                panes.append(p)
            }
            if case let .claude(path) = scene.p2 {
                panes.append(["pane_id": "w1:p2", "workspace_id": "w2", "agent_status": "working", "cwd": "/work/two",
                              "agent_session": ["kind": "path", "value": path]])
            }
            return StepsSession([json(["result": ["panes": panes]])])
        }
        if args == ["workspace", "list"] {
            return StepsSession([json(["result": ["workspaces": [["workspace_id": "w1", "label": "PROJECT-Log-work"], ["workspace_id": "w2", "label": "solo"]]]])])
        }
        if args == ["pane", "process-info", "--pane", "w1:p1"] {
            if case .uncertain = scene.p1 { throw ProcessFailure("no answer") }
            return StepsSession([json(["result": ["process_info": ["foreground_processes": [["argv": ["codex", "-m", "gpt-6.1-sol", "PRIVATE"], "pid": 48213]]]]])])
        }
        if args == ["pane", "process-info", "--pane", "w1:p2"] {
            return StepsSession([json(["result": ["process_info": ["foreground_processes": [["argv": ["claude", "--effort", "high"], "pid": 200]]]]])])
        }
        return StepsSession([])
    }
}

private struct StepsSession: ProcessSession {
    let stdoutLines: AsyncThrowingStream<String, Error>
    init(_ lines: [String], _ failure: (any Error)? = nil) {
        stdoutLines = AsyncThrowingStream { c in for l in lines { c.yield(l) }; c.finish(throwing: failure) }
    }
    func send(_ line: String) throws {}
    func closeInput() {}
    func terminate() {}
}
