import Foundation

/// The only place the Codex app-server's rate limits reply is known.
///
/// It reads the JSON-RPC line with `id: 2`, keys `primary` and `secondary` by
/// `windowDurationMins`, and leaves `usedPercent` alone: the figure is already
/// a used one, so converting at the boundary is the identity here.
public enum CodexRateLimitsParser {
    /// The window lengths the panel draws. Anything else is a limit this app
    /// has no row for, and is ignored.
    private static let known: [Int: WindowKind] = [300: .fiveHour, 10080: .weekly]

    public static func windows(from stdoutLines: [String]) -> FetchOutcome {
        let objects = stdoutLines.compactMap(JSON.object)
        // A server-to-client request for fresh tokens means the seat is not
        // logged in. It is never answered; the reason is handed back instead.
        if objects.contains(where: { $0["method"] as? String == "account/chatgptAuthTokens/refresh" }) {
            return .dormant(reason: "Codex needs a login")
        }
        guard let result = objects.first(where: { JSON.int($0["id"]) == 2 })?["result"]
                as? [String: Any],
              let limits = result["rateLimits"] as? [String: Any]
        else { return .unreadable(reason: "no reply to the Codex rate limits request") }

        let read = ["primary", "secondary"].compactMap { key -> Window? in
            // A null secondary is a seat with one window, not a broken reply.
            guard let row = limits[key] as? [String: Any],
                  let minutes = JSON.int(row["windowDurationMins"]),
                  let kind = known[minutes],
                  let used = JSON.int(row["usedPercent"]),
                  let resetsAt = JSON.date(row["resetsAt"])
            else { return nil }
            return Window(kind: kind, usedPercent: used, resetsAt: resetsAt,
                          length: .seconds(minutes * 60))
        }
        guard !read.isEmpty else {
            return .unreadable(reason: "no usable window in the Codex rate limits reply")
        }
        return .live(windows: read.sorted { $0.kind < $1.kind },
                     plan: limits["planType"] as? String)
    }
}
