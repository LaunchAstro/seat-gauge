import Foundation
import Testing

import SeatGaugeCore
import SeatGaugeTestSupport

/// Every Claude seat runs with `--strict-mcp-config`. The likeliest cause of
/// macOS's app management notice is an MCP server a Claude login declares,
/// started by the Claude seat the app polls; `--strict-mcp-config` with no
/// `--mcp-config` starts none.
@Suite struct StrictMCPConfigTests {

    static let flag = "--strict-mcp-config"
    static let oldClaudeArguments = ["claude", "-p", "--input-format", "stream-json",
                                     "--output-format", "stream-json", "--verbose",
                                     "--model", "haiku", "--max-turns", "1"]
    static let now = Date(timeIntervalSince1970: 1_758_600_000)

    static func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seat-gauge-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func write(_ contents: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func seats(in root: URL) throws -> [Seat] {
        let token = try write("not-a-real-token-mcp-0123456789", to: root.appendingPathComponent("personal.token"))
        return [
            Seat(id: SeatID(rawValue: "work"), label: "Work",
                 kind: .claude(profileDir: root.appendingPathComponent("work", isDirectory: true))),
            Seat(id: SeatID(rawValue: "team"), label: "Team",
                 kind: .claude(profileDir: root.appendingPathComponent("team", isDirectory: true))),
            Seat(id: SeatID(rawValue: "personal"), label: "Personal",
                 kind: .claude(profileDir: root.appendingPathComponent("personal", isDirectory: true)),
                 tokenFile: token),
            Seat(id: SeatID(rawValue: "codex"), label: "Codex", kind: .codex),
        ]
    }

    /// What the fetcher hands the runner, and what it writes, for one seat.
    static func recorded(_ seat: Seat, home: URL,
                         replies: [[String]] = []) async -> (runner: ScriptedRunner, fetched: Fetched) {
        let runner = ScriptedRunner(replies: replies)
        let fetcher: any SeatFetching
        switch seat.kind {
        case .claude:
            fetcher = ClaudeFetcher(runner: runner, primer: home, timeout: .milliseconds(200))
        case .codex:
            fetcher = CodexFetcher(runner: runner, timeout: .milliseconds(200),
                                   authFile: home.appendingPathComponent("auth.json"))
        }
        return (runner, await fetcher.fetch(seat, now: now, last: nil))
    }

    /// The two real-CLI cases launch the installed `claude` and `codex` and
    /// start an MCP script of their own, so they run only when asked for with
    /// `SEATGAUGE_INTEGRATION=1`. The gate runs without them.
    static let integration = ProcessInfo.processInfo.environment["SEATGAUGE_INTEGRATION"] == "1"

    /// The real CLI on the inherited `PATH`, when the integration cases are on.
    static func binary(_ name: String) -> URL? {
        guard integration else { return nil }
        return (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// A stdio MCP server that only leaves a mark that it ran.
    static func marker(in root: URL) throws -> (script: URL, mark: URL) {
        let mark = root.appendingPathComponent("marker-ran")
        let script = try write("#!/bin/sh\necho ran >> '\(mark.path)'\nsleep 5\n",
                               to: root.appendingPathComponent("marker.sh"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, mark)
    }

    /// Stdout as whole lines, filled from the pipe's own queue.
    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var rest = Data()
        private var whole: [String] = []

        func take(_ data: Data) {
            lock.withLock {
                rest.append(data)
                while let at = rest.firstIndex(of: 0x0a) {
                    whole.append(String(decoding: rest[rest.startIndex..<at], as: UTF8.self))
                    rest = rest[rest.index(after: at)...]
                }
            }
        }

        var all: [String] { lock.withLock { whole } }
    }

    /// What a real run printed, and its exit status: nil when the deadline stopped it.
    struct RealRun {
        let lines: [String]
        let status: Int32?
    }

    /// The spec the fetcher handed the runner, run for real with a scratch home, no key of any kind,
    /// and `extra` on top. `lines` are sent, stdin closes once `done` holds,
    /// and the run returns once the CLI has ended and a second has passed.
    static func runForReal(_ spec: ProcessSpec, home: URL, extra: [String: String], lines: [String],
                           done: ([String]) -> Bool) async throws -> RealRun {
        var environment = spec.environment
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", SeatToken.variable,
                    "OPENAI_API_KEY", "CODEX_API_KEY"] { environment.removeValue(forKey: key) }
        environment["HOME"] = home.path
        environment.merge(extra) { _, new in new }
        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.environment = environment
        process.currentDirectoryURL = home
        let input = Pipe(), output = Pipe(), seen = Lines()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { seen.take(data) }
        }
        signal(SIGPIPE, SIG_IGN)
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        for line in lines { try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8)) }
        let deadline = ContinuousClock.now + .seconds(30)
        while process.isRunning, !done(seen.all), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try input.fileHandleForWriting.close()
        while process.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        let status = process.isRunning ? nil : process.terminationStatus
        try await Task.sleep(for: .seconds(1))
        return RealRun(lines: seen.all, status: status)
    }

    // MARK: - The real Claude starts no server the login declares

    @Test(.enabled(if: StrictMCPConfigTests.binary("claude") != nil,
                   "launches the real claude: set SEATGAUGE_INTEGRATION=1 with claude on PATH to run it"))
    func theRealClaudeStartsNoMCPServerTheLoginDeclares() async throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("claude-config", isDirectory: true)
        let (script, mark) = try Self.marker(in: config)
        try Self.write(#"{"hasCompletedOnboarding":true,"mcpServers":{"marker":{"command":"\#(script.path)","args":[]}}}"#,
                       to: config.appendingPathComponent(".claude.json"))
        let seat = Seat(id: SeatID(rawValue: "team"), label: "Team", kind: .claude(profileDir: config))
        let recorded = await Self.recorded(seat, home: root).runner
        let spec = try #require(recorded.launched.first)
        // Only the initialize line: the question after it is never sent, so no turn runs.
        let first = try #require(recorded.sent.first)
        let flagless = ProcessSpec(executable: spec.executable, arguments: spec.arguments.filter { ![Self.flag, "--safe-mode"].contains($0) },
                                   environment: spec.environment, currentDirectory: spec.currentDirectory)
        let extra = ["DISABLE_AUTOUPDATER": "1"]

        // Claude Code 2.1.283 starts servers after it answers initialize, and
        // exits first when its input closes at once. Both runs hold the input
        // open the same way: until the marker appears, or for the hold.
        let hold = Duration.seconds(8)
        let start = ContinuousClock.now
        let control = try await Self.runForReal(flagless, home: root, extra: extra, lines: [first]) { _ in
            FileManager.default.fileExists(atPath: mark.path) || ContinuousClock.now - start > hold
        }
        #expect(FileManager.default.fileExists(atPath: mark.path),
                "without the flag claude started no marker, so its absence below would prove nothing")
        try? FileManager.default.removeItem(at: mark)
        let again = ContinuousClock.now
        let run = try await Self.runForReal(spec, home: root, extra: extra, lines: [first]) { _ in
            FileManager.default.fileExists(atPath: mark.path) || ContinuousClock.now - again > hold
        }
        #expect(!FileManager.default.fileExists(atPath: mark.path), "claude started the login's MCP server")

        for (name, result) in [("without the flag", control), ("with the flag", run)] {
            #expect(result.status == 0, "claude \(name) ended with \(String(describing: result.status)); nil is the deadline")
            #expect(result.lines.contains { $0.contains(#""request_id":"1""#) && $0.contains("control_response") },
                    "claude \(name) never answered initialize, so it never reached startup")
            #expect(result.lines.contains { $0.contains(#""tokenSource":"none""#) },
                    "claude \(name) found a login in the scratch config, so a turn could spend")
            #expect(!result.lines.contains { $0.contains(#""type":"assistant""#) || $0.contains(#""type":"result""#) },
                    "claude \(name) ran a model turn")
        }
    }

    // MARK: - The real Codex starts no server in the fetcher's exchange

    @Test(.enabled(if: StrictMCPConfigTests.binary("codex") != nil,
                   "launches the real codex: set SEATGAUGE_INTEGRATION=1 with codex on PATH to run it"))
    func theRealCodexStartsNoMCPServerInTheFetchersExchange() async throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let (script, mark) = try Self.marker(in: codexHome)
        try Self.write("[mcp_servers.marker]\ncommand = \"\(script.path)\"\n",
                       to: codexHome.appendingPathComponent("config.toml"))
        let seat = Seat(id: SeatID(rawValue: "codex"), label: "Codex", kind: .codex)
        let recorded = await Self.recorded(seat, home: root).runner
        let spec = try #require(recorded.launched.first)
        #expect(recorded.sent.count == 3)
        let extra = ["CODEX_HOME": codexHome.path]
        let status = #"{"jsonrpc":"2.0","id":3,"method":"mcpServerStatus/list","params":{}}"#

        _ = try await Self.runForReal(spec, home: root, extra: extra,
                                      lines: Array(recorded.sent.prefix(2)) + [status]) { _ in
            FileManager.default.fileExists(atPath: mark.path)
        }
        #expect(FileManager.default.fileExists(atPath: mark.path),
                "codex asked for its servers started no marker, so its absence below would prove nothing")
        try? FileManager.default.removeItem(at: mark)
        let run = try await Self.runForReal(spec, home: root, extra: extra, lines: recorded.sent) { lines in
            lines.contains { $0.contains(#""id":2"#) }
        }
        #expect(!FileManager.default.fileExists(atPath: mark.path), "codex started the login's MCP server")
        #expect(run.status == 0, "codex ended with \(String(describing: run.status)); nil is the deadline")
        #expect(run.lines.contains { $0.hasPrefix(#"{"id":1,"result""#) }, "codex never answered initialize")
        #expect(run.lines.contains { $0.contains(#""id":2"#) && $0.contains(#""error""#) },
                "codex read rate limits from the scratch home, so it found a login there")
    }

    // MARK: - Every Claude seat carries the flag

    @Test func everyClaudeSeatIsLaunchedWithStrictMCPConfig() async throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        for seat in try Self.seats(in: root) {
            let spec = try #require(await Self.recorded(seat, home: root).runner.launched.first)
            if case .claude = seat.kind {
                #expect(spec.arguments.contains(Self.flag), "\(seat.id.rawValue) has no \(Self.flag)")
                #expect(!spec.arguments.contains("--mcp-config"))
            } else {
                #expect(spec.arguments.prefix(2) == ["codex", "app-server"])
                #expect(!spec.arguments.contains(Self.flag))
            }
        }
    }

    // MARK: - A launch and three polls

    @Test func aLaunchAndThreePollsLaunchNoClaudeWithoutTheFlag() async throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let seats = try Self.seats(in: root)
        let runner = ScriptedRunner()
        for _ in 0..<4 {
            for seat in seats {
                _ = await seatFetcher(for: seat, runner: runner, timeout: .milliseconds(50))
                    .fetch(seat, now: Self.now, last: nil)
            }
        }
        let claude = runner.launched.filter { $0.arguments.first == "claude" }
        #expect(runner.launched.count == 16)
        #expect(claude.count == 12)
        #expect(claude.allSatisfy { $0.arguments.contains(Self.flag) })
    }

    // MARK: - The recipe and its reading are unchanged

    @Test func theRecipeAndItsReadingAreUnchanged() async throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = try Fixture.lines("work")
        let result = try #require(lines.firstIndex { $0.contains(#""type":"result""#) })
        let replies = [[], Array(lines[...result]), Array(lines[lines.index(after: result)...])]

        // A token seat, the one seat that still takes a turn.
        let token = root.appendingPathComponent("work.token")
        try Data("not-a-real-token".utf8).write(to: token)
        let seat = Seat(id: SeatID(rawValue: "work"), label: "Work",
                        kind: .claude(profileDir: root.appendingPathComponent("work", isDirectory: true)),
                        tokenFile: token)
        let run = await Self.recorded(seat, home: root, replies: replies)
        let spec = try #require(run.runner.launched.first)
        #expect(spec.arguments == Array(Self.oldClaudeArguments.prefix(7)) + [Self.flag, "--safe-mode"]
                + ["--model", "haiku", "--max-turns", "1"])
        #expect(run.runner.sent == [
            #"{"type":"control_request","request_id":"1","request":{"subtype":"initialize"}}"#,
            #"{"type":"user","message":{"role":"user","content":"Reply with the single word ok."}}"#,
            #"{"type":"control_request","request_id":"2","request":{"subtype":"get_usage","skip_behaviors":true}}"#,
        ])
        guard case let .live(windows, plan) = ClaudeUsageParser.windows(from: lines, requestID: "2"),
              case let .live(reading) = run.fetched.state else {
            Issue.record("the work fixture no longer reads live")
            return
        }
        #expect(reading.windows == windows)
        #expect(reading.plan == plan)

        let codex = await Self.recorded(Seat(id: SeatID(rawValue: "codex"), label: "Codex", kind: .codex),
                                        home: root)
        #expect(codex.runner.launched.first?.arguments.prefix(2) == ["codex", "app-server"])
    }

    // MARK: - Fails closed

    @Test func failsClosedWithNoConfigToRead() async throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = Seat(id: SeatID(rawValue: "team"), label: "Team",
                           kind: .claude(profileDir: root.appendingPathComponent("not-there", isDirectory: true)))
        let broken = root.appendingPathComponent("broken", isDirectory: true)
        try Self.write("{ not json", to: broken.appendingPathComponent(".claude.json"))
        let malformed = Seat(id: SeatID(rawValue: "personal"), label: "Personal", kind: .claude(profileDir: broken))
        for seat in [missing, malformed] {
            let spec = try #require(await Self.recorded(seat, home: root).runner.launched.first)
            #expect(spec.arguments.contains(Self.flag), "\(seat.id.rawValue) has no \(Self.flag)")
        }
        let tokenless = Seat(id: SeatID(rawValue: "personal"), label: "Personal", kind: .claude(profileDir: broken),
                             tokenFile: root.appendingPathComponent("no-such.token"))
        let run = await Self.recorded(tokenless, home: root)
        #expect(run.runner.launched.isEmpty)
        guard case .unreadable = run.fetched.state else {
            Issue.record("a seat with no token read as \(run.fetched.state)")
            return
        }
    }
}
