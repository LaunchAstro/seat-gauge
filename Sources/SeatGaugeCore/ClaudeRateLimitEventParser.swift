import Foundation

/// The only place the Claude `rate_limit_event` message's shape is known.
///
/// The CLI volunteers it mid-turn, before the `result` line and under both auth
/// mechanisms, so it is already in the transcript the fetcher keeps. It is the
/// one source of windows a token seat has: `get_usage` needs a resolved
/// subscription and a token session never has one.
///
/// Two fields differ from that reply and are normalised here: `utilization` is a
/// fraction of the window, not a whole percentage, and `resetsAt` is seconds
/// since the epoch. `overageDisabledReason` rides along, is stale, and is unread.
enum ClaudeRateLimitEventParser {
    /// The windows the last such message carried, in `WindowKind` order. No
    /// message, or unreadable windows, gives nothing back rather than a zero.
    static func windows(in lines: [String]) -> [Window] {
        guard let info = latest(in: lines),
              let unified = info["unifiedWindows"] as? [String: Any]
        else { return [] }
        let pairs: [(String, WindowKind, Duration)] = [
            ("five_hour", .fiveHour, ClaudeUsageParser.fiveHours),
            ("seven_day", .weekly, ClaudeUsageParser.sevenDays),
        ]
        return pairs.compactMap { key, kind, length in
            guard let object = unified[key] as? [String: Any],
                  let used = percent(object),
                  let resetsAt = JSON.date(object["resetsAt"])
            else { return nil }
            return Window(kind: kind, usedPercent: used, resetsAt: resetsAt, length: length)
        }
        .sorted { $0.kind < $1.kind }
    }

    /// The last message in the transcript: a turn may carry more than one, and
    /// the newest is the one that describes the seat now.
    private static func latest(in lines: [String]) -> [String: Any]? {
        for line in lines.reversed() {
            guard let object = JSON.object(line),
                  object["type"] as? String == "rate_limit_event",
                  let info = object["rate_limit_info"] as? [String: Any]
            else { continue }
            return info
        }
        return nil
    }

    /// The fraction as the whole number `Window` counts in, rounded half away
    /// from zero, in the one place the conversion happens. The rounding is
    /// decimal because the fraction was written as one: in binary `0.145` sits a
    /// hair under fourteen and a half and rounds down, where the seat that wrote
    /// it means fifteen. A value no `Int` could hold drops the window instead of
    /// being converted, because converting it traps.
    private static func percent(_ object: [String: Any]) -> Int? {
        guard let fraction = JSON.fraction(object["utilization"]),
              var scaled = Decimal(string: "\(fraction)").map({ $0 * 100 })
        else { return nil }
        var whole = Decimal()
        NSDecimalRound(&whole, &scaled, 0, .plain)
        guard whole >= Decimal(Int.min), whole <= Decimal(Int.max) else { return nil }
        return NSDecimalNumber(decimal: whole).intValue
    }
}
