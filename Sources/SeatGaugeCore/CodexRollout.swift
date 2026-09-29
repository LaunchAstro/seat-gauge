import Foundation

/// What a read of Codex's rollout files gave up: hourly cells under directory
/// `codex`, the lines it could not read, and the files it could not key.
public struct CodexReading: Sendable {
    public let cells: [SpendCell: TokenCounts]
    public let skipped: Int
    public let unkeyed: Int

    /// The cells as record rows, in the record's order. Pricing and sealing
    /// are the roll-up's to decide, so every row here is unpriced and open.
    public var rows: [SpendRow] {
        cells.map { cell, counts in
            SpendRow(seat: cell.seat, day: cell.day, hour: cell.hour, model: cell.model,
                     counts: counts, usd: nil, sealed: false)
        }
        .sorted { ($0.seat, $0.day, $0.hour, $0.model) < ($1.seat, $1.day, $1.hour, $1.model) }
    }
}

/// Codex's own session logs, `rollout-*.jsonl`, read into the spend record's
/// cells. Usage arrives as a cumulative total on
/// each `token_count` event, so what a response adds is the rise in that total
/// since the last one the session saw, and every rule below is about finding
/// that rise without counting any token twice.
public enum CodexRollout {
    public static let seat = "codex"

    static let fields = ["input_tokens", "cached_input_tokens", "cache_write_input_tokens",
                         "output_tokens", "reasoning_output_tokens", "total_tokens"]

    /// One token event, with the model the latest `turn_context` named.
    struct Event {
        let at: Date?
        let model: String
        let total: [String: Int]
        let last: [String: Int]?
    }

    /// One file, keyed by the session its first `session_meta` names.
    struct Rollout {
        let url: URL
        let session: String?
        let cwd: String?
        /// The timestamp of the file's first `token_count` event, with usage
        /// or without, which is what orders a resume: a file with none sorts
        /// last.
        let firstToken: Date?
        let events: [Event]
        let skipped: Int
    }

    /// A session any of whose files ran in one of `primers` is the gauge's
    /// own polling, and is left out as the Claude walk leaves out its own.
    public static func read(files: [URL], calendar: Calendar, excluding primers: [String] = []) -> CodexReading {
        var sessions: [String: [Rollout]] = [:]
        var skipped = 0
        var unkeyed = 0
        for url in files {
            guard let rollout = parse(url) else { continue }
            skipped += rollout.skipped
            guard let session = rollout.session else { unkeyed += 1; continue }
            sessions[session, default: []].append(rollout)
        }

        var cells: [SpendCell: TokenCounts] = [:]
        for rollouts in sessions.values {
            let polled = rollouts.contains { rollout in
                rollout.cwd.map { cwd in primers.contains { (cwd + "/").hasPrefix($0 + "/") } } ?? false
            }
            if polled { continue }
            // A resume continues the file before it, so the files are read in
            // the order the session wrote them, whatever order they came in.
            let ordered = rollouts.sorted {
                ($0.firstToken ?? .distantFuture, $0.url.lastPathComponent, $0.url.path)
                    < ($1.firstToken ?? .distantFuture, $1.url.lastPathComponent, $1.url.path)
            }
            var baseline: [String: Int]?
            for event in ordered.flatMap(\.events) {
                guard let at = event.at else { skipped += 1; continue }
                let step = contribution(total: event.total, last: event.last, after: baseline)
                baseline = step.baseline
                guard step.added.values.contains(where: { $0 > 0 }) else { continue }
                let hour = SpendCSV.columns(at: at, calendar: calendar)
                let cell = SpendCell(seat: seat, day: hour.day, hour: hour.hour, model: event.model)
                cells[cell] = (cells[cell] ?? TokenCounts()) + counts(step.added)
            }
        }
        return CodexReading(cells: cells, skipped: skipped, unkeyed: unkeyed)
    }

    /// What one event adds, and the total the next one is measured against.
    /// A field absent from either side adds nothing, and keeps the value it
    /// last had, so an absence is never read as a fall to zero.
    static func contribution(total: [String: Int], last: [String: Int]?,
                             after baseline: [String: Int]?) -> (added: [String: Int], baseline: [String: Int]) {
        guard let baseline else { return (last ?? total, total) }
        let reset: Bool
        if let now = total["total_tokens"], let before = baseline["total_tokens"] {
            reset = now < before
        } else {
            let shared = total.keys.filter { baseline[$0] != nil }
            reset = shared.reduce(0) { $0 + total[$1]! } < shared.reduce(0) { $0 + baseline[$1]! }
        }
        if reset { return (last ?? total, total) }
        var added: [String: Int] = [:]
        for (field, value) in total {
            if let before = baseline[field] { added[field] = max(0, value - before) }
        }
        return (added, baseline.merging(total) { _, fresh in fresh })
    }

    /// Cached input and cache writes sit inside Codex's input, so fresh input
    /// is what is left without them, and never below zero. Reasoning sits
    /// inside output: it is recorded as thinking and never added again.
    static func counts(_ usage: [String: Int]) -> TokenCounts {
        let cached = usage["cached_input_tokens"] ?? 0
        let written = usage["cache_write_input_tokens"] ?? 0
        return TokenCounts(responses: 1,
                           input: max(0, (usage["input_tokens"] ?? 0) - cached - written),
                           output: usage["output_tokens"] ?? 0,
                           thinking: usage["reasoning_output_tokens"] ?? 0,
                           cacheRead: cached, cacheWrite5m: written, cacheWrite1h: 0)
    }

    // MARK: - One file

    /// Nil for a file that is not there. The model is per file: a resumed
    /// file is `unknown` until its own `turn_context`.
    static func parse(_ url: URL) -> Rollout? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var session: String?
        var cwd: String?
        var firstToken: Date?
        var model = "unknown"
        var events: [Event] = []
        var skipped = 0
        for line in candidates(data) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                skipped += 1
                continue
            }
            let at = JSON.date(object["timestamp"])
            let payload = object["payload"] as? [String: Any] ?? [:]
            switch object["type"] as? String {
            case "session_meta":
                // A fork carries its parent's meta after its own; only the
                // first names this file's session.
                if session == nil {
                    session = payload["id"] as? String
                    cwd = payload["cwd"] as? String
                }
            case "turn_context":
                if let named = payload["model"] as? String { model = named }
            case "event_msg" where payload["type"] as? String == "token_count":
                // Taken before a usage-less event is dropped, since it is the
                // file's first token event all the same.
                if firstToken == nil { firstToken = at }
                guard let info = payload["info"] as? [String: Any],
                      let total = usage(info["total_token_usage"]) else { continue }
                events.append(Event(at: at, model: model, total: total, last: usage(info["last_token_usage"])))
            default:
                continue
            }
        }
        return Rollout(url: url, session: session, cwd: cwd, firstToken: firstToken,
                       events: events, skipped: skipped)
    }

    static func usage(_ value: Any?) -> [String: Int]? {
        guard let object = value as? [String: Any] else { return nil }
        var out: [String: Int] = [:]
        for field in fields { out[field] = JSON.int(object[field]) }
        return out
    }

    /// The lines worth decoding. A rollout is mostly response items, and a
    /// long one runs to several gigabytes, so a line is handed to the JSON
    /// reader only when it names one of the three kinds that matter, or does
    /// not end the way a JSON object does, which is a line to count as
    /// unreadable rather than pass by. The lines come back as slices.
    static func candidates(_ data: Data) -> [Data] {
        let needles = ["\"session_meta\"", "\"turn_context\"", "\"token_count\""].map { Array($0.utf8) }
        var lines: [Range<Int>] = []
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let count = raw.count
            var start = 0
            while start < count {
                let rest = base + start
                let end = memchr(rest, 0x0A, count - start).map { base.distance(to: UnsafeRawPointer($0)) } ?? count
                var tail = end
                while tail > start, [0x20, 0x09, 0x0D].contains(raw[tail - 1]) { tail -= 1 }
                if tail > start {
                    let length = tail - start
                    let named = needles.contains { memmem(rest, length, $0, $0.count) != nil }
                    if named || raw[tail - 1] != 0x7D { lines.append(start ..< tail) }
                }
                start = end + 1
            }
        }
        let origin = data.startIndex
        return lines.map { data[(origin + $0.lowerBound) ..< (origin + $0.upperBound)] }
    }
}
