import SeatGaugeCore
import SwiftUI

/// `GaugeStore` is an actor in Core, so the views read it through this mirror:
/// the last snapshot and the seats it was read against, held on the main actor.
/// The countdowns are not kept here, because they are a function of the moment
/// the root is drawn at, which the minute tick hands in.
@Observable final class GaugeMirror {
    static let shared = GaugeMirror()

    private(set) var snapshot = Snapshot(states: [:], order: [])
    private(set) var seats: [Seat] = []
    /// What the Spend tab draws, read off `spend.csv` at launch and after
    /// every roll-up. The file is the record; this is a reading of it.
    private(set) var chart = SpendChart.empty
    /// Both tabs are laid out in one envelope, so a switch moves nothing.
    var tab: Tab = .seats
    /// The size the whole panel is drawn at. It is held here rather than in a
    /// global because a view body that reads it is a view body that redraws
    /// when the user changes it: `Type` and `CardMetrics` both read it
    /// through `TextScale.current`.
    var textScale = TextScale.normal
    /// Read by `Tone` and `VerticalFit` in a view body, as the size is.
    var lightAppearance = false
    var verticalFactor: CGFloat = 1
    /// Why `seats.json` would not read, or nothing. The spend and
    /// attribution records add their own problems after it, in the title
    /// bar's order.
    var configProblem: String?
    /// Each provider's icon as a template, set once the launch has read or
    /// fetched it. A provider missing here draws no mark.
    var marks: [Provider: NSImage] = [:]
    var recordProblems: [PanelProblem] = []
    var problems: [String] {
        ProblemSlot((configProblem.map { [.config($0)] } ?? []) + recordProblems).menu
    }
    /// Whether the title bar has room for its title and its status line, and
    /// the narrowest the row can be, all set by the window as it lays the bar
    /// out.
    var titleShown = true
    var statusShown = true
    var chromeMinimum: CGFloat = 0
    /// Set by `main.swift` once the poller exists: one seat's sync from its
    /// card, every seat's from the title bar and the menu.
    var sync: (SeatID) -> Void = { _ in }
    var syncAll: () -> Void = {}
    /// The seats a sync or poll is reading now, which draw their icon busy.
    var syncing: Set<SeatID> = []
    /// The poll interval, which the synced line judges an age against.
    var pollMinutes = 5
    /// The card under the pointer and the bucket under it.
    private(set) var hovered: SeatID?
    private(set) var selected: Int?
    var choice = DetailChoice()
    /// What the last `readSpend` met, so a hover reads no file.
    private(set) var record: SpendRecord?
    private(set) var through: AttributionRecord?
    /// The histories for one record, choice and day, which the pointer
    /// and the minute tick outlast.
    @ObservationIgnored private var histories: (key: [AnyHashable], value: [SeatID: SeatHistory])?

    /// Another card, or none, drops the last one's selected bucket.
    func hover(_ id: SeatID?) {
        if id != hovered { selected = nil }
        hovered = id
    }

    func select(_ index: Int?) { if index != selected { selected = index } }

    func choose(range: HistoryRange, store: StateStore = StateStore()) throws {
        choice.range = range
        try store.update { $0.historyRange = range }
    }

    func choose(measure: Measure, store: StateStore = StateStore()) throws {
        choice.measure = measure
        try store.update { $0.measure = measure }
        drawSpend()
    }

    /// The Spend tab's measure, which is the card detail's: setting it goes
    /// through `choose(measure:)`, so the two never disagree.
    var measure: Measure {
        get { choice.measure }
        set { try? choose(measure: newValue, store: measureStore) }
    }
    var measureStore = StateStore()
    /// The key of the Spend line the pointer is on, over the line or its
    /// legend entry.
    var spendFocus: String?
    /// The focused line's point under the pointer, which draws its callout.
    var spendPoint: SpendPoint?
    /// The Spend lines clicked off in the legend, read with the record.
    private(set) var hiddenLines: Set<String> = []

    /// Turns one Spend line off, or back on, by key. The panel changes only
    /// once the choice is saved, so what it shows is what a relaunch shows.
    func toggle(line: String, store: StateStore = StateStore()) throws {
        let hidden = hiddenLines.symmetricDifference([line])
        try store.update { $0.hiddenSpendLines = hidden }
        hiddenLines = hidden
        if spendFocus == line, hidden.contains(line) { spendFocus = nil; spendPoint = nil }
    }

    func apply(_ snapshot: Snapshot, seats: [Seat]) {
        self.snapshot = snapshot
        self.seats = seats
    }

    func readSpend(csv: URL = SpendCSV.defaultFile, state: URL = StateStore.defaultFile,
                   attribution: URL = AttributionFile.defaultFile) {
        let record = SpendCSV.read(csv, state: state)
        let spans = AttributionFile.read(attribution)
        // A missing or malformed record holds no spans: every main login
        // cell is unattributed.
        var through = AttributionRecord(timeZone: TimeZone.current.identifier)
        if case let .record(kept) = spans { through = kept }
        self.record = record
        self.through = through
        histories = nil
        drawSpend()
        let kept = StateStore(file: state).load()
        hiddenLines = kept.hiddenSpendLines
        recordProblems = PanelProblem.reading(spend: record, attribution: spans, rebuilt: kept.spendRebuiltAt != nil)
    }

    /// The Spend tab from the last record read, in the chosen measure.
    func drawSpend() {
        guard let record, let through else { return }
        chart = SpendChart.make(record: record, through: through, rates: RateCard.load(),
                                measure: choice.measure, now: Date())
    }

    func model(at now: Date) -> PanelModel {
        let calendar = Calendar.current
        let key: [AnyHashable] = [choice.range, choice.measure, calendar.startOfDay(for: now), seats.map(\.id)]
        if histories?.key != key {
            histories = (key, PanelModel.histories(seats: seats, spend: record, through: through, choice: choice,
                                                   now: now, calendar: calendar))
        }
        return PanelModel.make(snapshot: snapshot, seats: seats, now: now, hovered: hovered, selected: selected,
                               histories: histories?.value ?? [:], syncing: syncing, pollMinutes: pollMinutes)
    }
}

/// Nothing readable: one line, and every reason under it, since the menu is a
/// right click away and this is the whole panel.
struct EmptyState: View {
    let message: String
    let notes: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message).font(Type.display(13)).foregroundStyle(Tone.ink)
            ForEach(notes, id: \.self) { note in
                Text(note).font(Type.mono(9)).foregroundStyle(Tone.inkMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct Root: View {
    var mirror = GaugeMirror.shared

    var body: some View {
        // Aligned to the wall-clock minute, so every countdown turns over
        // together rather than a minute after whenever the app started.
        SwiftUI.TimelineView(.periodic(from: PanelClock.nextMinute(after: Date()), by: 60)) { tick in
            let model = mirror.model(at: tick.date)
            let seats = mirror.tab == .seats
            // Both tabs, the hidden one at no opacity and out of reach of the
            // pointer, so the window is the taller of the two on either.
            ZStack(alignment: .top) {
                Group {
                    if let message = model.emptyMessage {
                        EmptyState(message: message, notes: model.notes)
                    } else {
                        ComboLayout(cards: model.cards, summary: model.summary, details: model.details, hovered: model.hovered)
                    }
                }
                .opacity(seats ? 1 : 0).allowsHitTesting(seats).accessibilityHidden(!seats)
                SpendTab(chart: mirror.chart)
                    .opacity(seats ? 0 : 1).allowsHitTesting(!seats).accessibilityHidden(seats)
            }
            .fixedSize(horizontal: false, vertical: true)
            // The title bar's row is never narrower than itself.
            .frame(minWidth: mirror.chromeMinimum, maxWidth: .infinity)
            .foregroundStyle(Tone.ink)
            .background(Tone.bg.ignoresSafeArea())
        }
    }
}
