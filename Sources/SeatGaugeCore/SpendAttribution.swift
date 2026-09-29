import Foundation

/// Reading `spend.csv` through `attribution.json` (ADR 0004): the
/// record stays keyed as the roll-up wrote it and is never rewritten, and
/// each hourly cell is given an account as it is read.
public struct SpendAttribution: Sendable {
    /// The directory the roll-up files the main login's usage under.
    public static let mainDirectory = "default"

    public let record: AttributionRecord
    let zone: TimeZone?

    public init(record: AttributionRecord) {
        self.record = record
        zone = TimeZone(identifier: record.timeZone)
    }

    /// The account a cell belongs to. A directory the record keeps spans for
    /// is read through them; any other is its own seat's, since the roll-up
    /// files a seat's profile under the seat's id, except the main login's,
    /// which with no spans belongs to nobody it can prove.
    public func account(directory: String, day: String, hour: String) -> String {
        guard let spans = record.directories[directory] else {
            return directory == Self.mainDirectory ? AttributionRecord.unattributed : directory
        }
        guard let cell = interval(day: day, hour: hour) else { return AttributionRecord.unattributed }
        let touching = spans.filter { $0.from < cell.end && cell.start < $0.end }
        guard touching.count == 1, let span = touching.first,
              span.from <= cell.start, cell.end <= span.end
        else { return AttributionRecord.unattributed }
        return span.account
    }

    /// The same rows, each filed under its account in place of its directory.
    public func project(_ rows: [SpendRow]) -> [SpendRow] {
        rows.map { row in
            SpendRow(seat: account(directory: row.seat, day: row.day, hour: row.hour), day: row.day,
                     hour: row.hour, model: row.model, counts: row.counts, usd: row.usd, sealed: row.sealed)
        }
    }

    /// The hour a cell names, in the record's stored zone, as instants. Nil
    /// for an hour that zone skips or repeats, or a zone it cannot name.
    func interval(day: String, hour: String) -> DateInterval? {
        guard let zone else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let hour = Int(hour) else { return nil }
        let asked = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour)
        guard let start = calendar.date(from: asked) else { return nil }
        let met = calendar.dateComponents([.year, .month, .day, .hour], from: start)
        guard met.year == asked.year, met.month == asked.month, met.day == asked.day, met.hour == hour
        else { return nil }
        // A repeated hour is met again an hour before or after itself.
        for step in [-3600.0, 3600] where calendar.component(.hour, from: start + step) == hour {
            return nil
        }
        return DateInterval(start: start, duration: 3600)
    }
}
