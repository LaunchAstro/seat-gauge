import Foundation

/// Which seat the main login is, once per poll (ADR 0005). It reads one field
/// from `~/.claude.json` and from each Claude seat profile's `.claude.json`,
/// compares the values where they were read and keeps none of them: the
/// observation carries a seat name or nothing.
public enum IdentityObserver {
    enum Read: Equatable { case id(String), noAccount, unreadable }

    static func account(in file: URL) -> Read {
        guard let data = FileManager.default.contents(atPath: file.path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unreadable }
        guard let account = root["oauthAccount"] as? [String: Any],
              let id = account["accountUuid"] as? String, !id.isEmpty
        else { return .noAccount }
        return .id(id)
    }

    /// A match only when every file read and exactly one seat's id is the main
    /// login's; no match when every file read and none is; anything less says
    /// nothing, so a missing, expired or half-written file never moves a span.
    public static func observe(seats: [Seat], home: URL) -> IdentityObservation {
        guard case let .id(main) = account(in: ClaudePlanFile.file(profileDir: nil, home: home))
        else { return .incomplete }
        var matched: [String] = []
        for seat in seats {
            guard case let .claude(profile) = seat.kind else { continue }
            guard case let .id(id) = account(in: ClaudePlanFile.file(profileDir: profile, home: home))
            else { return .incomplete }
            if id == main { matched.append(seat.id.rawValue) }
        }
        switch matched.count {
        case 0: return .noMatch
        case 1: return .match(matched[0])
        default: return .incomplete
        }
    }

    /// What the app hands its poller: after each poll's cards are read, one
    /// observation for the writer.
    public static func hook(writer: AttributionWriter,
                            home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                            now: @escaping @Sendable () -> Date = { Date() }) -> @Sendable ([Seat]) async -> Void {
        { seats in
            await writer.observe(observe(seats: seats, home: home), now: now())
        }
    }
}
