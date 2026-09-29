import Foundation

/// The plan a Claude login says it has, read off the config dir's
/// `.claude.json`. That file holds live account state, so exactly one
/// key is read, `oauthAccount.organizationRateLimitTier`, and the rest of the
/// parsed file is dropped where it was parsed: nothing else is kept, logged,
/// printed or written anywhere. A file that cannot say is no plan, never an
/// error and never "Free".
public enum ClaudePlanFile {
    /// `~/.claude.json` for the default login, `<profile>/.claude.json` for a
    /// profile seat, which is where the CLI keeps each login's account.
    public static func file(profileDir: URL?,
                            home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        (profileDir ?? home).appendingPathComponent(".claude.json")
    }

    public static func plan(in file: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: file.path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any],
              let tier = account["organizationRateLimitTier"] as? String
        else { return nil }
        return words(forTier: tier)
    }

    /// The display words for a tier: `default_claude_max_20x` is `Max 20x`.
    /// A tier this app does not know keeps its own words, the tail after the
    /// last `default_claude_` with underscores as spaces, rather than being
    /// guessed into one it does.
    public static func words(forTier tier: String) -> String? {
        let marker = "default_claude_"
        let tail = tier.range(of: marker, options: .backwards)
            .map { String(tier[$0.upperBound...]) } ?? tier
        switch tail {
        case "max_20x": return "Max 20x"
        case "max_5x": return "Max 5x"
        case "pro": return "Pro"
        case "free": return "Free"
        default: return PlanText.said(tail.replacingOccurrences(of: "_", with: " "))
        }
    }
}

/// The plan a Codex login says it has: the `chatgpt_plan_type` claim in the
/// `id_token` payload of `auth.json`. The payload segment is decoded
/// with no signature check, because nothing is trusted on it but a word to
/// draw. The `id_token` is read, in memory only, to decode that payload; the
/// plan claim is kept and the rest is discarded when the read returns: the
/// `id_token` itself, its other claims, and the access and refresh tokens,
/// which are never selected. None of it is logged, printed or saved.
public enum CodexPlanFile {
    /// `$CODEX_HOME/auth.json`, or `~/.codex/auth.json`, where Codex keeps it.
    public static var defaultFile: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap(PlanText.said)
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex", isDirectory: true)
        return home.appendingPathComponent("auth.json")
    }

    public static func plan(in file: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: file.path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String
        else { return nil }
        let segments = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, let payload = decode(segments[1]),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let plan = auth["chatgpt_plan_type"] as? String
        else { return nil }
        return words(forPlanType: plan)
    }

    /// The display words for a Codex plan type, from the login or the wire.
    public static func words(forPlanType type: String) -> String? {
        switch type.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "pro": return "Pro"
        case "plus": return "Plus"
        case "free": return "Free"
        case "prolite": return "Pro Lite"
        case let other: return PlanText.said(other.replacingOccurrences(of: "_", with: " "))
        }
    }

    /// base64url with its padding put back, which is how a JWT segment is cut.
    private static func decode(_ segment: Substring) -> Data? {
        var text = segment.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text)
    }
}
