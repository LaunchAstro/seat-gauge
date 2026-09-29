import Foundation
import Testing

import SeatGaugeCore
import SeatGaugeTestSupport

/// A token seat never resolves a subscription, so `get_usage` answers
/// with nulls for it. The CLI volunteers the same windows mid-turn as a
/// `rate_limit_event`, and that is where a token seat's reading now comes from.
/// Every transcript here is built in the case, except the fixtures one case reads.
@Suite struct RateLimitEventTests {

    static let fiveHours = Duration.seconds(5 * 60 * 60)
    static let sevenDays = Duration.seconds(7 * 24 * 60 * 60)

    /// The resets `personal` reported, as the message writes them: seconds since the
    /// epoch, not the instants `readings.json` holds.
    static let fiveHourReset = 1_790_073_000.0
    static let sevenDayReset = 1_790_625_600.0

    /// The message the CLI volunteers, with the stale entitlement field it really
    /// carries, so a case can prove nothing downstream picks it up.
    static func event(fiveHour: Double, sevenDay: Double) -> String {
        """
        {"type":"rate_limit_event","rate_limit_info":{"status":"allowed",\
        "rateLimitType":"five_hour","resetsAt":\(Int(fiveHourReset)),\
        "overageStatus":"rejected","overageDisabledReason":"org_level_disabled",\
        "isUsingOverage":false,"unifiedWindows":{\
        "five_hour":{"utilization":\(fiveHour),"resetsAt":\(Int(fiveHourReset))},\
        "seven_day":{"utilization":\(sevenDay),"resetsAt":\(Int(sevenDayReset))}}}}
        """
    }

    /// The turn a signed-in seat finishes: the transcript's evidence that it is
    /// signed in whatever `get_usage` then says.
    static let answered = #"{"type":"result","subtype":"success","is_error":false,"result":"ok"}"#

    /// What `get_usage` returns for a token seat: answering, and resolving no
    /// subscription at all.
    static let noSubscription = """
        {"type":"control_response","response":{"subtype":"success","request_id":"2",\
        "response":{"subscription_type":null,"rate_limits_available":false,"rate_limits":null}}}
        """

    /// A token seat's transcript in the order the CLI prints it: the event, then
    /// the result, then the usage reply.
    static func tokenSeat(fiveHour: Double, sevenDay: Double) -> [String] {
        [event(fiveHour: fiveHour, sevenDay: sevenDay), answered, noSubscription]
    }

    @Test("A token seat reads live from the event, in both windows and epoch resets")
    func aTokenSeatReadsFromTheEvent() throws {
        // From the issue: personal read 0.33 and 0.05 with a 5h 30, 7d 5 statusline.
        let outcome = ClaudeUsageParser.windows(from: Self.tokenSeat(fiveHour: 0.33, sevenDay: 0.05),
                                                requestID: "2")
        guard case let .live(windows, plan) = outcome else {
            Issue.record("a token seat's transcript did not read live: \(outcome)")
            return
        }
        #expect(windows.map(\.kind) == [.fiveHour, .weekly])
        #expect(windows.map(\.usedPercent) == [33, 5])
        #expect(windows.map(\.length) == [Self.fiveHours, Self.sevenDays])
        // The seat resolves no subscription, and still reads live.
        #expect(plan == nil)
        // `resetsAt` is seconds since the epoch. Read as anything else these land
        // tens of thousands of years out and the countdown draws a useless number.
        #expect(windows.map(\.resetsAt).map(\.timeIntervalSince1970)
                == [Self.fiveHourReset, Self.sevenDayReset])
        #expect(windows[0].resetsAt < Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test("The fraction becomes a whole percentage, rounded away from zero at the half")
    func theFractionIsConvertedOnce() throws {
        // 0.125 and 0.375 are exact in binary, so each lands on the half. 0.145 and
        // 0.285 are halves only a decimal makes: each sits a hair under in binary
        // and rounds low if Double does the work.
        let expected: [(Double, Int)] = [
            (0.0, 0), (0.001, 0), (0.005, 1), (0.1249, 12), (0.125, 13), (0.145, 15),
            (0.285, 29), (0.33, 33), (0.375, 38), (0.6, 60), (0.995, 100), (1.0, 100),
        ]
        for (fraction, percent) in expected {
            let outcome = ClaudeUsageParser.windows(from: Self.tokenSeat(fiveHour: fraction, sevenDay: 0.0),
                                                    requestID: "2")
            guard case let .live(windows, _) = outcome else {
                Issue.record("\(fraction) did not read live: \(outcome)")
                continue
            }
            #expect(windows[0].usedPercent == percent)
        }
    }

    @Test("A seat that answers but volunteers nothing is unreadable with a reason")
    func noEventIsUnreadableRatherThanDormant() throws {
        let outcome = ClaudeUsageParser.windows(from: [Self.answered, Self.noSubscription],
                                                requestID: "2")
        guard case let .unreadable(reason) = outcome else {
            Issue.record("a seat with no event did not read unreadable: \(outcome)")
            return
        }
        #expect(!reason.isEmpty)
        // The stale entitlement state rides on the event, and is never a reason.
        #expect(!reason.contains("overage"))
        #expect(!reason.contains("org_level_disabled"))

        // An event carrying no windows is the same nothing, said the same way.
        let empty = #"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{}}}"#
        #expect(ClaudeUsageParser.windows(from: [empty, Self.answered, Self.noSubscription], requestID: "2")
                == .unreadable(reason: "the seat answered but reported no usage windows"))
    }

    @Test("A seat the CLI turned away is unreadable in the seat's own words")
    func aRefusedTurnCarriesItsOwnReason() throws {
        let said = "This seat cannot use its subscription here, so ask the account owner"
        let refused = """
            {"type":"result","subtype":"success","is_error":true,"result":"\(said)"}
            """
        let outcome = ClaudeUsageParser.windows(from: [refused, Self.noSubscription], requestID: "2")
        // Not dormant: the seat is signed in and said why it would not answer.
        #expect(outcome == .unreadable(reason: said))

        // A transcript with no turn never said the login was absent, so it is
        // unreadable. Dormant needs the seat to say so, as the personal fixture does.
        #expect(ClaudeUsageParser.windows(from: [Self.noSubscription], requestID: "2")
                == .unreadable(reason: "the seat answered but reported no usage windows"))
    }

    @Test("The work, personal and codex fixtures read as expected")
    func theFixturesReadAsExpected() throws {
        // work: get_usage answered, so its three windows are the reading.
        let work = ClaudeUsageParser.windows(from: try Fixture.lines("work"), requestID: "2")
        guard case let .live(windows, plan) = work else {
            Issue.record("the work fixture did not read live: \(work)")
            return
        }
        #expect(windows.map(\.kind) == [.fiveHour, .weekly, .fable])
        #expect(windows.map(\.usedPercent) == [10, 40, 70])
        #expect(plan == "max")

        // personal says `Not logged in`, the positive evidence dormant is kept for.
        #expect(ClaudeUsageParser.windows(from: try Fixture.lines("personal"), requestID: "2")
                == .dormant(reason: "not logged in"))

        // codex reads through its own parser, untouched here.
        let codex = CodexRateLimitsParser.windows(from: try Fixture.lines("codex"))
        guard case let .live(codexWindows, _) = codex else {
            Issue.record("the codex fixture did not read live: \(codex)")
            return
        }
        #expect(codexWindows.first?.usedPercent == 90)
    }

    @Test("A utilization no Int could hold drops the window instead of the app")
    func aMalformedFractionCannotTrapTheProcess() throws {
        // Each killed the process on conversion, from one field the app does not write.
        for written in ["1e20", "-1e30", "\"nan\"", "\"inf\"", "\"1e400\""] {
            let event = """
                {"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":\
                {"five_hour":{"utilization":\(written),"resetsAt":1790073000}}}}
                """
            let lines = [event, Self.answered, Self.noSubscription]
            if case .unreadable = ClaudeUsageParser.windows(from: lines, requestID: "2") { continue }
            Issue.record("a utilization of \(written) did not read unreadable")
        }
    }

    @Test("The last readable event is the reading, and an unreadable one is none")
    func theEventShapesThatCarryNoWindow() throws {
        func percents(_ lines: [String]) -> [Int]? {
            let outcome = ClaudeUsageParser.windows(from: lines + [Self.answered, Self.noSubscription],
                                                    requestID: "2")
            guard case let .live(windows, _) = outcome else { return nil }
            return windows.map(\.usedPercent)
        }
        // Two events in one turn: the later describes the seat now, so it is read.
        #expect(percents([Self.event(fiveHour: 0.2, sevenDay: 0.2),
                          Self.event(fiveHour: 0.6, sevenDay: 0.6)]) == [60, 60])
        // A later message with no info is skipped, so the earlier event stands.
        #expect(percents([Self.event(fiveHour: 0.2, sevenDay: 0.2),
                          #"{"type":"rate_limit_event","rate_limit_info":null}"#]) == [20, 20])
        // Kinds nothing draws, no window map and a null one are the same nothing.
        for windows in [#"{"opus_weekly":{"utilization":0.5,"resetsAt":1790073000}}"#, "{}", "null"] {
            #expect(percents([#"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":\#(windows)}}"#]) == nil)
        }
        #expect(percents([#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#]) == nil)
    }

    @Test("A turn that ended in an error is not a logged out seat")
    func anErrorTurnIsUnreadableAndTheReasonIsSafe() throws {
        let errored = #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["request failed"]}"#
        let blank = #"{"type":"result","subtype":"error","is_error":true,"result":""}"#
        for result in [errored, blank] {
            let outcome = ClaudeUsageParser.windows(from: [result, Self.noSubscription], requestID: "2")
            guard case let .unreadable(reason) = outcome else {
                Issue.record("a completed error turn read as \(outcome), not as unreadable")
                continue
            }
            // Neither says the login is absent, and saying so hid the token seats.
            #expect(!reason.contains("logged in"))
        }
    }

    @Test("A reason loses what sits where a credential sits and keeps the rest")
    func theReasonIsRedactedByContextNotByLength() throws {
        // Every sentinel is invented here and is never a credential. Left is what the
        // seat said, right is what may be shown; a nil must arrive whole, because its
        // identifier or its sentence is the only thing in it a reader can act on.
        let cases: [(String, String?)] = [
            ("authentication failed: password=\"zzSentinel!A7k?B8m#C9n$D0p%E1q\"",
             "authentication failed: password=\"[redacted]\""),
            ("Authentication failed: Bearer zzSYNTHETIC_A7kB8m", "Authentication failed: Bearer [redacted]"),
            // A vendor key's shape under a prefix AGENTS.md allows: shape is the rule.
            ("refused: zk-syn-oat01-zzSYNTH0A7kB8mC9n is not valid", "refused: [redacted] is not valid"),
            ("refused, key zzsentinel" + String(repeating: "A7k", count: 8), "refused, key [redacted]"),
            ("Request failed: UnsupportedAuthenticationMethod", nil),
            ("error: insufficient_authentication_scopes", nil),
            ("This seat cannot use its subscription here, so ask the account owner", nil),
            ("Your organization has disabled Claude subscription access for Claude Code", nil),
        ]
        for (said, want) in cases {
            let quoted = said.replacing("\"", with: "\\\"")
            let refused = #"{"type":"result","is_error":true,"result":"\#(quoted)"}"#
            #expect(ClaudeUsageParser.windows(from: [refused, Self.noSubscription], requestID: "2")
                    == .unreadable(reason: want ?? said))
        }
        // Bounded: the panel is given a line of it, not a transcript.
        let long = String(repeating: "no ", count: 200)
        let flood = #"{"type":"result","is_error":true,"result":"\#(long)"}"#
        #expect(ClaudeUsageParser.windows(from: [flood, Self.noSubscription], requestID: "2")
                == .unreadable(reason: String(long.prefix(240))))
    }
}
