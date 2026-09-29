import Foundation

/// Where `seatgauge-cli record` redacts and writes one seat's reply.
///
/// A recording is a real seat's own usage, so it goes through this before it
/// reaches the disk: account ids, emails, tokens and home paths come out. It
/// is still a local file to read, not a fixture to commit. The fixtures in
/// `Tests/Fixtures/` are hand-written.
public enum FixtureRecording {
    private static let zeroUUID = "00000000-0000-0000-0000-000000000000"

    /// Each rule is a pattern and what replaces the capture group in it, in the
    /// order they run. Keys first, so a token inside one is gone before the
    /// looser prefix rule looks for it.
    private static let rules: [(pattern: String, keep: String)] = [
        (#"("(?:accountId|account_id|email|access_token|refresh_token|id_token|api_?[Kk]ey)"\s*:\s*")[^"]*"#, "$1"),
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, ""),
        (#"\bsk-[a-z]{2,5}-[A-Za-z0-9_-]{8,}"#, ""),
        (#"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#, zeroUUID),
        // A home folder, macOS or Linux, becomes one neutral home.
        (#"/(?:Users|home)/[^/"\\\s]+"#, "/home/seat"),
        // The Bonjour name of the Mac, which names its user as surely as an
        // account id does.
        (#"[A-Za-z0-9-]+\.local\b"#, "seat-mac.local"),
    ]

    private static let compiled: [(NSRegularExpression, String)] = rules.compactMap {
        guard let expression = try? NSRegularExpression(pattern: $0.pattern) else { return nil }
        return (expression, $0.keep)
    }

    /// One recorded stdout line, with the login taken out of it.
    public static func redact(_ line: String) -> String {
        var line = line
        for (expression, keep) in compiled {
            line = expression.stringByReplacingMatches(
                in: line, range: NSRange(line.startIndex..., in: line), withTemplate: keep)
        }
        return line
    }

    /// `<seat>-<date>.jsonl`, on the local day. Local because every other date
    /// in this app is local, and because a recording made this afternoon
    /// sorting after this morning's is what the tests read the newest one by.
    public static func fileName(seat: SeatID, date: Date) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        return "\(seat.rawValue)-\(day.string(from: date)).jsonl"
    }

    /// Writes the lines as they came off stdout, one per line, and hands back
    /// the file it wrote. The caller redacts first; this does not redact again.
    @discardableResult
    public static func write(_ lines: [String], seat: SeatID, date: Date,
                             into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(fileName(seat: seat, date: date))
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
