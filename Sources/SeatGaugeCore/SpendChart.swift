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
        var chart = make(rows: rows, rates: rates, measure: measure, now: now, calendar: calendar, days: days)
        let lines = chart.series.filter { $0.name != AttributionRecord.unattributed }
        if lines.count < chart.series.count {
            chart = SpendChart(series: lines, totals: chart.totals, from: chart.from, days: chart.days,
                               measure: measure)
        }
        if case let .unavailable(reason) = record { chart.unreadable = reason } else { chart.note = record.reason }
        return chart
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
            SpendSeries(name: seat, points: points(lines[seat] ?? [:]))
        }
        if !series.isEmpty {
            series.append(SpendSeries(name: "total", points: points(everyDay), isTotal: true))
        }
        let totals = headings(measure).map { group in
            SpendGroupTotal(group: group, amount: group == Self.unpriced ? nil : money[group] ?? 0,
                            responses: counted[group] ?? 0)
        }
        return SpendChart(series: series, totals: totals, from: from, days: days, measure: measure)
    }

    static func points(_ byDay: [Date: Decimal]) -> [SpendPoint] {
        byDay.keys.sorted().map { SpendPoint(day: $0, amount: byDay[$0] ?? 0) }
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
