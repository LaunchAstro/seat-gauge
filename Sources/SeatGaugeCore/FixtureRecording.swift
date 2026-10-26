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

    /// Each rule is a pattern and what replaces it, in the order they run, on
    /// the text of each kept string, once any JSON written inside it is gone
    /// (`scrub`). Credentials first, so a token inside one is gone before a
    /// looser rule looks at it.
    private static let rules: [(pattern: String, keep: String)] = [
        // A bearer or basic credential, in a header or in prose.
        (#"(?i)\b(bearer|basic)\s+[^\s"',;}\]]+"#, "$1 [redacted]"),
        // A credential word, alone or as part of a name such as
        // `refresh_token`, `client_secret` or `API key`, given a value with
        // `:` or `=`: a quoted value goes whole, and an unquoted one up to the
        // next comma, semicolon or bracket, spaces and all.
        (#"(?i)([A-Za-z0-9_\-]*(?:password|passphrase|passwd|secret|token|authorization|credential|cookie|api[ _\-]?key|access[ _\-]?key|private[ _\-]?key|session[ _\-]?key)[A-Za-z0-9_\-]*["']?\s*[:=]\s*)(?:"[^"]*"?|'[^']*'?|(?!\s*(?:bearer|basic)\b)[^,;}\]\n]+)"#, "$1[redacted]"),
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, ""),
        (#"\bsk-[A-Za-z0-9_\-]{12,}"#, "[redacted]"),
        (#"\beyJ[A-Za-z0-9_\-]{8,}(?:\.[A-Za-z0-9_\-]+){1,2}"#, "[redacted]"),
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

    /// A long unbroken run mixing letters and digits is a key or an id,
    /// never anyone's prose, so it goes whatever names it.
    private static let run = try? NSRegularExpression(pattern: #"[A-Za-z0-9_\-+/=.]{24,}"#)

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

    /// A kept string with any JSON object written inside it taken out
    /// whole, since no parser reads one there and it can carry a credential
    /// under any name, nested or escaped, then put through `rules` and `run`.
    static func scrub(_ text: String) -> String {
        var text = withoutObjects(text)
        for (expression, keep) in compiled {
            text = expression.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: keep)
        }
        guard let run else { return text }
        var out = text
        for match in run.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let found = text[range]
            if found.contains(where: \.isNumber), found.contains(where: \.isLetter) {
                out.replaceSubrange(Range(match.range, in: out)!, with: "[redacted]")
            }
        }
        return out
    }

    /// Each `{` and what follows it to its matching `}`, or to the end when
    /// it never closes, as `{…}`. Braces inside a quoted string do not count.
    static func withoutObjects(_ text: String) -> String {
        var out = ""
        var depth = 0, quoted = false, escaped = false
        for character in text {
            if depth == 0 {
                if character == "{" { depth = 1; out += "{…}" } else { out.append(character) }
                continue
            }
            if escaped { escaped = false; continue }
            switch character {
            case "\\" where quoted: escaped = true
            case "\"": quoted.toggle()
            case "{" where !quoted: depth += 1
            case "}" where !quoted: depth -= 1
            default: break
            }
        }
        return out
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
        // Neither the folder nor the one above it may be a link, checked
        // before anything is made, so nothing outside is made, written or
        // narrowed. The folder is then opened without following a link, and
        // every step after works through that one descriptor.
        for folder in [directory.deletingLastPathComponent(), directory] where isLink(folder) {
            throw ProcessFailure("\(folder.path) is a link, so no recording was written.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw failure(directory) }
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

    static func isLink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    private static func failure(_ url: URL) -> ProcessFailure {
        ProcessFailure("\(url.lastPathComponent) could not be written: \(String(cString: strerror(errno)))")
    }
}
