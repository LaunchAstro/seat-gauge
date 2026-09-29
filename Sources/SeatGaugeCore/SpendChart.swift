import Foundation

/// One day on one line. The day is the start of a local day, because the tab
/// draws days: the hour stays in `spend.csv` and off the chart.
public struct SpendPoint: Equatable, Sendable {
    public let day: Date
    /// Tokens or list-price dollars, in the chart's measure.
    public let amount: Decimal
}

/// One account's line, or the total beside them.
public struct SpendSeries: Equatable, Sendable {
    public let name: String
    public let points: [SpendPoint]
    public var isTotal = false

    /// What hover and the hidden set name a line by. An account may itself be
    /// called `total`, so accounts carry a prefix the total never has.
    public var key: String { isTotal ? "total" : "account:\(name)" }
}

/// One heading under the chart. `amount` is nil for the unpriced heading,
/// which counts responses and never dollars.
public struct SpendGroupTotal: Equatable, Sendable {
    public let group: String
    public let amount: Decimal?
    public let responses: Int
}

/// How far back the Spend tab reaches: the last 28 days, or every day on record.
public enum SpendRange: String, CaseIterable, Sendable {
    case recent, all
}

/// One account over the whole record. A floor, not a total: use off this Mac
/// never reaches `spend.csv`.
public struct SpendAccountTotal: Equatable, Sendable {
    public let account: String
    public let tokens: Decimal
    public let activeDays: Int
    public let firstDay: Date
}

/// The lines and headings over every day on record, kept beside the recent
/// ones so a switch of range reads no file.
public struct SpendWhole: Equatable, Sendable {
    public let series: [SpendSeries]
    public let totals: [SpendGroupTotal]
    public let from: Date
    public let days: Int
}

/// What the Spend tab draws, as values, so the chart can be read without a
/// screen.
public struct SpendChart: Equatable, Sendable {
    public static let unpriced = "unpriced"

    /// The model families, and in dollars the unpriced heading after them:
    /// in tokens every token already sits in its family.
    public static func headings(_ measure: Measure) -> [String] {
        ModelFamily.allCases.map(\.rawValue) + (measure == .usd ? [unpriced] : [])
    }

    public let series: [SpendSeries]
    public let totals: [SpendGroupTotal]
    /// The first local day drawn, and how many days the range is.
    public let from: Date
    public let days: Int
    public var measure: Measure = .usd
    /// Why some of the record's lines are not drawn, when some are not.
    public var note: String? = nil
    /// Why none of the record could be drawn, in place of the empty line.
    public var unreadable: String? = nil
    /// Every day on record, and each account's floor over it.
    public var whole: SpendWhole? = nil
    public var accounts: [SpendAccountTotal] = []

    /// The same chart over `range`. With nothing older than the recent days,
    /// All draws what the recent range does.
    public func showing(_ range: SpendRange) -> SpendChart {
        guard range == .all, let whole else { return self }
        var chart = SpendChart(series: whole.series, totals: whole.totals, from: whole.from, days: whole.days,
                               measure: measure, note: note, unreadable: unreadable)
        chart.whole = whole
        chart.accounts = accounts
        return chart
    }

    /// Days between the x axis labels: a week for four weeks, and wider as the
    /// range grows so the labels keep about four to a graph.
    public var axisStride: Int { max(7, days / 28 * 7) }

    /// The dates the lines span, from the first day any line has to the end
    /// of the last. The x axis is pinned to it, so the labels below always
    /// fall on the plot. Nil when there is no line.
    public func drawn(calendar: Calendar = .current) -> ClosedRange<Date>? {
        let days = series.flatMap(\.points).map(\.day)
        guard let first = days.min(), let last = days.max(),
              let end = calendar.date(byAdding: .day, value: 1, to: last) else { return nil }
        return first...end
    }

    /// The days the x axis labels, a stride apart from the first day drawn. A
    /// label starts at its day and runs right, so one after the first with
    /// under an eighth of the span left after it would be cut at the edge and
    /// is left off.
    public func axisDays(calendar: Calendar = .current) -> [Date] {
        guard let span = drawn(calendar: calendar),
              let length = calendar.dateComponents([.day], from: span.lowerBound, to: span.upperBound).day
        else { return [] }
        return stride(from: 0, to: length, by: axisStride)
            .filter { $0 == 0 || (length - $0) * 8 >= length }
            .compactMap { calendar.date(byAdding: .day, value: $0, to: span.lowerBound) }
    }

    public var isEmpty: Bool { series.isEmpty }
    public var emptyMessage: String? { unreadable ?? (isEmpty ? "no spend recorded yet" : nil) }

    /// The lines still drawn once the hidden ones, by key, are taken out.
    public func visible(hiding hidden: Set<String>) -> [SpendSeries] {
        series.filter { !hidden.contains($0.key) }
    }

    /// The point whose drawn centre is nearest `instant`. A day is drawn at
    /// its middle, not its midnight, so the pick changes day halfway between
    /// two dots rather than at a dot.
    public static func point(nearest instant: Date, in points: [SpendPoint],
                             calendar: Calendar = .current) -> SpendPoint? {
        func distance(_ point: SpendPoint) -> TimeInterval {
            let centre = calendar.dateInterval(of: .day, for: point.day).map { $0.start + $0.duration / 2 }
            return abs((centre ?? point.day).timeIntervalSince(instant))
        }
        return points.min { distance($0) < distance($1) }
    }

    public static let empty = SpendChart(series: [], totals: [], from: .distantPast, days: 28)

    public static func read(csv: URL = SpendCSV.defaultFile, state: URL = StateStore.defaultFile,
                            attribution: URL = AttributionFile.defaultFile, rates: RateCard = .bundled,
                            measure: Measure = .usd, now: Date = Date(), calendar: Calendar = .current,
                            days: Int = 28) -> SpendChart {
        make(record: SpendCSV.read(csv, state: state), through: AttributionFile.record(at: attribution),
             rates: rates, measure: measure, now: now, calendar: calendar, days: days)
    }

    /// The record's rows under their accounts. Unattributed usage
    /// is in the total and on no account's line.
    public static func make(record: SpendRecord, through attribution: AttributionRecord,
                            rates: RateCard, measure: Measure = .usd, now: Date,
                            calendar: Calendar = .current, days: Int = 28) -> SpendChart {
        let rows = SpendAttribution(record: attribution).project(record.rows)
        let accountLines = { (series: [SpendSeries]) in series.filter { $0.name != AttributionRecord.unattributed } }
        let recent = make(rows: rows, rates: rates, measure: measure, now: now, calendar: calendar, days: days)
        var chart = SpendChart(series: accountLines(recent.series), totals: recent.totals, from: recent.from,
                               days: recent.days, measure: measure)
        let today = calendar.startOfDay(for: now)
        let first = rows.compactMap { SpendCSV.start(day: $0.day, calendar: calendar) }.filter { $0 <= today }.min()
        let span = first.flatMap { calendar.dateComponents([.day], from: $0, to: today).day }.map { $0 + 1 } ?? 0
        let all = make(rows: rows, rates: rates, measure: measure, now: now, calendar: calendar,
                       days: max(days, span))
        chart.whole = SpendWhole(series: accountLines(all.series), totals: all.totals, from: all.from, days: all.days)
        chart.accounts = accounts(rows, through: today, calendar: calendar)
        if case let .unavailable(reason) = record { chart.unreadable = reason } else { chart.note = record.reason }
        return chart
    }

    /// Each account's tokens, active days and first day, over every row on
    /// record through `today`, the days All can draw. Unattributed usage
    /// belongs to no account, so it has no floor.
    static func accounts(_ rows: [SpendRow], through today: Date, calendar: Calendar) -> [SpendAccountTotal] {
        var tokens: [String: Decimal] = [:]
        var days: [String: Set<Date>] = [:]
        for row in rows where row.seat != AttributionRecord.unattributed {
            guard let day = SpendCSV.start(day: row.day, calendar: calendar), day <= today else { continue }
            tokens[row.seat, default: 0] += Measure.tokens.amount(of: row) ?? 0
            days[row.seat, default: []].insert(day)
        }
        return days.keys.sorted().compactMap { account in
            guard let active = days[account], let first = active.min() else { return nil }
            return SpendAccountTotal(account: account, tokens: tokens[account] ?? 0, activeDays: active.count,
                                     firstDay: first)
        }
    }

    /// Rows to lines. Only the last `days` local days are drawn; the rest stay
    /// in the file, which is the record and outlives the chart.
    public static func make(rows: [SpendRow], rates: RateCard, measure: Measure = .usd, now: Date,
                            calendar: Calendar = .current, days: Int = 28) -> SpendChart {
        let today = calendar.startOfDay(for: now)
        let from = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        var lines: [String: [Date: Decimal]] = [:]
        var everyDay: [Date: Decimal] = [:]
        var money: [String: Decimal] = [:]
        var counted: [String: Int] = [:]

        for row in rows {
            guard let day = SpendCSV.start(day: row.day, calendar: calendar), day >= from, day <= today
            else { continue }
            let amount = measure.amount(of: row) ?? 0
            lines[row.seat, default: [:]][day, default: 0] += amount
            everyDay[day, default: 0] += amount
            // Family and price are separate questions: in dollars a model the
            // rate card has no price for counts its responses as unpriced.
            if measure == .usd, rates.priceStatus(for: row.model) == .unpriced {
                counted[Self.unpriced, default: 0] += row.responses
            } else {
                money[ModelFamily(model: row.model).rawValue, default: 0] += amount
                counted[ModelFamily(model: row.model).rawValue, default: 0] += row.responses
            }
        }

        var series = lines.keys.sorted().map { seat in
            SpendSeries(name: seat, points: points(lines[seat] ?? [:], calendar: calendar))
        }
        if !series.isEmpty {
            series.append(SpendSeries(name: "total", points: points(everyDay, calendar: calendar), isTotal: true))
        }
        let totals = headings(measure).map { group in
            SpendGroupTotal(group: group, amount: group == Self.unpriced ? nil : money[group] ?? 0,
                            responses: counted[group] ?? 0)
        }
        return SpendChart(series: series, totals: totals, from: from, days: days, measure: measure)
    }

    /// A line's days in order. Where days with no record fall between two
    /// that have one, the line drops to zero the day after and climbs from
    /// zero the day before, so a gap reads as no use rather than steady use.
    static func points(_ byDay: [Date: Decimal], calendar: Calendar) -> [SpendPoint] {
        var drawn: [SpendPoint] = []
        for day in byDay.keys.sorted() {
            if let last = drawn.last?.day, let after = calendar.date(byAdding: .day, value: 1, to: last),
               let before = calendar.date(byAdding: .day, value: -1, to: day), after < day {
                drawn.append(SpendPoint(day: after, amount: 0))
                if before > after { drawn.append(SpendPoint(day: before, amount: 0)) }
            }
            drawn.append(SpendPoint(day: day, amount: byDay[day] ?? 0))
        }
        return drawn
    }
}

extension Decimal {
    /// For the chart axis, which takes a `Double` and nothing else.
    public var asDouble: Double { NSDecimalNumber(decimal: self).doubleValue }

    /// Dollars and cents, for a heading a person reads.
    public var asMoney: String {
        var value = self
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        let shape = NumberFormatter()
        shape.numberStyle = .currency
        shape.currencyCode = "USD"
        shape.locale = Locale(identifier: "en_AU")
        shape.currencySymbol = "$"
        return shape.string(from: NSDecimalNumber(decimal: rounded)) ?? "$\(rounded)"
    }
}
