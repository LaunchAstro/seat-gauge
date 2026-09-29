import Foundation
import Testing

@testable import SeatGaugeCore
import SeatGaugeTestSupport

/// A CLI child starts with a deliberate environment, and the poll log keeps
/// seat names and headroom private.
@Suite struct ChildEnvironmentTests {

    static let planted = [
        "ANTHROPIC_API_KEY": "planted-anthropic", "OPENAI_API_KEY": "planted-openai",
        "CLAUDE_CONFIG_DIR": "/planted/claude", "CLAUDE_CODE_OAUTH_TOKEN": "planted-token",
        "AWS_SECRET_ACCESS_KEY": "planted-aws", "CODEX_HOME": "/planted/codex",
    ]

    /// A stand-in CLI on a PATH of its own: it prints its environment, then
    /// answers the recipe's requests as the real CLI would, one per line in.
    static func stub(_ name: String, in folder: URL, answers: [String]) throws {
        let replies = answers.map { "read line; echo '\($0)'" }.joined(separator: "\n")
        let script = "#!/bin/sh\nenv | sed 's/^/ENV /'\n\(replies)\n"
        let file = folder.appendingPathComponent(name)
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    static func variables(_ lines: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for line in lines where line.hasPrefix("ENV ") {
            let pair = line.dropFirst(4).split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { out[pair[0]] = pair[1] }
        }
        return out
    }

    @Test func aKeyThePanelWasLaunchedWithNeverReachesAChild() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.stub("claude", in: folder, answers: [
            #"{"type":"control_response","response":{"request_id":"1"}}"#,
            #"{"type":"result"}"#,
            #"{"type":"control_response","response":{"request_id":"2"}}"#,
        ])
        try Self.stub("codex", in: folder, answers: ["{}", "{}", #"{"id":2}"#])
        var parent = Self.planted
        parent["PATH"] = folder.path + ":/usr/bin:/bin"
        parent["HOME"] = folder.path
        parent["LANG"] = "en_AU.UTF-8"

        let profile = folder.appendingPathComponent("profile")
        let claude = Seat(id: SeatID(rawValue: "work"), label: "Work", kind: .claude(profileDir: profile))
        let codex = Seat(id: SeatID(rawValue: "codex"), label: "Codex", kind: .codex)
        let claudeRun = await ClaudeFetcher(primer: folder, timeout: .seconds(10), parent: parent)
            .fetch(claude, now: Date(), last: nil)
        let codexRun = await CodexFetcher(timeout: .seconds(10), authFile: folder.appendingPathComponent("auth.json"),
                                          primer: folder, parent: parent)
            .fetch(codex, now: Date(), last: nil)

        let claudeSaw = Self.variables(claudeRun.lines)
        let codexSaw = Self.variables(codexRun.lines)
        #expect(claudeSaw["HOME"] == folder.path, "the stub ran and printed what it was given")
        #expect(codexSaw["HOME"] == folder.path)
        for key in ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "AWS_SECRET_ACCESS_KEY", "CLAUDE_CODE_OAUTH_TOKEN"] {
            #expect(claudeSaw[key] == nil, "\(key) reached claude")
            #expect(codexSaw[key] == nil, "\(key) reached codex")
        }
        // Each CLI gets its own: the seat's profile, never the one exported,
        // and Codex's home, never Claude's.
        #expect(claudeSaw["CLAUDE_CONFIG_DIR"] == profile.path)
        #expect(claudeSaw["CODEX_HOME"] == nil)
        #expect(codexSaw["CODEX_HOME"] == "/planted/codex")
        #expect(codexSaw["CLAUDE_CONFIG_DIR"] == nil)
        #expect(claudeSaw["LANG"] == "en_AU.UTF-8")
    }

    @Test func theChildEnvironmentIsTheAllowlistAndWhatTheFetcherSets() {
        let parent = Self.planted.merging(["PATH": "/bin", "HOME": "/h", "USER": "u", "TERM_PROGRAM": "x"]) { $1 }
        let made = ChildEnvironment.make(from: parent, setting: ["CLAUDE_CONFIG_DIR": "/seat"])
        #expect(made == ["PATH": "/bin", "HOME": "/h", "USER": "u", "CLAUDE_CONFIG_DIR": "/seat"])
    }

    /// The spec each fetcher launches, from a runner that spawns nothing.
    static func spec(_ seat: Seat) async throws -> ProcessSpec {
        let runner = ScriptedRunner()
        let folder = URL(fileURLWithPath: "/tmp/seat-gauge-spec")
        switch seat.kind {
        case .claude:
            _ = await ClaudeFetcher(runner: runner, primer: folder, timeout: .milliseconds(50), parent: planted)
                .fetch(seat, now: Date(), last: nil)
        case .codex:
            _ = await CodexFetcher(runner: runner, timeout: .milliseconds(50),
                                   authFile: folder.appendingPathComponent("auth.json"),
                                   primer: FileManager.default.temporaryDirectory, parent: planted)
                .fetch(seat, now: Date(), last: nil)
        }
        return try #require(runner.launched.first)
    }

    static let claudeSeat = Seat(id: SeatID(rawValue: "work"), label: "Work",
                                 kind: .claude(profileDir: URL(fileURLWithPath: "/tmp/seat-gauge-profile")))
    static let codexSeat = Seat(id: SeatID(rawValue: "codex"), label: "Codex", kind: .codex)

    @Test func aClaudePollNeverUpdatesTheCLI() async throws {
        #expect(try await Self.spec(Self.claudeSeat).environment["DISABLE_AUTOUPDATER"] == "1")
    }

    @Test func aClaudePollLoadsNoneOfTheLoginsHooksOrPlugins() async throws {
        let spec = try await Self.spec(Self.claudeSeat)
        #expect(spec.arguments.contains("--safe-mode"))
        // Safe mode is not bare mode, which would refuse the seat's own login.
        #expect(!spec.arguments.contains("--bare"))
        #expect(spec.environment["CLAUDE_CONFIG_DIR"] == "/tmp/seat-gauge-profile")
    }

    @Test func aCodexPollNeverChecksForAnUpdate() async throws {
        let arguments = try await Self.spec(Self.codexSeat).arguments
        let at = try #require(arguments.firstIndex(of: "check_for_update_on_startup=false"))
        #expect(arguments[at - 1] == "-c")
    }

    @Test func aCodexPollRunsNoneOfTheLoginsHooksOrPlugins() async throws {
        let arguments = try await Self.spec(Self.codexSeat).arguments
        let disabled = arguments.indices.dropLast().filter { arguments[$0] == "--disable" }.map { arguments[$0 + 1] }
        #expect(Set(disabled) == ["hooks", "plugins"])
        #expect(arguments.prefix(2) == ["codex", "app-server"])
    }

    @Test func proxySettingsReachTheChildInEitherSpelling() {
        let proxies = ["HTTPS_PROXY": "http://proxy:8080", "http_proxy": "http://proxy:8080",
                       "ALL_PROXY": "socks5://proxy:1080", "no_proxy": "localhost"]
        let made = ChildEnvironment.make(from: Self.planted.merging(proxies) { $1 })
        #expect(made == proxies)
    }

    @Test func thePollLogKeepsSeatsAndHeadroomPrivate() {
        #expect(PollLog.parts("poll: work live 40% headroom, codex stale")
            == ("poll:", " work live 40% headroom, codex stale"))
        #expect(PollLog.parts("config: 2 seat(s), every 5 min") == ("config:", " 2 seat(s), every 5 min"))
        // A line that opens with anything else, a seat id included, is all private.
        #expect(PollLog.parts("work: 40%, and more") == ("", "work: 40%, and more"))
        #expect(PollLog.parts("40% at 10:00") == ("", "40% at 10:00"))
    }
}
