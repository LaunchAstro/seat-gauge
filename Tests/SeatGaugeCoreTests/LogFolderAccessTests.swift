import Foundation
import Testing
@testable import SeatGaugeCore

/// Issue #74: after a reinstall macOS asks again whether Seat Gauge may open
/// the Desktop folder, and until the owner answers, every git call the Log
/// probe makes in a session there waits.
@Suite struct LogFolderAccessTests {
    private func rollout(_ id: String) -> Data {
        Data("""
        {"type":"session_meta","payload":{"id":"\(id)","cwd":"/work/\(id)"}}
        {"type":"turn_context","payload":{"model":"gpt-6.1-sol"}}
        {"timestamp":"2026-10-15T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":10,"total_tokens":110}}}}

        """.utf8)
    }

    @Test func aGitCallMacOSHoldsEndsQuicklyAndTheRestOfThePassSkipsGit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for id in ["one", "two"] { try rollout(id).write(to: root.appendingPathComponent("rollout-\(id).jsonl")) }
        let directory = root.appendingPathComponent("private")
        let start = Date(timeIntervalSince1970: 1_790_000_000)

        let allowed = FolderAccessRunner(home: root, blocked: false)
        let first = try await SessionProbe(runner: allowed, directory: directory, home: root).run(now: start)
        #expect(first.sessions.map(\.branch) == ["main", "main"])
        #expect(first.problems.isEmpty)

        let held = FolderAccessRunner(home: root, blocked: true)
        let second = try await SessionProbe(runner: held, directory: directory, home: root)
            .run(now: start.addingTimeInterval(30))
        // One short wait for the whole pass, however many panes sit there.
        #expect(held.gitTimeouts.count == 1)
        #expect(held.gitTimeouts.allSatisfy { $0 <= .seconds(2) })
        // A branch git could not be asked for this pass is the one last seen.
        #expect(second.sessions.map(\.branch) == ["main", "main"])
        let problem = try #require(second.problems.values.first)
        #expect(problem.contains("Files and Folders"))
        #expect(!problem.contains("/work"))
        #expect(!problem.contains(root.path))

        let again = FolderAccessRunner(home: root, blocked: false)
        let third = try await SessionProbe(runner: again, directory: directory, home: root)
            .run(now: start.addingTimeInterval(60))
        // A branch and a remote read for each of the two folders.
        #expect(again.gitTimeouts.count == 4)
        #expect(third.problems.isEmpty)
    }

    @Test func aLocalProbePastItsLimitNamesFolderAccessNotTheHelper() async {
        let late = TimedOutRunner()
        let here = await MachineProber(runner: late, environment: [:]).readLog(.here)
        guard case let .failure(local) = here else { Issue.record("a timed-out probe read as an answer"); return }
        #expect(local.reason.contains("Files and Folders"))
        #expect(!local.reason.contains("CLI helper"))

        let studio = Machine(id: "studio", label: "Studio", ssh: "studio")
        let remote = await MachineProber(runner: late, environment: [:]).readLog(studio)
        guard case let .failure(far) = remote else { Issue.record("a timed-out probe read as an answer"); return }
        // ssh shows no folder prompt, so the far machine keeps the helper line.
        #expect(far.reason.contains("CLI helper"))
    }

    /// Most strangers have no herdr. The local line then says so, because the
    /// helper ships inside the app and is not what is missing.
    @Test func aMacWithoutHerdrSaysHerdrIsMissingNotTheHelper() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        // The probe ran and printed nothing, as it does when herdr is not there.
        let silent = AnswerRunner(line: "")

        let bare = await MachineProber(runner: silent, environment: [:], home: home).readLog(.here)
        guard case let .failure(missing) = bare else { Issue.record("an empty answer read as a log"); return }
        #expect(missing.reason.contains("herdr was not found"))
        #expect(missing.reason.contains("~/.local/bin/herdr"))
        #expect(!missing.reason.contains("CLI helper"))
        #expect(!missing.reason.contains(home.path))

        // With herdr in place, the same silence is not herdr's fault.
        let herdr = home.appendingPathComponent(".local/bin/herdr")
        try FileManager.default.createDirectory(at: herdr.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: herdr)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: herdr.path)
        let present = await MachineProber(runner: silent, environment: [:], home: home).readLog(.here)
        guard case let .failure(helper) = present else { Issue.record("an empty answer read as a log"); return }
        #expect(helper.reason.contains("CLI helper"))

        // A far machine's herdr is not looked for here: its line stays the helper's.
        let studio = Machine(id: "studio", label: "Studio", ssh: "studio")
        let bareHome = home.appendingPathComponent("elsewhere")
        let remote = await MachineProber(runner: silent, environment: [:], home: bareHome).readLog(studio)
        guard case let .failure(far) = remote else { Issue.record("an empty answer read as a log"); return }
        #expect(far.reason.contains("CLI helper"))
    }

    @Test func aProblemTheProbeReportsReachesTheLogTab() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let row = SessionRow(sessionId: "main", workspace: "PROJECT-Log-work", pane: "w1:p1",
                             tool: "codex", status: "working", asOf: Date())
        let answer = SessionLogFile(updated: Date(), sessions: [row], problems: ["git": "folder access line"])
        let text = String(decoding: try SessionLogFile.encoder().encode(answer), as: UTF8.self)
        let config = Config(seats: [], pollMinutes: 5, machines: [.here])
        let monitor = SessionLogMonitor(prober: MachineProber(runner: AnswerRunner(line: text), environment: [:]),
                                        file: root.appendingPathComponent("log.json"), config: { config })
        let log = await monitor.read()
        #expect(log.problems[Machine.here.id] == "folder access line")
        #expect(log.sessions.count == 1)
        #expect(log.sessions.first?.stale == false)
    }
}

/// Two panes, each in its own folder. `blocked` is macOS holding those
/// folders: git answers only when its timeout runs out.
private final class FolderAccessRunner: ProcessRunning, @unchecked Sendable {
    let home: URL
    let blocked: Bool
    private let lock = NSLock()
    private var timeouts: [Duration] = []
    var gitTimeouts: [Duration] { lock.withLock { timeouts } }

    init(home: URL, blocked: Bool) { self.home = home; self.blocked = blocked }

    func launch(_ spec: ProcessSpec) throws -> any ProcessSession {
        let args = spec.arguments
        let panes = ["one", "two"]
        switch spec.executable.lastPathComponent {
        case "git":
            lock.withLock { timeouts.append(spec.timeout) }
            if blocked { return FolderAccessSession(lines: [], failure: ProcessFailure.timedOut(after: spec.timeout)) }
            return FolderAccessSession(lines: ["main"])
        case "ps": return FolderAccessSession(lines: ["Thu Oct 15 01:00:00 2026"])
        case "lsof":
            let pid = Int(args[args.firstIndex(of: "-p").map { $0 + 1 } ?? 0]) ?? 0
            let id = panes[(pid - 101) % panes.count]
            return FolderAccessSession(lines: ["n" + home.appendingPathComponent("rollout-\(id).jsonl").path])
        default: break
        }
        if args == ["pane", "list"] {
            let listed = panes.enumerated().map { index, id in
                ["pane_id": "w1:p\(index + 1)", "workspace_id": "w1", "agent_status": "working", "cwd": "/work/\(id)"]
            }
            return FolderAccessSession(lines: [Self.json(["result": ["panes": listed]])])
        }
        if args == ["workspace", "list"] {
            return FolderAccessSession(lines: [#"{"result":{"workspaces":[{"workspace_id":"w1","label":"PROJECT-Log-work"}]}}"#])
        }
        if args.starts(with: ["pane", "process-info", "--pane"]), let pane = args.last,
           let index = Int(pane.dropFirst("w1:p".count)) {
            let process: [String: Any] = ["argv": ["codex"], "pid": 100 + index, "cwd": "/work/\(panes[index - 1])"]
            return FolderAccessSession(lines: [Self.json(["result": ["process_info": ["foreground_processes": [process]]]])])
        }
        return FolderAccessSession(lines: [])
    }

    static func json(_ object: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }
}

/// A probe that never answered before its 90 s ran out.
private struct TimedOutRunner: ProcessRunning {
    func launch(_ spec: ProcessSpec) throws -> any ProcessSession {
        FolderAccessSession(lines: [], failure: ProcessFailure.timedOut(after: spec.timeout))
    }
}

private struct AnswerRunner: ProcessRunning {
    let line: String
    func launch(_ spec: ProcessSpec) throws -> any ProcessSession { FolderAccessSession(lines: [line]) }
}

private struct FolderAccessSession: ProcessSession {
    let stdoutLines: AsyncThrowingStream<String, Error>
    init(lines: [String], failure: ProcessFailure? = nil) {
        stdoutLines = AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish(throwing: failure)
        }
    }
    func send(_ line: String) throws {}
    func closeInput() {}
    func terminate() {}
}
