import Foundation

/// The only place the Claude `get_usage` reply's shape is known, and the one
/// that decides what a Claude transcript amounts to.
///
/// It reads the `control_response` whose `response.request_id` matches, then
/// `rate_limits.limits[]`, falling back to the top-level `five_hour` and
/// `seven_day` objects when there is no `limits[]`. The percentage key is
/// `percent` in the rows and `utilization` at the top level, and either
/// spelling is accepted in both places.
///
/// When that reply carries no windows, the ones the CLI volunteered during the
/// turn are read instead, through `ClaudeRateLimitEventParser`: a token seat
/// resolves no subscription, so its reply is always empty and the volunteered
/// message is all it has. `get_usage` is still asked for the plan.
public enum ClaudeUsageParser {
    static let fiveHours = Duration.seconds(5 * 60 * 60)
    static let sevenDays = Duration.seconds(7 * 24 * 60 * 60)

    public static func windows(from stdoutLines: [String], requestID: String) -> FetchOutcome {
        guard let payload = reply(in: stdoutLines, requestID: requestID) else {
            if saysNotLoggedIn(stdoutLines) { return .dormant(reason: "not logged in") }
            return .unreadable(reason: "no control_response for request \(requestID)")
        }
        let plan = payload["subscription_type"] as? String
        if let read = asked(payload), !read.isEmpty {
            return .live(windows: read.sorted { $0.kind < $1.kind }, plan: plan)
        }
        let volunteered = ClaudeRateLimitEventParser.windows(in: stdoutLines)
        if !volunteered.isEmpty { return .live(windows: volunteered, plan: plan) }
        return nothingToDraw(payload, lines: stdoutLines)
    }

    /// The windows the reply carried, or nothing when it resolved no subscription.
    private static func asked(_ payload: [String: Any]) -> [Window]? {
        guard payload["rate_limits_available"] as? Bool == true,
              let limits = payload["rate_limits"] as? [String: Any]
        else { return nil }
        return (limits["limits"] as? [[String: Any]]).map(rows) ?? topLevel(limits)
    }

    /// No window from either source. Dormant is said on positive evidence only:
    /// a seat that states it is not logged in. One that turned the CLI away, one
    /// whose turn ended in an error, one that never finished a turn, and one that
    /// answered and reported nothing are all unreadable with the reason. A
    /// dormant seat is hidden from the panel, so a wrong dormant hides a seat
    /// that could have been read.
    private static func nothingToDraw(_ payload: [String: Any], lines: [String]) -> FetchOutcome {
        if saysNotLoggedIn(lines) { return .dormant(reason: "not logged in") }
        guard payload["rate_limits_available"] as? Bool == true else {
            if let refusal = refusal(lines) { return .unreadable(reason: refusal) }
            let finished = result(in: lines)
            // An own login is asked no turn, so only a started turn has a result to wait for.
            if finished == nil, turnStarted(lines) { return .unreadable(reason: "the seat's turn never finished") }
            if finished?["is_error"] as? Bool == true { return .unreadable(reason: "the seat's turn ended in an error") }
            return .unreadable(reason: "the seat answered but reported no usage windows")
        }
        guard payload["rate_limits"] is [String: Any] else {
            return .unreadable(reason: "the usage reply carried no rate limits")
        }
        return .unreadable(reason: "no usable window in the Claude usage reply")
    }

    /// The turn says so in words. With no turn, the `initialize` reply says so:
    /// its account has no token source.
    private static func saysNotLoggedIn(_ lines: [String]) -> Bool {
        lines.contains { line in
            if line.contains("Not logged in") { return true }
            guard line.contains("tokenSource"), let object = JSON.object(line),
                  let response = object["response"] as? [String: Any],
                  let payload = response["response"] as? [String: Any],
                  let account = payload["account"] as? [String: Any] else { return false }
            return account["tokenSource"] as? String == "none"
        }
    }

    private static func turnStarted(_ lines: [String]) -> Bool {
        lines.lazy.compactMap(JSON.object).contains {
            $0["type"] as? String == "system" && $0["subtype"] as? String == "init"
        }
    }

    /// What the seat said when it turned the turn away, in its own words, so the
    /// panel names the cause rather than guessing at one. It is upstream text this
    /// app does not write and both the CLI and the panel show, so anything
    /// credential shaped comes out of it first.
    private static func refusal(_ lines: [String]) -> String? {
        guard let result = result(in: lines), result["is_error"] as? Bool == true,
              let said = result["result"] as? String, !said.isEmpty
        else { return nil }
        return safe(said)
    }

    /// Length does not say what a credential is: `Bearer zzShort1` is one and
    /// `insufficient_authentication_scopes` is not. Context does. A word that
    /// names a credential puts what follows it in credential context, and that
    /// value goes when it was assigned with `:` or `=` or when it carries a
    /// digit, neither of which ordinary error prose does. A long unbroken run
    /// mixing letters and digits is nobody's prose either. The rest is the
    /// seat's own wording, which is the whole use of showing it, and the reason
    /// is bounded either way.
    private static func safe(_ said: String) -> String {
        let named = #/(?i)(^|[^A-Za-z0-9_])(password|passwd|secret|token|bearer|authorization|credential|cookie|api[_\-]?key|key)(["']?\s*[:=]\s*["']?|\s+)([^\s"']{2,})/#
        let told = said.replacing(named) { found -> String in
            let assigned = found.3.contains { (mark: Character) in mark == ":" || mark == "=" }
            let numbered = found.4.contains { (mark: Character) in mark.isNumber }
            guard assigned || numbered else { return String(found.0) }
            return String(found.1) + String(found.2) + String(found.3) + "[redacted]"
        }
        let shown = told.replacing(#/[A-Za-z0-9_\-.+\/=]{20,}/#) { run -> String in
            let digit = run.output.contains { (mark: Character) in mark.isNumber }
            let letter = run.output.contains { (mark: Character) in mark.isLetter }
            return digit && letter ? "[redacted]" : String(run.output)
        }
        return String(shown.prefix(240))
    }

    private static func result(in lines: [String]) -> [String: Any]? {
        lines.lazy.compactMap(JSON.object).last { $0["type"] as? String == "result" }
    }

    /// The reply this request asked for. Another request's reply is not it,
    /// whatever it carries.
    private static func reply(in lines: [String], requestID: String) -> [String: Any]? {
        for line in lines {
            guard let object = JSON.object(line),
                  object["type"] as? String == "control_response",
                  let response = object["response"] as? [String: Any],
                  JSON.text(response["request_id"]) == requestID,
                  let payload = response["response"] as? [String: Any]
            else { continue }
            return payload
        }
        return nil
    }

    /// `limits[]`, one row at a time. A row of a kind nothing draws, and a row
    /// with no percentage or no reset instant, is dropped here.
    private static func rows(_ rows: [[String: Any]]) -> [Window] {
        rows.compactMap { row in
            let kind: WindowKind
            let length: Duration
            switch row["kind"] as? String {
            case "session":
                kind = .fiveHour
                length = fiveHours
            case "weekly_all":
                kind = .weekly
                length = sevenDays
            case "weekly_scoped":
                let scope = row["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                guard let name = model?["display_name"] as? String, name.hasPrefix("Fable")
                else { return nil }
                kind = .fable
                length = sevenDays
            default:
                return nil
            }
            guard let used = percent(row), let resetsAt = JSON.date(row["resets_at"]) else { return nil }
            return Window(kind: kind, usedPercent: used, resetsAt: resetsAt, length: length)
        }
    }

    /// The pair that was there before `limits[]` was, read the same way.
    private static func topLevel(_ limits: [String: Any]) -> [Window] {
        let pairs: [(String, WindowKind, Duration)] = [
            ("five_hour", .fiveHour, fiveHours),
            ("seven_day", .weekly, sevenDays),
        ]
        return pairs.compactMap { key, kind, length in
            guard let object = limits[key] as? [String: Any],
                  let used = percent(object),
                  let resetsAt = JSON.date(object["resets_at"])
            else { return nil }
            return Window(kind: kind, usedPercent: used, resetsAt: resetsAt, length: length)
        }
    }

    /// Either spelling, in a row or at the top level. Claude Code 2.1.278 writes
    /// `percent` in the rows and `utilization` above them.
    private static func percent(_ object: [String: Any]) -> Int? {
        JSON.int(object["percent"]) ?? JSON.int(object["utilization"])
    }
}
