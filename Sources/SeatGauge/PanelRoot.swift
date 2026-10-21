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
    /// The model the Spend graph is narrowed to, picked from the list, and
    /// the chart of that model alone. Nil draws every model.
    private(set) var spendModel: String?
    /// The first day the Spend tab and the cards' charts draw, from
    /// `spendFrom` in `seats.json`. A change re-reads the record.
    var spendFrom: String? {
        didSet { if spendFrom != oldValue { readSpend() } }
    }
    private(set) var modelChart: SpendChart?

    /// A click on a model in the list draws it alone; a second click, or
    /// one on ALL, draws every model again.
    func pick(model: String?) {
        spendModel = model == spendModel ? nil : model
        drawSpend()
    }
    /// Every tab is laid out in one envelope, so a switch moves nothing.
    var tab: Tab = .seats
    var sessionLog = SessionLogFile(updated: .distantPast, sessions: [])
    /// The LOAD tab's machines and what each last read said, set by the
    /// machine loop in `main.swift`.
    var machines: [Machine] = []
    var machineStates: [String: MachineState] = [:]
    /// Each machine's last ten minutes of CPU and memory, for the hover chart.
    var machineHistory: [String: [LoadSample]] = [:]
    /// The size the whole panel is drawn at. It is held here rather than in a
    /// global because a view body that reads it is a view body that redraws
    /// when the user changes it: `Type` and `CardMetrics` both read it
    /// through `TextScale.current`.
    var textScale = TextScale.normal
    /// Read by `Tone` and `VerticalFit` in a view body, as the size is.
    var lightAppearance = false
    var verticalFactor: CGFloat = 1
    /// How many rows of cards the user's height asked for, which `CardGrid`
    /// reads as how few columns to draw. One is the plain row.
    var cardRows = 1
    /// The content's width, which `CardGrid` wraps at when it is asked for
    /// its ideal size and given no width. Zero before the first layout.
    /// Read while laying out, never in a body: the window sets it inside its
    /// own layout pass, and a change there must not redraw the panel.
    @ObservationIgnored var panelWidth: CGFloat = 0
    /// Why `seats.json` would not read, or nothing. The spend and
    /// attribution records add their own problems after it, in the title
    /// bar's order.
    var configProblem: String?
    /// Each provider's icon as a template, set once the launch has read or
    /// fetched it. A provider missing here draws no mark.
    var marks: [Provider: NSImage] = [:]
    var recordProblems: [PanelProblem] = []
    /// Why the last click on a card's name did not open its seat, kept for
    /// a minute or until the next click.
    var openProblem: String?
    var problems: [String] {
        ProblemSlot((configProblem.map { [.config($0)] } ?? []) + (openProblem.map { [.open($0)] } ?? [])
                    + recordProblems).menu
    }
    @ObservationIgnored var opener = SeatOpener()
    /// Seats whose command is inside its start check, so a double click
    /// runs it once.
    @ObservationIgnored private var opening: Set<SeatID> = []
    /// The minute timer on the shown note, cancelled by the next click so an
    /// older timer never clears a newer note.
    @ObservationIgnored private var expiry: Task<Void, Never>?
    /// How long a failure note stays up. A case shortens it so its margins
    /// are seconds wide rather than a minute long.
    @ObservationIgnored var openNoteLifetime: Duration = .seconds(60)

    /// Runs the seat's `open` command, and returns the start check for a
    /// caller that waits on it. A seat with none, or one already starting,
    /// runs nothing.
    @discardableResult
    func open(_ id: SeatID) -> Task<Void, Never>? {
        guard let seat = seats.first(where: { $0.id == id }), seat.open != nil,
              opening.insert(id).inserted else { return nil }
        expiry?.cancel()
        openProblem = nil
        return Task {
            do { try await opener.open(seat) } catch {
                openProblem = (error as? ProcessFailure)?.reason ?? "\(error)"
                expiry?.cancel()
                expiry = Task {
                    try? await Task.sleep(for: openNoteLifetime)
                    if !Task.isCancelled { openProblem = nil }
                }
            }
            opening.remove(id)
        }
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
    /// Set by `main.swift`: one read of every machine now, beside the loop's.
    var readMachines: () -> Void = {}
    /// The seats a sync or poll is reading now, which draw their icon busy.
    var syncing: Set<SeatID> = []
    /// Set by `main.swift`: one seat's Sign in from its card, through `SignIn`.
    var signIn: (SeatID) -> Void = { _ in }
    /// The seats a Sign in is running for, whose button waits.
    var signingIn: Set<SeatID> = []
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

    /// Where the user has put the cards, read at launch and changed only
    /// once the change is saved, as the Spend lines are.
    private(set) var cards = CardArrangement()
    /// Set by `main.swift`: a card on or off the window changes its height.
    var refit: () -> Void = {}

    /// The file the arrangement was last read from or saved to, which a
    /// config change prunes.
    private var cardStore = StateStore()

    func readCards(_ store: StateStore = StateStore()) {
        cardStore = store
        cards = store.load().cards
    }

    func arrange(_ change: (CardArrangement) -> CardArrangement, store: StateStore? = nil) throws {
        let store = store ?? cardStore
        cardStore = store
        let next = change(cards).kept(seats.map(\.id))
        guard next != cards else { return }
        try store.update { $0.cards = next }
        cards = next
        refit()
    }

    func move(_ id: SeatID, to target: SeatID) {
        try? arrange { $0.moving(id, to: target, configured: seats.map(\.id)) }
    }

    func hide(_ id: SeatID) {
        if hovered == id { hover(nil) }
        try? arrange { $0.hiding(id) }
    }

    func show(_ id: SeatID) { try? arrange { $0.showing(id) } }

    func apply(_ snapshot: Snapshot, seats: [Seat]) {
        self.snapshot = snapshot
        self.seats = seats
        // A seat gone from the config leaves the saved arrangement. A config
        // that did not read is the seats first launch would seed, not the
        // user's, so it prunes nothing.
        if configProblem == nil { try? arrange { $0 } }
    }

    func readSpend(csv: URL = SpendCSV.defaultFile, state: URL = StateStore.defaultFile,
                   attribution: URL = AttributionFile.defaultFile) {
        let record = SpendCSV.read(csv, state: state).from(spendFrom)
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
        let rates = RateCard.load()
        chart = SpendChart.make(record: record, through: through, rates: rates, measure: choice.measure, now: Date(),
                                start: spendFrom)
        modelChart = spendModel.map {
            SpendChart.make(record: record, through: through, rates: rates, measure: choice.measure, now: Date(),
                            model: $0, start: spendFrom)
        }
    }

    func model(at now: Date) -> PanelModel {
        let calendar = Calendar.current
        let key: [AnyHashable] = [choice.range, choice.measure, calendar.startOfDay(for: now), seats.map(\.id)]
        if histories?.key != key {
            histories = (key, PanelModel.histories(seats: seats, spend: record, through: through, choice: choice,
                                                   now: now, calendar: calendar))
        }
        return PanelModel.make(snapshot: snapshot, seats: seats, now: now, hovered: hovered, selected: selected,
                               histories: histories?.value ?? [:], syncing: syncing, pollMinutes: pollMinutes,
                               arrangement: cards)
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

/// The tabs one over the other, as tall as the tallest, and every tab
/// offered that whole height, so a shorter tab's boxes reach the bottom
/// rather than leaving an empty strip under them.
nonisolated struct TabStack: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
        return CGSize(width: proposal.width ?? sizes.map(\.width).max() ?? 0,
                      height: proposal.height ?? sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for tab in subviews {
            tab.place(at: bounds.origin, anchor: .topLeading,
                      proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
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
            let spend = mirror.tab == .spend
            let load = mirror.tab == .load
            // Every tab but the Log, the hidden ones at no opacity and out of
            // reach of the pointer, so the window is the tallest of them on any.
            TabStack {
                Group {
                    if let message = model.emptyMessage {
                        EmptyState(message: message, notes: model.notes)
                    } else {
                        ComboLayout(cards: model.cards, summary: model.summary, details: model.details, hovered: model.hovered)
                    }
                }
                .opacity(seats ? 1 : 0).allowsHitTesting(seats).accessibilityHidden(!seats)
                SpendTab(chart: mirror.chart, focus: mirror.modelChart)
                    .opacity(spend ? 1 : 0).allowsHitTesting(spend).accessibilityHidden(!spend)
                LoadTab()
                    .opacity(load ? 1 : 0).allowsHitTesting(load).accessibilityHidden(!load)
            }
            // The Log fills the other tabs' height and never sets it, and is
            // drawn only while it is open: its list is every session, laid
            // out whole, and every measure of the window would lay it out again.
            .overlay {
                if mirror.tab == .log { LogTab(log: mirror.sessionLog) }
            }
            .fixedSize(horizontal: false, vertical: true)
            // The title bar's row is never narrower than itself.
            .frame(minWidth: mirror.chromeMinimum, maxWidth: .infinity)
            .foregroundStyle(Tone.ink)
            .background(Tone.bg.ignoresSafeArea())
        }
    }
}
