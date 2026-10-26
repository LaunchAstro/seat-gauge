import Foundation

/// `spend.csv`, the record the roll-up merges into. It is never regenerated
/// once it exists: the transcripts it was built from are pruned at 30 days by
/// mtime, so the file outlives its own evidence and rewriting it wholesale
/// would throw away everything older than the walk can still see.
public enum SpendCSV {
    /// The columns, in order. A seat, an attributed account or a model is
    /// whatever the config, `attribution.json` or a transcript says. A row
    /// is written as the record always wrote it whenever that reads back as
    /// the same row, and with every field quoted when it would not (`line`).
    public static let header =
        "seat,day,hour,model,responses,input,output,thinking,cache_read,cache_write_5m,cache_write_1h,usd,sealed"

    public static var defaultFile: URL { AppPaths.support.appendingPathComponent("spend.csv") }

    // MARK: - The file

    public static func text(_ rows: [SpendRow]) -> String {
        var out = header + "\n"
        for row in rows { out += line(row) + "\n" }
        return out
    }

    /// One row's line: its columns joined by commas, as the record has always
    /// been written, whenever that splits back into the same columns, which
    /// is every row the record held before quoting. A seat or model with a
    /// comma in it, or with a mark that joins the comma beside it into one
    /// `Character`, would not, so then every field is quoted instead, each
    /// quote in it doubled, by Unicode scalar. A `\n` in a seat or model is
    /// written as a space (`oneLine`), so a row is always one line, whoever
    /// built it.
    static func line(_ row: SpendRow) -> String {
        let usd = row.usd.map { "\($0)" } ?? ""
        let columns = [oneLine(row.seat), row.day, row.hour, oneLine(row.model), "\(row.responses)", "\(row.input)",
                       "\(row.output)", "\(row.thinking)", "\(row.cacheRead)", "\(row.cacheWrite5m)",
                       "\(row.cacheWrite1h)", usd, row.sealed ? "true" : "false"]
        let plain = columns.joined(separator: ",")
        if split(Substring(plain)) == columns { return plain }
        return columns.map { column in
            var quoted = String.UnicodeScalarView(["\""])
            for scalar in column.unicodeScalars {
                quoted.append(scalar)
                if scalar == "\"" { quoted.append(scalar) }
            }
            quoted.append("\"")
            return String(quoted)
        }.joined(separator: ",")
    }

    /// A line read as the record has always been read: split at each comma.
    static func split(_ line: Substring) -> [String] {
        line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }

    /// A line `line` wrote with every field quoted, or nil when any field is
    /// not quoted, a quote does not close, or anything but a comma follows
    /// one. Read by Unicode scalar. The record never held such a line before
    /// quoting, since its counts were never quoted, so no older line reads
    /// differently for it.
    static func quoted(_ line: Substring) -> [String]? {
        var fields: [String] = []
        var scalars = line.unicodeScalars
        while true {
            guard scalars.popFirst() == "\"" else { return nil }
            var value = String.UnicodeScalarView()
            while true {
                guard let next = scalars.popFirst() else { return nil }
                if next != "\"" { value.append(next) }
                else if scalars.first == "\"" { value.append(next); scalars = scalars.dropFirst() }
                else { break }
            }
            fields.append(String(value))
            guard let after = scalars.popFirst() else { return fields }
            guard after == "," else { return nil }
        }
    }

    /// A line is read the way the record was always read first, so every line
    /// that read before reads the same, and only a line that does not is read
    /// as a quoted one. A line that is not thirteen fields, whose counts are
    /// not numbers, whose `usd` is present but not a decimal, or whose
    /// `sealed` is neither `true` nor `false`, either way, is not a row: it is
    /// skipped and the rest of the file is still read, so one bad line never
    /// costs the history.
    public static func rows(_ text: String) -> [SpendRow] {
        var rows: [SpendRow] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line == Substring(header) { continue }
            guard let row = row(split(line)) ?? quoted(line).flatMap(row) else { continue }
            rows.append(row)
        }
        return rows
    }

    static func row(_ f: [String]) -> SpendRow? {
        guard f.count == 13 else { return nil }
        let n = f[4 ... 10].compactMap { Int($0) }
        guard n.count == 7, f[12] == "true" || f[12] == "false",
              f[11].isEmpty || f[11].wholeMatch(of: /-?[0-9]+(\.[0-9]+)?/) != nil
        else { return nil }
        return SpendRow(
            seat: f[0], day: f[1], hour: f[2], model: f[3],
            counts: TokenCounts(responses: n[0], input: n[1], output: n[2], thinking: n[3],
                                cacheRead: n[4], cacheWrite5m: n[5], cacheWrite1h: n[6]),
            usd: f[11].isEmpty ? nil : Decimal(string: f[11]),
            sealed: f[12] == "true")
    }

    /// A `\n` in a seat, an account or a model as a space. Only `\n` as a
    /// `Character`, which is what splits the record into lines: a row the
    /// record already held never has one, so it is written and keyed as it
    /// was, and a `\r` or `\r\n`, which the record has always kept inside a
    /// line, stays as it was. The writer (`line`) and the merge (`key`) are
    /// the two places it applies, so every row passes through it however it
    /// was built.
    static func oneLine(_ text: String) -> String {
        text.contains("\n") ? String(text.map { $0 == "\n" ? " " : $0 }) : text
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

    /// A log file a run passes by: not written since the roll-up that
    /// counted it, and every cell it can feed sealed. Both collectors walk by
    /// this one test (`ClaudeCollector.transcripts`). With no roll-up behind
    /// the run, or no write date to read, the file is read.
    static func passedBy(_ file: URL, rolledUpAt: Date?, now: Date, calendar: Calendar) -> Bool {
        guard let rolledUpAt,
              let changed = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return false }
        return changed <= rolledUpAt && sealedThrough(lastWrite: changed, now: now, calendar: calendar)
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
    ///
    /// Rows are keyed on their text as it is written (`key`), so two fresh
    /// rows whose model differs only by a `\n` are one cell, added up, never
    /// one replacing the other.
    public static func merge(_ existing: [SpendRow], with fresh: [SpendRow],
                             now: Date, calendar: Calendar) -> [SpendRow] {
        var rows: [SpendCell: SpendRow] = [:]
        for row in existing { rows[key(row)] = row }
        var walked: [SpendCell: SpendRow] = [:]
        for row in fresh {
            let cell = key(row)
            guard let other = walked[cell] else { walked[cell] = row; continue }
            let usd = other.usd.flatMap { first in row.usd.map { first + $0 } }
            walked[cell] = SpendRow(cell: cell, counts: other.counts + row.counts, usd: usd, sealed: false)
        }
        for (cell, row) in walked {
            guard let stored = rows[cell] else { rows[cell] = row; continue }
            guard !stored.sealed,
                  !sealed(day: row.day, hour: row.hour, now: now, calendar: calendar)
            else { continue }
            rows[cell] = row
        }
        return rows.values
            .map { $0.sealing(sealed(day: $0.day, hour: $0.hour, now: now, calendar: calendar)) }
            .sorted { key($0) < key($1) }
    }

    /// A row's cell as it is written: its seat and model through `oneLine`.
    static func key(_ row: SpendRow) -> SpendCell {
        SpendCell(seat: oneLine(row.seat), day: row.day, hour: row.hour, model: oneLine(row.model))
    }
}
