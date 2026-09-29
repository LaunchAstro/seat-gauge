import Testing

import SeatGaugeCore

/// A JSON boolean is an `NSNumber` too, and on Darwin one holding 0 or 1 bridges
/// to `Bool` as well, so both parsers dropped a window at 0 or 1 percent used.
@Test(arguments: [0, 1]) func aPercentageOfZeroOrOneIsReadRatherThanDropped(_ used: Int) {
    let claude = #"{"type":"control_response","response":{"request_id":"2","response":{"rate_limits_available":true,"rate_limits":{"limits":[{"kind":"session","percent":\#(used),"resets_at":1767243600}]}}}}"#
    let codex = #"{"id":2,"result":{"rateLimits":{"primary":{"windowDurationMins":300,"usedPercent":\#(used),"resetsAt":1767243600}}}}"#
    guard case let .live(claudeWindows, _) = ClaudeUsageParser.windows(from: [claude], requestID: "2"),
          case let .live(codexWindows, _) = CodexRateLimitsParser.windows(from: [codex])
    else { Issue.record("a window at \(used) percent used was dropped rather than read"); return }
    #expect(claudeWindows.map(\.usedPercent) == [used])
    #expect(codexWindows.map(\.usedPercent) == [used])
}
