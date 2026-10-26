import Foundation

/// Where `seatgauge-cli record` redacts and writes one seat's reply.
///
/// A recording is a real seat's own usage, so it goes through this before it
/// reaches the disk. Only the keys the parsers read are kept; every other
/// field, and with it whatever account, organisation, skill or credential a
/// reply carries, is dropped. What is kept is scrubbed of credentials, emails,
/// account ids and home paths. It is still a local file to read, not a
/// fixture to commit: it goes in `.scratch/recordings/`, which git ignores,
/// readable by the user alone. The fixtures in `Tests/Fixtures/` are
/// hand-written.
public enum FixtureRecording {
    private static let zeroUUID = "00000000-0000-0000-0000-000000000000"

    /// Every key a parser reads, at any depth: `ClaudeUsageParser`,
    /// `ClaudeRateLimitEventParser`, `CodexRateLimitsParser` and the
    /// fetchers' own checks. A key a parser starts to read is added here, or
    /// a recording will not show it.
    static let kept: Set<String> = [
        "type", "subtype", "request_id", "response", "result", "is_error", "method", "id", "model",
        "account", "tokenSource",
        "subscription_type", "rate_limits_available", "rate_limits", "limits", "kind", "scope",
        "display_name", "percent", "utilization", "resets_at", "five_hour", "seven_day",
        "rate_limit_info", "unifiedWindows", "resetsAt",
        "rateLimits", "primary", "secondary", "windowDurationMins", "usedPercent", "planType",
    ]

    /// Each rule is a pattern and what replaces it, run on a kept string
    /// before `plain` decides whether it is kept at all: ids and the user's
    /// home and Mac name, which a parser never needs, made neutral.
    private static let rules: [(pattern: String, keep: String)] = [
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

    /// What a kept string may be: the short plain words, dates and numbers
    /// the parsers read (a type, a kind, a reset time, a model, an error
    /// sentence such as "Not logged in · Please run /login"), with no quote
    /// of either kind, line break, `=`, `@`, backslash or brace in it, no word that names a credential,
    /// and no long run mixing letters and digits, which is a key or an id
    /// rather than anyone's prose. A `key` or `pin`, in any case, counts
    /// wherever it ends, however it is spaced or joined: `API  key`, a bare
    /// `key:`, `key_id`, `keyId`, `signingkEy`, `userPIN`, `MyPin`,
    /// `pinNumber`. Only a lower-case letter straight after it, as in
    /// `keyboard`, `pinned` or `spinning`, makes it part of a longer word,
    /// and a `KEY` or `PIN` in capitals counts even then (`PINnumber`). A
    /// missed spelling leaks, while a redacted word (`monkey`, `spin up`)
    /// only costs a recording its wording.
    private static let plainText = try? NSRegularExpression(
        pattern: #"\A[\p{L}\p{N} .,:;_+\-/()\[\]!?·…%]{0,200}\z"#)
    private static let credential = try? NSRegularExpression(
        pattern: #"(?i)pass(word|phrase|wd)?|secret|token|bearer|basic|auth|credential|cookie|session.?key|api.?key|private.?key|access.?key|keys?(?-i:(?!\p{Ll}))|pin(?:s|code)?(?-i:(?!\p{Ll}))|(?-i:KEY|PIN)|sk-|eyJ"#)
    private static let run = try? NSRegularExpression(pattern: #"[\p{L}\p{N}_\-+/.]{24,}"#)

    /// One recorded stdout line with only what the parsers read left in it.
    /// A line that is not JSON is the CLI's own prose, which no parser reads,
    /// so it becomes an empty object and the line count stays as recorded.
    public static func redact(_ line: String) -> String {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
              parsed is [String: Any] || parsed is [Any],
              let data = try? JSONSerialization.data(withJSONObject: keep(parsed),
                                                     options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Kept keys at every depth, their strings scrubbed; numbers, booleans
    /// and nulls as they were.
    static func keep(_ value: Any) -> Any {
        switch value {
        case let object as [String: Any]:
            return object.filter { kept.contains($0.key) }.mapValues(keep)
        case let array as [Any]:
            return array.map(keep)
        case let text as String:
            return scrub(text)
        default:
            return value
        }
    }

    /// A kept string, with its ids and home made neutral, if it is plain
    /// (`plainText`), or `[redacted]` whole. Whole, because a rule that
    /// takes out only the credential in a sentence always meets one more
    /// way of writing it: escaped quotes, quoted values, cookie lists, JSON
    /// inside the string. A recording shows the shape; it never needs the
    /// wording of an error that mentions a credential.
    static func scrub(_ text: String) -> String {
        var text = text
        for (expression, keep) in compiled {
            text = expression.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: keep)
        }
        let whole = NSRange(text.startIndex..., in: text)
        guard let plainText, let credential, let run,
              plainText.firstMatch(in: text, range: whole) != nil,
              credential.firstMatch(in: text, range: whole) == nil,
              !run.matches(in: text, range: whole).contains(where: { match in
                  guard let range = Range(match.range, in: text) else { return true }
                  return text[range].contains(where: \.isNumber) && text[range].contains(where: \.isLetter)
              })
        else { return "[redacted]" }
        return text
    }

    /// `.scratch/recordings/` in the folder `record` runs from: in a clone,
    /// beside its tracked files and ignored by git.
    public static func directory(in folder: URL) -> URL {
        folder.appendingPathComponent(".scratch/recordings", isDirectory: true)
    }

    /// `<seat>-<date>.jsonl`, on the local day. Local because every other date
    /// in this app is local, and because a recording made this afternoon
    /// sorts after this morning's.
    public static func fileName(seat: SeatID, date: Date) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        return "\(seat.rawValue)-\(day.string(from: date)).jsonl"
    }

    /// Writes the lines as they came off stdout, one per line, and hands back
    /// the file it wrote. The caller redacts first; this does not redact
    /// again. The folder is made private to the user, and the file is written
    /// beside its name with only the user able to read it, then renamed into
    /// place, so it is never readable by anyone else, even for a moment. A
    /// seat whose name would put the file anywhere but `directory` writes
    /// nothing; `seats.json` refuses such an id, and this holds whatever
    /// built the seat.
    @discardableResult
    public static func write(_ lines: [String], seat: SeatID, date: Date,
                             into directory: URL) throws -> URL {
        let name = fileName(seat: seat, date: date)
        let file = directory.appendingPathComponent(name)
        guard !seat.rawValue.isEmpty, !seat.rawValue.contains("/"), !seat.rawValue.contains("\0"),
              file.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path
        else { throw ProcessFailure("\(seat.rawValue.debugDescription) cannot name a recording, so nothing was written.") }
        // The folder and the one above it are opened one name at a time from
        // the folder above both, never following a link and never by path
        // again, so neither can be swapped for a link to somewhere else
        // between a check and a write. Every step after works through the
        // one descriptor.
        let parent = directory.deletingLastPathComponent()
        let grand = parent.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: grand, withIntermediateDirectories: true)
        let top = open(grand.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard top >= 0 else { throw failure(grand) }
        defer { close(top) }
        let middle = try openFolder(parent.lastPathComponent, in: top, at: parent)
        defer { close(middle) }
        let folder = try openFolder(directory.lastPathComponent, in: middle, at: directory)
        defer { close(folder) }
        var info = stat()
        guard fstat(folder, &info) == 0, info.st_uid == geteuid() else {
            throw ProcessFailure("\(directory.path) is not yours, so no recording was written.")
        }
        guard fchmod(folder, 0o700) == 0 else { throw failure(directory) }

        let draft = ".\(name).\(UUID().uuidString)"
        let descriptor = openat(folder, draft, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw failure(directory.appendingPathComponent(draft)) }
        var bytes = Array((lines.joined(separator: "\n") + "\n").utf8)[...]
        var written = fchmod(descriptor, 0o600) == 0
        while written, !bytes.isEmpty {
            let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            written = count > 0
            if written { bytes = bytes.dropFirst(count) }
        }
        let closed = close(descriptor) == 0
        guard written, closed, renameat(folder, draft, folder, name) == 0 else {
            let problem = failure(file)
            unlinkat(folder, draft, 0)
            throw problem
        }
        return file
    }

    /// `name` inside the folder `parent` is open on, made 700 when it is
    /// missing, and opened without following a link: a link there, or
    /// anything not a folder, is refused.
    static func openFolder(_ name: String, in parent: Int32, at url: URL) throws -> Int32 {
        if mkdirat(parent, name, 0o700) != 0, errno != EEXIST { throw failure(url) }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ProcessFailure("\(url.path) is a link or not a folder, so no recording was written.")
        }
        return descriptor
    }

    private static func failure(_ url: URL) -> ProcessFailure {
        ProcessFailure("\(url.lastPathComponent) could not be written: \(String(cString: strerror(errno)))")
    }
}
