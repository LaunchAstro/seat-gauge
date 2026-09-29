import Foundation

extension Measure {
    /// The one measure the card detail and the Spend tab share.
    /// Tokens are fresh input, output and cache writes: cache reads are left
    /// out, and thinking is already inside output. Dollars are the row's list
    /// price, nil where the rate card has none.
    public func amount(of row: SpendRow) -> Decimal? {
        switch self {
        case .tokens: Decimal(row.input + row.output + row.cacheWrite5m + row.cacheWrite1h)
        case .usd: row.usd
        }
    }

    /// `1.2M tokens`, `380K tokens` or `$41.20`.
    public func figure(_ amount: Decimal) -> String {
        guard self == .tokens else { return amount.asMoney }
        let count = amount.asDouble
        let short = switch count {
        case 1_000_000...: String(format: "%.1fM", count / 1_000_000)
        case 1_000...: String(format: "%.0fK", count / 1_000)
        default: String(format: "%.0f", count)
        }
        return short + " tokens"
    }
}

extension HistoryRange {
    /// How many buckets the range draws.
    public var count: Int {
        switch self {
        case .week: 7
        case .month: 30
        case .halfYear: 26
        case .year: 12
        }
    }

    var unit: Calendar.Component {
        switch self {
        case .week, .month: .day
        case .halfYear: .weekOfYear
        case .year: .month
        }
    }

    /// Where each bucket starts, oldest first; the last holds now. Weeks start
    /// on Monday whatever the machine's first weekday is.
    public func starts(now: Date, calendar: Calendar) -> [Date] {
        var calendar = calendar
        calendar.firstWeekday = 2
        let current = calendar.dateInterval(of: unit, for: now)?.start
            ?? calendar.startOfDay(for: now)
        return (0 ..< count).reversed().compactMap { calendar.date(byAdding: unit, value: -$0, to: current) }
    }

    /// `Wed 23 Sep`, `wk of 21 Sep` or `Aug 2026`, in English whatever the
    /// machine's locale, so the short month always reads `Sep`.
    func label(_ start: Date, calendar: Calendar) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = calendar.timeZone
        switch unit {
        case .day: format.dateFormat = "EEE d MMM"
        case .weekOfYear: format.dateFormat = "'wk of' d MMM"
        default: format.dateFormat = "MMM yyyy"
        }
        return format.string(from: start)
    }
}

/// One bar of a seat's history.
public struct HistoryBucket: Equatable, Sendable {
    public let start: Date
    public let label: String
    public let amount: Decimal
    public let figure: String

    /// What the status line says while the bar is selected.
    public var readOut: String { "\(label) · \(figure)" }
}

/// One seat's usage over a range, in one measure, as the card detail draws
/// it. Record integrity is the outcome's to say; usage attribution
/// cannot place is simply not this seat's, and never makes it partial.
public struct SeatHistory: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case available([HistoryBucket])
        /// The record read cleanly and holds nothing for this seat in range.
        case empty
        case partial([HistoryBucket], String)
        case unavailable(String)

        public var buckets: [HistoryBucket] {
            switch self {
            case let .available(buckets), let .partial(buckets, _): buckets
            case .empty, .unavailable: []
            }
        }
    }

    public let seat: String
    public let range: HistoryRange
    public let measure: Measure
    public let outcome: Outcome
    /// In dollars: the seat used something in range, and none of it has a
    /// list price, so a plot of zeros would read as no use.
    public let noListPrice: Bool

    public static func make(record: SpendRecord, through attribution: AttributionRecord, seat: String,
                            range: HistoryRange, measure: Measure, now: Date,
                            calendar: Calendar = .current) -> SeatHistory {
        func value(_ outcome: Outcome, noListPrice: Bool = false) -> SeatHistory {
            SeatHistory(seat: seat, range: range, measure: measure, outcome: outcome, noListPrice: noListPrice)
        }
        if case let .unavailable(reason) = record { return value(.unavailable(reason)) }

        let starts = range.starts(now: now, calendar: calendar)
        let end = starts.last.flatMap { calendar.date(byAdding: range.unit, value: 1, to: $0) } ?? now
        var sums = [Decimal](repeating: 0, count: starts.count)
        var used = false, priced = false, undated = 0
        for row in SpendAttribution(record: attribution).project(record.rows) {
            guard let day = SpendCSV.start(day: row.day, calendar: calendar) else { undated += 1; continue }
            guard row.seat == seat, let first = starts.first, day >= first, day < end,
                  let index = starts.lastIndex(where: { $0 <= day }) else { continue }
            used = true
            priced = priced || row.usd != nil
            sums[index] += measure.amount(of: row) ?? 0
        }
        let buckets = zip(starts, sums).map { start, sum in
            HistoryBucket(start: start, label: range.label(start, calendar: calendar), amount: sum,
                          figure: measure.figure(sum))
        }
        let noListPrice = measure == .usd && used && !priced
        if let reason = record.reason { return value(.partial(buckets, reason), noListPrice: noListPrice) }
        if undated > 0 {
            let reason = "spend.csv: \(undated) row\(undated == 1 ? "" : "s") with no date"
            return value(.partial(buckets, reason), noListPrice: noListPrice)
        }
        return value(used ? .available(buckets) : .empty, noListPrice: noListPrice)
    }
}
