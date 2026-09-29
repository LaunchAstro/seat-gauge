import Foundation

/// One seat read once: what the panel draws, and the raw lines the CLI printed,
/// which is what `seatgauge-cli record` writes to a fixture.
public struct Fetched: Sendable {
    public let state: SeatState
    public let lines: [String]

    public init(state: SeatState, lines: [String]) {
        self.state = state
        self.lines = lines
    }
}

public protocol SeatFetching: Sendable {
    func fetch(_ seat: Seat, now: Date, last: Reading?) async -> Fetched
}

/// The fetcher for a seat's kind, with the runner that spawns real CLIs.
public func seatFetcher(for seat: Seat, runner: any ProcessRunning = RealProcessRunner(),
                        timeout: Duration = .seconds(60)) -> any SeatFetching {
    switch seat.kind {
    case .claude: return ClaudeFetcher(runner: runner, timeout: timeout)
    case .codex: return CodexFetcher(runner: runner, timeout: timeout)
    }
}

/// The pieces both recipes share: where the CLI is found, how a transcript is
/// read, and how a parser's answer becomes a seat state.
enum Fetch {
    /// `env` resolves the CLI off the PATH the runner augments, so a login
    /// launched app finds `claude` and `codex` where a shell would.
    static let env = URL(fileURLWithPath: "/usr/bin/env")

    typealias Lines = AsyncThrowingStream<String, Error>.AsyncIterator

    /// Reads until `stop` says so, or until the seat stops talking. A seat that
    /// closed early is not an error here: the parser reads what arrived and
    /// decides whether that is a dormant seat or an unreadable one.
    static func read(_ lines: inout Lines, into kept: inout [String],
                     until stop: ([String: Any]) -> Bool) async throws {
        while let line = try await lines.next() {
            kept.append(line)
            if let object = JSON.object(line), stop(object) { return }
        }
    }

    /// `tier` finds the exact plan the account names, given the wire's word,
    /// and the reading keeps both. It runs only for a live seat, so a
    /// seat that did not read has no file read.
    static func state(_ outcome: FetchOutcome, seat: Seat, now: Date, last: Reading?,
                      tier: (String?) -> String?) -> SeatState {
        switch outcome {
        case let .live(windows, plan):
            return .live(Reading(seat: seat.id, windows: windows, takenAt: now,
                                 plan: plan, tier: tier(plan)))
        case let .dormant(reason):
            return .dormant(reason: reason)
        case let .unreadable(reason):
            return .unreadable(reason: reason, last: last)
        }
    }

    static func failed(_ error: any Error, last: Reading?) -> SeatState {
        .unreadable(reason: (error as? ProcessFailure)?.reason ?? "\(error)", last: last)
    }
}

/// Drives the Claude recipe and hands the transcript to the parser.
public struct ClaudeFetcher: SeatFetching {
    let runner: any ProcessRunning
    let primer: URL
    let timeout: Duration
    /// The environment the app was launched with, which the child's is
    /// picked from (`ChildEnvironment`).
    let parent: [String: String]

    public init(runner: any ProcessRunning = RealProcessRunner(),
                primer: URL = AppPaths.primer, timeout: Duration = .seconds(60),
                parent: [String: String] = ProcessInfo.processInfo.environment) {
        self.runner = runner
        self.primer = primer
        self.timeout = timeout
        self.parent = parent
    }

    /// `--strict-mcp-config` with no `--mcp-config` starts no MCP server, and
    /// `--safe-mode` loads none of the login's hooks, plugins, skills or LSP
    /// servers. What they start is the login's, and one that tries to modify
    /// an app is charged to Seat Gauge as App Management. Sign-in is untouched.
    static let arguments = ["claude", "-p", "--input-format", "stream-json",
                            "--output-format", "stream-json", "--verbose", "--strict-mcp-config",
                            "--safe-mode"]
    /// A poll never updates the CLI. An update rewrites the install the
    /// user's own sessions run, charged to whichever app spawned it.
    static let noUpdate = ["DISABLE_AUTOUPDATER": "1"]
    /// The one short turn a token seat needs: its `get_usage` reply is empty,
    /// and its windows arrive only as a `rate_limit_event` during a turn.
    static let turn = ["--model", "haiku", "--max-turns", "1"]
    static let initialize = #"{"type":"control_request","request_id":"1","request":{"subtype":"initialize"}}"#
    static let ask = #"{"type":"user","message":{"role":"user","content":"Reply with the single word ok."}}"#
    static let usage = #"{"type":"control_request","request_id":"2","request":{"subtype":"get_usage","skip_behaviors":true}}"#

    public func fetch(_ seat: Seat, now: Date, last: Reading?) async -> Fetched {
        // Neither the config directory nor the token is inherited, so whatever
        // the launching shell exported never signs a seat in as somebody
        // else. The seat gets its own directory, and its token when it has a
        // token source.
        guard case let .claude(profileDir) = seat.kind else {
            return Fetched(state: .unreadable(reason: "not a Claude seat", last: last), lines: [])
        }
        var seatVariables = Self.noUpdate.merging(["CLAUDE_CONFIG_DIR": profileDir.path]) { $1 }
        if let tokenFile = seat.tokenFile {
            switch SeatToken.read(tokenFile) {
            case let .success(token): seatVariables[SeatToken.variable] = token
            case let .failure(problem):
                // Nothing was launched, so there is no transcript to keep.
                return Fetched(state: .unreadable(reason: problem.reason, last: last), lines: [])
            }
        }
        let turn = seat.readsByTurn
        let spec = ProcessSpec(executable: Fetch.env, arguments: Self.arguments + (turn ? Self.turn : []),
                               environment: ChildEnvironment.make(from: parent, setting: seatVariables),
                               currentDirectory: primer, timeout: timeout)
        var kept: [String] = []
        do {
            let session = try runner.launch(spec)
            defer { session.terminate() }
            var lines = session.stdoutLines.makeAsyncIterator()
            try session.send(Self.initialize)
            if turn {
                try session.send(Self.ask)
                // The turn has to finish before the usage request is worth sending.
                try await Fetch.read(&lines, into: &kept) { $0["type"] as? String == "result" }
            }
            try session.send(Self.usage)
            try await Fetch.read(&lines, into: &kept) { object in
                guard object["type"] as? String == "control_response",
                      let response = object["response"] as? [String: Any] else { return false }
                return JSON.text(response["request_id"]) == "2"
            }
            session.closeInput()
        } catch {
            return Fetched(state: Fetch.failed(error, last: last), lines: kept)
        }
        // The login's tier; the wire's `subscription_type` stays as the plan.
        let file = ClaudePlanFile.file(profileDir: profileDir)
        return Fetched(state: Fetch.state(ClaudeUsageParser.windows(from: kept, requestID: "2"),
                                          seat: seat, now: now, last: last) { _ in
            ClaudePlanFile.plan(in: file)
        }, lines: kept)
    }
}

/// Drives the Codex app-server recipe. Stdin stays open until the
/// `id: 2` reply has arrived, because closing it earlier ends the server.
public struct CodexFetcher: SeatFetching {
    let runner: any ProcessRunning
    let timeout: Duration
    /// The login the plan claim is read from when the wire gives none.
    let authFile: URL
    /// Where the server runs, so the rollout it may leave is the gauge's own.
    let primer: URL
    let parent: [String: String]

    public init(runner: any ProcessRunning = RealProcessRunner(), timeout: Duration = .seconds(60),
                authFile: URL = CodexPlanFile.defaultFile, primer: URL = AppPaths.codexPrimer,
                parent: [String: String] = ProcessInfo.processInfo.environment) {
        self.runner = runner
        self.timeout = timeout
        self.authFile = authFile
        self.primer = primer
        self.parent = parent
    }

    /// The same guard as Claude's: no update check, and none of the login's
    /// hooks or plugins, so a poll starts nothing the gauge did not ask for.
    static let arguments = ["codex", "app-server", "-c", "check_for_update_on_startup=false",
                            "--disable", "hooks", "--disable", "plugins"]
    static let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"seat-gauge","title":"Seat Gauge","version":"0.1.0"}}}"#
    static let initialized = #"{"jsonrpc":"2.0","method":"initialized"}"#
    static let limits = #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{"excludeResetCreditDetails":true}}"#

    public func fetch(_ seat: Seat, now: Date, last: Reading?) async -> Fetched {
        // A working directory that is not there fails the launch.
        try? FileManager.default.createDirectory(at: primer, withIntermediateDirectories: true)
        let spec = ProcessSpec(executable: Fetch.env, arguments: Self.arguments,
                               // CODEX_HOME is where the codex login lives, when the
                               // user has moved it from ~/.codex.
                               environment: ChildEnvironment.make(from: parent, keeping: ["CODEX_HOME"]),
                               currentDirectory: primer, timeout: timeout)
        var kept: [String] = []
        do {
            let session = try runner.launch(spec)
            defer { session.terminate() }
            var lines = session.stdoutLines.makeAsyncIterator()
            try session.send(Self.initialize)
            try session.send(Self.initialized)
            try session.send(Self.limits)
            try await Fetch.read(&lines, into: &kept) { object in
                // The token refresh request is a seat with no login. It ends
                // the read and is never answered.
                JSON.int(object["id"]) == 2
                    || object["method"] as? String == "account/chatgptAuthTokens/refresh"
            }
            session.closeInput()
        } catch {
            return Fetched(state: Fetch.failed(error, last: last), lines: kept)
        }
        // The wire's `planType` is exact already, so it is the tier when it is
        // there, then the login's claim.
        return Fetched(state: Fetch.state(CodexRateLimitsParser.windows(from: kept),
                                          seat: seat, now: now, last: last) { wire in
            PlanText.said(wire).flatMap(CodexPlanFile.words(forPlanType:))
                ?? CodexPlanFile.plan(in: authFile)
        }, lines: kept)
    }
}
