import Foundation

/// What the Spend tab is drawing, in one value: the range it shows, the
/// measure (which the cards' history charts share), the one model the graph
/// is narrowed to, and the lines clicked off in the legend.
public struct SpendChoices: Equatable, Sendable {
    public var range: SpendRange
    public var measure: Measure
    /// Nil draws every model.
    public var model: String?
    public var hidden: Set<String>

    public init(range: SpendRange = .recent, measure: Measure = .tokens, model: String? = nil,
                hidden: Set<String> = []) {
        self.range = range
        self.measure = measure
        self.model = model
        self.hidden = hidden
    }

    /// A click on a model draws it alone; a second click, or one on ALL
    /// (nil), draws every model again.
    public func picking(_ model: String?) -> SpendChoices {
        var next = self
        next.model = model == self.model ? nil : model
        return next
    }
}

/// The spend record as the panel reads it: `spend.csv` from the day
/// `spendFrom` names, through `attribution.json`, priced on one rate card,
/// all read once. Every chart, history and problem the panel shows is
/// answered from this one read. It only reads: `spend.csv` is
/// `SpendCoordinator`'s alone to write (ADR 0004).
public struct SpendView: Sendable {
    public let record: SpendRecord
    /// The attribution record, or for a missing or malformed file one with no
    /// spans, so every main login cell is unattributed.
    public let attribution: AttributionRecord
    public let rates: RateCard
    /// `spendFrom`, the first day the record is read from.
    public let start: String?
    /// What reading the two records raised, for the title bar.
    public let problems: [PanelProblem]
    /// The legend lines saved as clicked off.
    public let hiddenLines: Set<String>

    public init(record: SpendRecord, attribution: AttributionFile.Read, rates: RateCard, start: String? = nil,
                rebuilt: Bool = false, hiddenLines: Set<String> = [], zone: TimeZone = .current) {
        self.record = record.from(start)
        self.attribution = attribution.kept(zone: zone)
        self.rates = rates
        self.start = start
        self.hiddenLines = hiddenLines
        problems = PanelProblem.reading(spend: self.record, attribution: attribution, zone: zone, rebuilt: rebuilt)
    }

    /// The three files and the rate card, each read once.
    public static func read(csv: URL = SpendCSV.defaultFile, state: URL = StateStore.defaultFile,
                            attribution: URL = AttributionFile.defaultFile, rates: RateCard = .load(),
                            start: String? = nil, zone: TimeZone = .current) -> SpendView {
        let kept = StateStore(file: state).load()
        return SpendView(record: SpendCSV.read(csv, state: state), attribution: AttributionFile.read(attribution),
                         rates: rates, start: start, rebuilt: kept.spendRebuiltAt != nil,
                         hiddenLines: kept.hiddenSpendLines, zone: zone)
    }

    /// The Spend tab's chart in the chosen measure, of the picked model alone
    /// when `model` is set.
    public func chart(measure: Measure, model: String? = nil, now: Date,
                      calendar: Calendar = .current, days: Int = 28) -> SpendChart {
        SpendChart.make(record: record, through: attribution, rates: rates, measure: measure, now: now,
                        calendar: calendar, days: days, model: model, start: start)
    }

    /// The narrowed chart for the picked model, or nil when none is picked.
    public func modelChart(_ choices: SpendChoices, now: Date, calendar: Calendar = .current) -> SpendChart? {
        choices.model.map { chart(measure: choices.measure, model: $0, now: now, calendar: calendar) }
    }

    /// The list beside the graph: every model, given the lines clicked off.
    public func modelRows(_ chart: SpendChart, _ choices: SpendChoices) -> [SpendModelRow] {
        chart.modelRows(hiding: choices.hidden)
    }

    /// One seat's history chart, by its name in the record.
    public func history(seat: String, range: HistoryRange, measure: Measure, now: Date,
                        calendar: Calendar = .current) -> SeatHistory {
        SeatHistory.make(record: record, through: attribution, seat: seat, range: range, measure: measure,
                         now: now, calendar: calendar, rates: rates)
    }
}

extension AttributionFile.Read {
    /// The record to project spend through. A missing or malformed file holds
    /// no spans, so every main login cell stays unattributed rather than
    /// landing on a guessed account.
    public func kept(zone: TimeZone = .current) -> AttributionRecord {
        if case let .record(record) = self { return record }
        return AttributionRecord(timeZone: zone.identifier)
    }
}
