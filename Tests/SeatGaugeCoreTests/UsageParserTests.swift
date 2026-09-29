import Foundation
import Testing

import SeatGaugeCore
import SeatGaugeTestSupport

/// The Claude and Codex usage parsers, pace, the countdown and the best seat.
@Suite struct UsageParserTests {

    // MARK: - Reading the fixtures under test

    /// The checkout this file was compiled from, so a run inside a worktree
    /// reads that worktree and not whatever is checked out beside it.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SeatGaugeCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // the repository

    /// A Claude `get_usage` reply built around one `rate_limits` body, for the
    /// shapes the work fixture does not show.
    static func claudeReply(rateLimits: String, available: String = "true") -> [String] {
        ["""
         {"type":"control_response","response":{"subtype":"success","request_id":"2",\
         "response":{"subscription_type":"max","rate_limits_available":\(available),\
         "rate_limits":\(rateLimits)}}}
         """]
    }

    static func codexReply(rateLimits: String) -> [String] {
        ["""
         {"id":2,"result":{"ordinaryUsageAllowed":true,"rateLimits":\(rateLimits),\
         "accountId":"redacted"}}
         """]
    }

    static func windows(_ outcome: FetchOutcome) -> [Window] {
        if case let .live(windows, _) = outcome { return windows }
        return []
    }

    static let fiveHours = Duration.seconds(5 * 60 * 60)
    static let sevenDays = Duration.seconds(7 * 24 * 60 * 60)

    // MARK: - The Claude parser

    @Test("the work fixture reads as three windows in WindowKind order")
    func workFixtureReadsAsThreeWindows() throws {
        let outcome = ClaudeUsageParser.windows(from: try Fixture.lines("work"), requestID: "2")
        guard case let .live(windows, plan) = outcome else {
            Issue.record("the work fixture did not read as live: \(outcome)")
            return
        }
        #expect(windows.map(\.kind) == [.fiveHour, .weekly, .fable])
        #expect(windows.map(\.usedPercent) == [10, 40, 70])
        #expect(windows.map(\.length) == [Self.fiveHours, Self.sevenDays, Self.sevenDays])
        #expect(plan == "max")
        // The three `resets_at` instants, fractional seconds and all.
        let epochs = windows.map(\.resetsAt).map(\.timeIntervalSince1970)
        #expect(abs(epochs[0] - 1_767_243_600.5) < 0.01)
        #expect(abs(epochs[1] - 1_767_744_000.5) < 0.01)
        #expect(abs(epochs[2] - 1_767_744_000.5) < 0.01)
        // A reply to another request is not this one's, whatever it carries.
        #expect(ClaudeUsageParser.windows(from: try Fixture.lines("work"), requestID: "7")
                == .unreadable(reason: "no control_response for request 7"))
    }

    @Test("either percentage key is read, in the rows and at the top level")
    func eitherPercentageKeyIsRead() throws {
        let rows = """
            {"limits":[{"kind":"session","utilization":11,"resets_at":"2026-01-01T05:00:00.000Z"},\
            {"kind":"weekly_all","percent":22,"resets_at":"2026-01-07T00:00:00.000Z"}]}
            """
        #expect(Self.windows(ClaudeUsageParser.windows(from: Self.claudeReply(rateLimits: rows),
                                                       requestID: "2")).map(\.usedPercent) == [11, 22])

        // No `limits[]` at all: the top-level pair is the fallback, and it too
        // is read under either spelling.
        let topUtilization = """
            {"five_hour":{"utilization":33,"resets_at":"2026-01-01T05:00:00.000Z"},\
            "seven_day":{"utilization":44,"resets_at":"2026-01-07T00:00:00.000Z"}}
            """
        let topPercent = topUtilization.replacingOccurrences(of: "utilization", with: "percent")
        for body in [topUtilization, topPercent] {
            let read = Self.windows(ClaudeUsageParser.windows(from: Self.claudeReply(rateLimits: body),
                                                              requestID: "2"))
            #expect(read.map(\.kind) == [.fiveHour, .weekly])
            #expect(read.map(\.usedPercent) == [33, 44])
        }
    }

    @Test("only the Not logged in capture is dormant, an unavailable reading is not")
    func aDormantSeatReadsAsDormant() throws {
        guard case let .dormant(reason) = ClaudeUsageParser.windows(from: try Fixture.lines("personal"),
                                                                    requestID: "2") else {
            Issue.record("the Not logged in fixture did not read as dormant")
            return
        }
        #expect(!reason.isEmpty)

        let rows = #"{"limits":[{"kind":"session","percent":9,"resets_at":"2026-01-01T05:00:00.000Z"}]}"#
        // False, and absent altogether: neither is a reading, and neither is a
        // missing login either. False is what a logged-in token seat answers, so
        // each reads unreadable carrying a reason.
        // With no turn asked, as for an own login, there is no turn to finish.
        let unavailable = Self.claudeReply(rateLimits: rows, available: "false")
        #expect(ClaudeUsageParser.windows(from: unavailable, requestID: "2")
                == .unreadable(reason: "the seat answered but reported no usage windows"))
        let absent = ["""
            {"type":"control_response","response":{"subtype":"success","request_id":"2",\
            "response":{"rate_limits":\(rows)}}}
            """]
        #expect(ClaudeUsageParser.windows(from: absent, requestID: "2")
                == .unreadable(reason: "the seat answered but reported no usage windows"))
        // A turn that started and never gave a result says so.
        let started = [#"{"type":"system","subtype":"init","model":"claude-haiku-4-5"}"#] + unavailable
        #expect(ClaudeUsageParser.windows(from: started, requestID: "2")
                == .unreadable(reason: "the seat's turn never finished"))
    }

    @Test("with no turn, an initialize reply with no token source is a seat that is not logged in")
    func anOwnLoginWithNoTokenSourceIsDormant() {
        let initialize = #"{"type":"control_response","response":{"subtype":"success","request_id":"1","response":{"commands":[],"account":{"tokenSource":"none","apiProvider":"firstParty"}}}}"#
        let usage = #"{"type":"control_response","response":{"subtype":"success","request_id":"2","response":{"subscription_type":null,"rate_limits_available":false,"rate_limits":null}}}"#
        #expect(ClaudeUsageParser.windows(from: [initialize, usage], requestID: "2")
                == .dormant(reason: "not logged in"))
    }

    // MARK: - The Codex parser

    @Test("the codex fixture is read off the id 2 line, uninverted")
    func codexFixtureReadsOffTheSecondReply() throws {
        let outcome = CodexRateLimitsParser.windows(from: try Fixture.lines("codex"))
        guard case let .live(windows, plan) = outcome else {
            Issue.record("the codex fixture did not read as live: \(outcome)")
            return
        }
        // 90% used is 90% used: the conversion is the identity on this transport.
        #expect(windows.map(\.kind) == [.weekly])
        #expect(windows.map(\.usedPercent) == [90])
        #expect(windows.map(\.length) == [Self.sevenDays])
        #expect(abs(windows[0].resetsAt.timeIntervalSince1970 - 1_767_571_200) < 0.01)
        #expect(plan == "prolite")

        // The fixture carries one weekly window, so the 300-minute and
        // the ignored duration are read beside it.
        let both = """
            {"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1767243600},\
            "secondary":{"usedPercent":34,"windowDurationMins":10080,"resetsAt":1767744000},\
            "planType":"pro"}
            """
        let read = Self.windows(CodexRateLimitsParser.windows(from: Self.codexReply(rateLimits: both)))
        #expect(read.map(\.kind) == [.fiveHour, .weekly])
        #expect(read.map(\.usedPercent) == [12, 34])
        #expect(read.map(\.length) == [Self.fiveHours, Self.sevenDays])

        let strange = """
            {"primary":{"usedPercent":12,"windowDurationMins":4321,"resetsAt":1767243600},\
            "secondary":{"usedPercent":34,"windowDurationMins":10080,"resetsAt":1767744000}}
            """
        #expect(Self.windows(CodexRateLimitsParser.windows(from: Self.codexReply(rateLimits: strange)))
                .map(\.kind) == [.weekly])
    }

    @Test("a null secondary keeps the primary, and a refresh request is dormant")
    func aNullSecondaryKeepsThePrimary() throws {
        // The fixture is itself a null secondary.
        #expect(try Fixture.lines("codex").contains { $0.contains("\"secondary\":null") })
        #expect(Self.windows(CodexRateLimitsParser.windows(from: try Fixture.lines("codex"))).count == 1)

        let nulled = """
            {"primary":{"usedPercent":7,"windowDurationMins":300,"resetsAt":1767243600},\
            "secondary":null}
            """
        #expect(Self.windows(CodexRateLimitsParser.windows(from: Self.codexReply(rateLimits: nulled)))
                .map(\.kind) == [.fiveHour])

        // A server-to-client request, not a reply: the seat needs a login, and
        // the parser hands back a reason rather than an answer to write.
        let refresh = [#"{"jsonrpc":"2.0","id":9,"method":"account/chatgptAuthTokens/refresh","params":{}}"#]
        #expect(CodexRateLimitsParser.windows(from: refresh)
                == .dormant(reason: "Codex needs a login"))
    }

    // MARK: - Pace and the countdown

    @Test("pace matches its three cases and Codex at 96%")
    func paceReadsItsThreeCases() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let week = 7.0 * 24 * 60 * 60
        let resetsAt = start.addingTimeInterval(week)
        func weekly(_ used: Int) -> Window {
            Window(kind: .weekly, usedPercent: used, resetsAt: resetsAt, length: Self.sevenDays)
        }

        // Half the window spent a tenth of the way in: dry long before reset.
        let early = start.addingTimeInterval(week * 0.1)
        guard case let .runsOut(dry) = Pace(weekly: weekly(50), now: early) else {
            Issue.record("50% used a tenth of the way in is not on pace to run out")
            return
        }
        #expect(abs(dry.timeIntervalSince(start) - week * 0.2) < 1)

        // A tenth spent halfway through: four fifths will go unused.
        #expect(Pace(weekly: weekly(10), now: start.addingTimeInterval(week * 0.5))
                == .unused(percent: 80))
        // Half spent halfway through: exactly on pace.
        #expect(Pace(weekly: weekly(50), now: start.addingTimeInterval(week * 0.5)) == .onPace)
        // Nothing used is no pace at all.
        #expect(Pace(weekly: weekly(0), now: start.addingTimeInterval(week * 0.5)) == nil)

        // Codex at 96% with a day to run is amber, not on pace.
        let codex = Window(kind: .weekly, usedPercent: 96, resetsAt: resetsAt, length: Self.sevenDays)
        let dayToRun = resetsAt.addingTimeInterval(-24 * 60 * 60)
        guard case .runsOut = Pace(weekly: codex, now: dayToRun) else {
            Issue.record("Codex at 96% with a day to run did not read as runs out")
            return
        }
    }

    @Test("the countdown reads in minutes, hours and days, and never in seconds")
    func theCountdownNeverPrintsSeconds() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func text(_ seconds: Double) -> String {
            Countdown.text(until: now.addingTimeInterval(seconds), now: now)
        }
        #expect(text(42 * 60) == "42m")
        #expect(text(60 * 60 + 3 * 60) == "1:03")
        #expect(text(24 * 60 * 60) == "1d 0h")
        #expect(text(6 * 24 * 60 * 60 + 2 * 60 * 60) == "6d 2h")
        // The odd seconds are dropped rather than shown or rounded up.
        #expect(text(42 * 60 + 59) == "42m")
        #expect(text(-90) == "0m")
    }

    // MARK: - The snapshot

    @Test("the best seat is the most headroom in its tightest window")
    func theBestSeatIsTheMostHeadroomInItsTightestWindow() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let resetsAt = now.addingTimeInterval(3600)
        func reading(_ id: String, _ percents: [Int]) -> Reading {
            Reading(seat: SeatID(rawValue: id),
                    windows: percents.enumerated().map { index, used in
                        Window(kind: WindowKind.allCases[index], usedPercent: used,
                               resetsAt: resetsAt, length: Self.fiveHours)
                    },
                    takenAt: now, plan: nil)
        }
        let order = [SeatID(rawValue: "a"), SeatID(rawValue: "b"), SeatID(rawValue: "c")]

        // a's tightest window leaves 40, b's leaves 40, c's leaves 70.
        let spread = Snapshot(states: [order[0]: .live(reading("a", [10, 60])),
                                       order[1]: .live(reading("b", [60, 10])),
                                       order[2]: .live(reading("c", [30, 20]))],
                              order: order)
        #expect(spread.best == order[2])

        // The same two, tied at 40, with the winner dormant: first in config order.
        let tied = Snapshot(states: [order[0]: .live(reading("a", [10, 60])),
                                     order[1]: .live(reading("b", [60, 10])),
                                     order[2]: .dormant(reason: "not logged in")],
                            order: order)
        #expect(tied.best == order[0])

        // Nothing live: a dormant seat and a stale one are never picked.
        let none = Snapshot(states: [order[0]: .dormant(reason: "not logged in"),
                                     order[1]: .unreadable(reason: "timed out", last: reading("b", [0, 0])),
                                     order[2]: .dormant(reason: "not logged in")],
                            order: order)
        #expect(none.best == nil)
        #expect(none.visible == [order[1]])
    }

    // MARK: - Failing closed

    @Test("a row with no reset instant is dropped, and a capture of none is unreadable")
    func aRowWithNoResetInstantIsDropped() throws {
        let mixed = """
            {"limits":[{"kind":"session","percent":3,"resets_at":"2026-01-01T05:00:00.000Z"},\
            {"kind":"weekly_all","percent":60},\
            {"kind":"weekly_scoped","percent":86,"resets_at":"2026-01-07T00:00:00.000Z",\
            "scope":{"model":{"display_name":"Fable 5.1"}}}]}
            """
        let read = Self.windows(ClaudeUsageParser.windows(from: Self.claudeReply(rateLimits: mixed),
                                                          requestID: "2"))
        #expect(read.map(\.kind) == [.fiveHour, .fable])

        // Every row dropped is not a live reading of nothing.
        let none = #"{"limits":[{"kind":"session","percent":3},{"kind":"weekly_all","percent":60}]}"#
        guard case let .unreadable(reason) = ClaudeUsageParser.windows(
            from: Self.claudeReply(rateLimits: none), requestID: "2") else {
            Issue.record("a capture whose every row was dropped did not read as unreadable")
            return
        }
        #expect(!reason.isEmpty)

        // The Codex side drops the same way, on a row with no reset instant.
        let codex = """
            {"primary":{"usedPercent":12,"windowDurationMins":300},\
            "secondary":{"usedPercent":34,"windowDurationMins":10080,"resetsAt":1767744000}}
            """
        #expect(Self.windows(CodexRateLimitsParser.windows(from: Self.codexReply(rateLimits: codex)))
                .map(\.kind) == [.weekly])
    }
}
