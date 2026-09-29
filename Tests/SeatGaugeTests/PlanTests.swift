import Foundation
import Testing

import SeatGaugeCore
@testable import SeatGauge
import SeatGaugeTestSupport

/// Where a seat's plan comes from. Every account file a case reads is one it wrote into its own temporary
/// directory, holding invented values. No case reads `~/.claude.json`,
/// `~/.codex` or `~/.config/claude-seats`.
@Suite(.sharedMirror) struct PlanTests {

    /// Not a token and not shaped like one, so a leak would leak nothing.
    static let dummy = "not-a-real-token-plan-0123456789"
    static let primer = URL(fileURLWithPath: "/tmp/seat-gauge-primer-plan")
    static let now = Date(timeIntervalSince1970: 1_758_500_100)

    static func temporary() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    static func write(_ contents: String, named name: String, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file, options: .atomic)
        return file
    }

    /// An invented `.claude.json`: the one key the gauge reads, beside keys it
    /// must leave alone.
    static func claudeJSON(tier: String) -> String {
        """
        { "numStartups": 3, "userID": "invented-user",
          "oauthAccount": { "emailAddress": "invented account",
                            "organizationRateLimitTier": "\(tier)" } }
        """
    }

    /// An invented Codex `auth.json` whose `id_token` payload carries the plan.
    static func codexAuth(plan: String) -> String {
        let payload = #"{"https://api.openai.com/auth":{"chatgpt_plan_type":"\#(plan)"},"https://api.openai.com/profile":{"email":"invented account"}}"#
        let segment = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return """
        { "auth_mode": "chatgpt", "OPENAI_API_KEY": "\(dummy)",
          "tokens": { "access_token": "\(dummy)", "refresh_token": "\(dummy)",
                      "id_token": "eyJhbGciOiJub25lIn0.\(segment).\(dummy)" } }
        """
    }

    /// The own-login fixture, cut where the recipe waits: the initialize
    /// reply, then the usage reply. An own login is asked no turn.
    static func claudeReplies() throws -> [[String]] {
        let lines = try Fixture.lines("own")
        return [Array(lines.prefix(1)), Array(lines.dropFirst())]
    }

    static func claude(_ seat: Seat, replies: [[String]],
                       ends: Bool = false) async -> (spec: ProcessSpec?, fetched: Fetched) {
        let runner = ScriptedRunner(replies: replies, endsWithScript: ends)
        let fetched = await ClaudeFetcher(runner: runner, primer: primer, timeout: .seconds(5))
            .fetch(seat, now: now, last: nil)
        return (runner.launched.first, fetched)
    }

    static func codex(lines: [String], authFile: URL) async -> Fetched {
        let runner = ScriptedRunner(replies: [[], [], lines])
        return await CodexFetcher(runner: runner, timeout: .seconds(5), authFile: authFile)
            .fetch(Seat(id: SeatID(rawValue: "codex"), label: "Codex", kind: .codex),
                   now: now, last: nil)
    }

    /// What the seat found about itself, before any declaration.
    static func plan(_ state: SeatState) -> String? {
        guard case let .live(reading) = state else { return nil }
        return PlanText.resolve(tier: reading.tier, declared: nil, wire: reading.plan)
    }

    // MARK: - The tier from the config dir's `.claude.json`

    @Test func theClaudePlanIsReadFromTheConfigDirTier() throws {
        let home = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = home.appendingPathComponent(".claude-seat-test", isDirectory: true)
        #expect(ClaudePlanFile.file(profileDir: nil, home: home).path
                == home.appendingPathComponent(".claude.json").path)
        #expect(ClaudePlanFile.file(profileDir: profile, home: home).path
                == profile.appendingPathComponent(".claude.json").path)

        let words = ["default_claude_max_20x": "Max 20x", "default_claude_max_5x": "Max 5x",
                     "default_claude_pro": "Pro", "default_claude_free": "Free",
                     "default_claude_team_premium": "team premium"]
        for (tier, said) in words {
            let file = try Self.write(Self.claudeJSON(tier: tier), named: ".claude.json", into: profile)
            #expect(ClaudePlanFile.plan(in: file) == said)
            #expect(ClaudePlanFile.words(forTier: tier) == said)
        }
        // Fails closed: nothing is no plan, never an error and never free.
        let missing = home.appendingPathComponent("absent/.claude.json")
        #expect(ClaudePlanFile.plan(in: missing) == nil)
        for broken in ["not json", #"{"numStartups": 3}"#, #"{"oauthAccount": 7}"#,
                       #"{"oauthAccount": {"organizationRateLimitTier": 20}}"#,
                       #"{"oauthAccount": {"organizationRateLimitTier": "  "}}"#] {
            let file = try Self.write(broken, named: ".claude.json", into: home)
            #expect(ClaudePlanFile.plan(in: file) == nil)
        }
    }

    // MARK: - File, then declared, then wire, then nothing

    @Test func thePlanResolvesFileThenDeclaredThenWire() async throws {
        #expect(PlanText.resolve(tier: "Pro", declared: "Pro Lite", wire: nil) == "Pro")
        #expect(PlanText.resolve(tier: "Max 5x", declared: "Max 5x obsolete", wire: "max") == "Max 5x")
        #expect(PlanText.resolve(tier: "Max 20x", declared: "Max 5x", wire: "max") == "Max 20x")
        #expect(PlanText.resolve(tier: nil, declared: "Max 20x", wire: "max") == "Max 20x")
        #expect(PlanText.resolve(tier: " ", declared: nil, wire: "max") == "max")
        #expect(PlanText.resolve(tier: nil, declared: " ", wire: " ") == nil)
        #expect(PlanText.resolve(tier: nil, declared: nil, wire: nil) == nil)
        // The two-argument form is the same rule with no file tier.
        #expect(PlanText.resolve(tier: nil, declared: "Max 20x", wire: "max") == "Max 20x")

        // All three disagree: the file wins, and the card says so.
        let home = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.write(Self.claudeJSON(tier: "default_claude_max_5x"), named: ".claude.json", into: home)
        let seat = Seat(id: SeatID(rawValue: "work"), label: "Work",
                        kind: .claude(profileDir: home), plan: "Max 20x")
        let fetched = await Self.claude(seat, replies: try Self.claudeReplies())
        #expect(Self.plan(fetched.fetched.state) == "Max 5x")
        #expect(PlanText.shown(for: seat, state: fetched.fetched.state) == "Max 5x")
        // No file: the declaration beats the wire's `max`, which the reading keeps.
        let bare = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: bare) }
        let wire = await Self.claude(Seat(id: seat.id, label: seat.label, kind: .claude(profileDir: bare),
                                          plan: seat.plan), replies: try Self.claudeReplies())
        #expect(Self.plan(wire.fetched.state) == "max")
        #expect(PlanText.shown(for: seat, state: wire.fetched.state) == "Max 20x")
        // Nothing anywhere is nil, never "Free".
        let silent = Seat(id: SeatID(rawValue: "personal"), label: "Personal", kind: .claude(profileDir: bare))
        let empty = Reading(seat: silent.id, windows: [], takenAt: Self.now, plan: nil)
        #expect(PlanText.shown(for: silent, state: .live(empty)) == nil)
    }

    // MARK: - Codex: the wire's planType, then the login's claim

    @Test func theCodexPlanComesFromItsLoginAndNoTokenLeaks() async throws {
        let directory = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let auth = try Self.write(Self.codexAuth(plan: "plus"), named: "auth.json", into: directory)
        #expect(CodexPlanFile.plan(in: auth) == "Plus")

        let recorded = try Fixture.lines("codex")
        let wire = await Self.codex(lines: recorded, authFile: auth)
        #expect(Self.plan(wire.state) == "Pro Lite")
        let quiet = recorded.map { $0.replacingOccurrences(of: #""planType":"prolite""#,
                                                           with: #""planType":null"#) }
        let login = await Self.codex(lines: quiet, authFile: auth)
        #expect(Self.plan(login.state) == "Plus")

        // No token value in anything the fetch produced or would keep.
        guard case let .live(reading) = login.state else { Issue.record("not live"); return }
        let encoded = String(decoding: try JSONEncoder().encode(reading), as: UTF8.self)
        for text in login.lines + [encoded, "\(login.state)", CodexPlanFile.plan(in: auth) ?? ""] {
            #expect(!text.contains(Self.dummy))
        }
        // Fails closed: a token that is not a JWT is no plan.
        let broken = try Self.write(#"{"tokens": {"id_token": "\#(Self.dummy)"}}"#,
                                    named: "broken.json", into: directory)
        #expect(CodexPlanFile.plan(in: broken) == nil)
        #expect(CodexPlanFile.plan(in: directory.appendingPathComponent("absent.json")) == nil)
    }

    // MARK: - A profile seat that signs in from its own login

    @Test func anOwnLoginSeatPinsNoTokenAndReadsAsTheDefault() async throws {
        let tokens = try Self.temporary()
        let home = try Self.temporary()
        defer {
            try? FileManager.default.removeItem(at: tokens)
            try? FileManager.default.removeItem(at: home)
        }
        try Self.write(Self.dummy, named: "personal.token", into: tokens)
        try Self.write(Self.dummy, named: "team.token", into: tokens)
        let profile = home.appendingPathComponent(".claude-seat-personal", isDirectory: true)
        let config = try ConfigLoader.decode(Data("""
            { "seats": [
                { "id": "personal", "label": "Personal", "kind": "claude", "profile": "\(profile.path)", "login": "own" },
                { "id": "team", "label": "Team", "kind": "claude", "profile": "/tmp/seat-gauge-plan-team" },
            ] }
            """.utf8), tokenDirectory: tokens)
        #expect(config.seats[0].tokenFile == nil)
        #expect(config.seats[1].tokenFile?.lastPathComponent == "team.token")

        try Self.write(Self.claudeJSON(tier: "default_claude_max_5x"), named: ".claude.json", into: profile)
        let live = await Self.claude(config.seats[0], replies: try Self.claudeReplies())
        let spec = try #require(live.spec)
        #expect(spec.environment["CLAUDE_CONFIG_DIR"] == profile.path)
        #expect(spec.environment[SeatToken.variable] == nil)
        guard case let .live(reading) = live.fetched.state else { Issue.record("not live"); return }
        #expect(reading.windows.contains { $0.kind == .fable })
        #expect(reading.tier == "Max 5x")

        // The token path is unchanged for the seat that did not say so.
        let loggedOut = #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}"#
        let token = await Self.claude(config.seats[1],
                                      replies: [[], [loggedOut], []], ends: true)
        #expect(token.spec?.environment[SeatToken.variable] == Self.dummy)

        // Fails closed: no login of its own is not logged in, and no token.
        let noSource = #"{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{"account":{"tokenSource":"none"}}}}"#
        let noUsage = #"{"type":"control_response","response":{"subtype":"success","request_id":"2","response":{"subscription_type":null,"rate_limits_available":false,"rate_limits":null}}}"#
        let empty = await Self.claude(config.seats[0], replies: [[noSource], [noUsage]], ends: true)
        #expect(empty.fetched.state == SeatState.dormant(reason: "not logged in"))
        #expect(empty.spec?.environment[SeatToken.variable] == nil)
        for bad in [#""login": "borrowed""#, #""login": "own", "token": "/tmp/x.token""#] {
            let text = #"{ "seats": [ { "id": "personal", "label": "Personal", "kind": "claude", "profile": "/tmp/p", "# + bad + " } ] }"
            #expect(throws: ConfigProblem.self) {
                try ConfigLoader.decode(Data(text.utf8), tokenDirectory: tokens)
            }
        }
    }

    // MARK: - Every mapping, and nothing guessed

    @Test func everyMappingHasItsWords() {
        #expect(ClaudePlanFile.words(forTier: "default_claude_max_20x") == "Max 20x")
        #expect(ClaudePlanFile.words(forTier: "default_claude_max_5x") == "Max 5x")
        #expect(ClaudePlanFile.words(forTier: "default_claude_pro") == "Pro")
        #expect(ClaudePlanFile.words(forTier: "default_claude_free") == "Free")
        #expect(ClaudePlanFile.words(forTier: "default_claude_enterprise_max") == "enterprise max")
        #expect(ClaudePlanFile.words(forTier: "legacy_default_claude_max_20x") == "Max 20x")
        #expect(ClaudePlanFile.words(forTier: "some_new_tier") == "some new tier")
        #expect(ClaudePlanFile.words(forTier: "") == nil)
        #expect(CodexPlanFile.words(forPlanType: "pro") == "Pro")
        #expect(CodexPlanFile.words(forPlanType: "plus") == "Plus")
        #expect(CodexPlanFile.words(forPlanType: "free") == "Free")
        #expect(CodexPlanFile.words(forPlanType: "prolite") == "Pro Lite")
        #expect(CodexPlanFile.words(forPlanType: "team_enterprise") == "team enterprise")
        #expect(CodexPlanFile.words(forPlanType: " ") == nil)
        for tier in ["default_claude_max_20x", "default_claude_pro", "some_new_tier"] {
            #expect(ClaudePlanFile.words(forTier: tier)?.lowercased().contains("free") != true)
        }
    }

    // MARK: - Fails closed: nothing from anywhere is no plan, end to end

    @Test @MainActor func aSeatThatSaysNothingCarriesNoPlanAnywhere() async throws {
        let home = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.write("{ not json", named: ".claude.json", into: home)
        let seat = Seat(id: SeatID(rawValue: "work"), label: "Work", kind: .claude(profileDir: home))
        let replies = try Self.claudeReplies().map { part in
            part.map { $0.replacingOccurrences(of: #""subscription_type":"max""#,
                                               with: #""subscription_type":null"#) }
        }
        let claude = await Self.claude(seat, replies: replies)
        guard case .live = claude.fetched.state else { Issue.record("not live"); return }
        #expect(Self.plan(claude.fetched.state) == nil)
        #expect(PlanText.shown(for: seat, state: claude.fetched.state) == nil)

        let quiet = try Fixture.lines("codex").map {
            $0.replacingOccurrences(of: #""planType":"prolite""#, with: #""planType":null"#)
        }
        let broken = try Self.write(#"{"tokens": {"id_token": "a.b.c"}}"#, named: "auth.json", into: home)
        let codex = await Self.codex(lines: quiet, authFile: broken)
        let codexSeat = Seat(id: SeatID(rawValue: "codex"), label: "Codex", kind: .codex)
        #expect(Self.plan(codex.state) == nil)
        #expect(PlanText.shown(for: codexSeat, state: codex.state) == nil)

        let model = PanelModel.make(
            snapshot: Snapshot(states: [seat.id: claude.fetched.state, codexSeat.id: codex.state],
                               order: [seat.id, codexSeat.id]),
            seats: [seat, codexSeat], now: Self.now)
        #expect(model.cards.count == 2)
        for card in model.cards {
            #expect(card.plan == nil)
            #expect(card.seat(on: .detail) == card.label)
        }
    }
}
