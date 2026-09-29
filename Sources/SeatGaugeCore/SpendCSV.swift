import Foundation

/// `spend.csv`, the record the roll-up merges into. It is never regenerated
/// once it exists: the transcripts it was built from are pruned at 30 days by
/// mtime, so the file outlives its own evidence and rewriting it wholesale
/// would throw away everything older than the walk can still see.
public enum SpendCSV {
    /// The columns, in order. No field can hold a comma: a seat is a
    /// seat id or `default`, a day and an hour are digits, and a model id is the
    /// transport's own, which has never carried one.
    public static let header =
        "seat,day,hour,model,responses,input,output,thinking,cache_read,cache_write_5m,cache_write_1h,usd,sealed"

    public static var defaultFile: URL { AppPaths.support.appendingPathComponent("spend.csv") }

    // MARK: - The file

    public static func text(_ rows: [SpendRow]) -> String {
        var out = header + "\n"
        for row in rows {
            let usd = row.usd.map { "\($0)" } ?? ""
            out += [row.seat, row.day, row.hour, row.model, "\(row.responses)", "\(row.input)",
                    "\(row.output)", "\(row.thinking)", "\(row.cacheRead)", "\(row.cacheWrite5m)",
                    "\(row.cacheWrite1h)", usd, row.sealed ? "true" : "false"]
                .joined(separator: ",") + "\n"
        }
        return out
    }

    /// A line that is not thirteen fields, whose counts are not numbers, whose
    /// `usd` is present but not a decimal, or whose `sealed` is neither `true`
    /// nor `false`, is not a row: it is skipped and the rest of the file is
    /// still read, so one bad line never costs the history.
    public static func rows(_ text: String) -> [SpendRow] {
        var rows: [SpendRow] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line == Substring(header) { continue }
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 13 else { continue }
            let n = f[4 ... 10].compactMap { Int($0) }
            guard n.count == 7, f[12] == "true" || f[12] == "false",
                  f[11].isEmpty || f[11].wholeMatch(of: /-?[0-9]+(\.[0-9]+)?/) != nil
            else { continue }
            rows.append(SpendRow(
                seat: f[0], day: f[1], hour: f[2], model: f[3],
                counts: TokenCounts(responses: n[0], input: n[1], output: n[2], thinking: n[3],
                                    cacheRead: n[4], cacheWrite5m: n[5], cacheWrite1h: n[6]),
                usd: f[11].isEmpty ? nil : Decimal(string: f[11]),
                sealed: f[12] == "true"))
        }
        return rows
    }

    public static func read(_ file: URL = SpendCSV.defaultFile) -> [SpendRow] {
        guard let data = FileManager.default.contents(atPath: file.path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return rows(text)
    }

    public static func write(_ rows: [SpendRow], to file: URL = SpendCSV.defaultFile) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text(rows).utf8).write(to: file, options: .atomic)
    }

    // MARK: - The day and hour columns

    /// The local day and hour columns one instant falls in, in the roll-up's
    /// own calendar. The cell a response buckets under and the cell a file's
    /// last write falls in are the same question, so they ask it here.
    static func columns(at instant: Date, calendar: Calendar) -> (day: String, hour: String) {
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: instant)
        return (String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0),
                String(format: "%02d", parts.hour ?? 0))
    }

    /// A `YYYY-MM-DD` day column read as the start of that day, or of `hour`
    /// in it, in the calendar the roll-up bucketed in.
    static func start(day text: String, hour: Int? = nil, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return calendar.date(from: components)
    }

    // MARK: - Sealing

    /// The instant the hour a cell names finishes.
    static func hourEnd(day: String, hour: String, calendar: Calendar) -> Date? {
        guard let hour = Int(hour), let start = start(day: day, hour: hour, calendar: calendar) else { return nil }
        return calendar.date(byAdding: .hour, value: 1, to: start)
    }

    /// 48 h after its hour ends, a cell is closed: the transcripts behind it
    /// are as complete as they will ever be, and a later walk leaves it alone.
    public static func sealed(day: String, hour: String, now: Date, calendar: Calendar) -> Bool {
        guard let end = hourEnd(day: day, hour: hour, calendar: calendar) else { return false }
        return now >= end.addingTimeInterval(48 * 60 * 60)
    }

    /// Whether every cell a log file can feed is already sealed. Its entries
    /// are all at or before its last write, so the latest cell it touches is
    /// that write's own hour: once that hour has sealed, so has every earlier
    /// one, and the merge would refuse all of its rows anyway.
    static func sealedThrough(lastWrite: Date, now: Date, calendar: Calendar) -> Bool {
        let at = columns(at: lastWrite, calendar: calendar)
        return sealed(day: at.day, hour: at.hour, now: now, calendar: calendar)
    }

    // MARK: - The merge

    /// The fresh walk replaces an unsealed cell and is refused a sealed one.
    /// A cell the walk did not reach is kept as it was, so a pruned transcript
    /// does not delete its own history, and every row is weighed against the
    /// sealing rule on the way out, so a cell closes on time whether or not
    /// the walk reached it.
    ///
    /// Sealed is the clock's answer, not the stored flag's. The flag is only
    /// ever as fresh as the run that wrote it, and the walk passes a
    /// transcript by on the clock (`ClaudeCollector.transcripts`), so on the first
    /// run at or after a cell's seal instant the two disagree: the files that
    /// ended inside that hour are already skipped while one that ran past it
    /// is still walked, and a flag still reading false would let that one
    /// file's share replace the whole cell and then close it. Asking the
    /// sealing rule directly is what keeps the skip and the refusal on the
    /// same cutoff, so a fresh row only ever replaces a cell every feeding
    /// transcript was walked for.
    ///
    /// A cell with no stored row is a different question and takes the fresh
    /// row however old it is: nothing was skipped on the run that built the
    /// history, and refusing there would throw away every cell over 48 h old
    /// on the first roll-up, which is the one walk that reads all 28 days.
    public static func merge(_ existing: [SpendRow], with fresh: [SpendRow],
                             now: Date, calendar: Calendar) -> [SpendRow] {
        var rows: [SpendCell: SpendRow] = [:]
        for row in existing { rows[row.cell] = row }
        for row in fresh {
            guard let stored = rows[row.cell] else { rows[row.cell] = row; continue }
            guard !stored.sealed,
                  !sealed(day: row.day, hour: row.hour, now: now, calendar: calendar)
            else { continue }
            rows[row.cell] = row
        }
        return rows.values
            .map { $0.sealing(sealed(day: $0.day, hour: $0.hour, now: now, calendar: calendar)) }
            .sorted {
                ($0.seat, $0.day, $0.hour, $0.model) < ($1.seat, $1.day, $1.hour, $1.model)
            }
    }
}
