import Foundation

/// The two lines every meter is graded on when no pace grades it: used from
/// 60 percent is a warning, from 85 danger. `MachineSummary.room` reads CPU
/// and memory against the same two.
public enum MeterLines {
    public static let warning = 60
    public static let danger = 85
}

extension WindowKind {
    /// The card's row label.
    public var shortName: String {
        switch self {
        case .fiveHour: "5H"
        case .weekly: "WK"
        case .fable: "FABLE"
        }
    }

    /// The word `seatgauge-cli` prints for it.
    public var word: String {
        switch self {
        case .fiveHour: "5h"
        case .weekly: "week"
        case .fable: "fable"
        }
    }
}

/// One window as a seat shows it. A Claude reply whose 5-hour window has no
/// reset is one nobody has started yet: none of it is used and all five hours
/// are ahead. The reading leaves it out, so the view puts it back with no
/// reset rather than losing the row.
public struct WindowView: Equatable, Sendable {
    public let kind: WindowKind
    public let usedPercent: Int
    /// Nil while the window is not started.
    public let resetsAt: Date?
    public let length: Duration
    /// The window as read, which `Pace` and `PaceGrade` read. Nil while it is
    /// not started.
    public let window: Window?

    public var left: Int { 100 - usedPercent }

    /// The countdown to the reset, or to the whole length while not started.
    public func countdown(now: Date) -> String {
        Countdown.text(until: resetsAt ?? now.addingTimeInterval(length.seconds), now: now)
    }

    public init(_ window: Window) {
        kind = window.kind
        usedPercent = window.usedPercent
        resetsAt = window.resetsAt
        length = window.length
        self.window = window
    }

    init(unstarted kind: WindowKind, length: Duration) {
        self.kind = kind
        usedPercent = 0
        resetsAt = nil
        self.length = length
        window = nil
    }

    /// A reading's windows in display order, with an unstarted Claude 5-hour
    /// window first where the reply left it out.
    public static func of(_ reading: Reading, provider: Provider) -> [WindowView] {
        let windows = reading.windows.sorted { $0.kind < $1.kind }
        let unstarted = provider == .claude && !windows.isEmpty && !windows.contains { $0.kind == .fiveHour }
        return (unstarted ? [WindowView(unstarted: .fiveHour, length: .seconds(5 * 3600))] : [])
            + windows.map(WindowView.init)
    }
}

extension SeatState {
    /// The reading this state holds: the live one, or the last one before a
    /// read failed.
    public var lastReading: Reading? {
        switch self {
        case let .live(reading): reading
        case let .unreadable(_, last): last
        case .dormant: nil
        }
    }

    /// Live and read less than two poll intervals ago. Anything else is
    /// stale to a reader: a failed read, a dormant seat, or figures two
    /// intervals old or more.
    public func isFresh(now: Date, pollMinutes: Int) -> Bool {
        guard case let .live(reading) = self else { return false }
        return now.timeIntervalSince(reading.takenAt) < 2 * 60 * Double(pollMinutes)
    }

    /// A seat the synced line counts: any but a dormant one, which is not
    /// drawn and has nothing to sync.
    public var canSync: Bool {
        if case .dormant = self { return false }
        return true
    }
}

/// What one seat shows, the same to every front end: the card draws it,
/// `headroom.json` writes it and `seatgauge-cli` prints it. Colours and layout
/// are the app's; every rule about what is shown is here.
public struct SeatView: Equatable, Sendable, Identifiable {
    public let id: SeatID
    /// The config's label, or the id when it has none: an empty label is not
    /// a name, so a card never draws the provider alone.
    public let label: String
    /// The seat as the config declares it, or nil for one only the snapshot names.
    public let seat: Seat?
    /// From the kind, never the label, so a seat named anything still reads as
    /// the CLI it is.
    public let provider: Provider
    public let state: SeatState?
    /// The reading the state holds, live or last held. `headroom.json` writes
    /// only this.
    public let last: Reading?
    /// What a card draws: `last`, or for a dormant seat what it last reported.
    public let shown: Reading?
    /// `shown`'s windows, an unstarted 5-hour one included.
    public let windows: [WindowView]
    public let fresh: Bool
    /// The login's tier, then the config's word, then the wire's, then nothing.
    public let plan: String?
    public let account: String?
    /// Why the card is dimmed: the age of a failed read's figures, "signed
    /// out", or why the seat has nothing now. Nil on a live card.
    public let stale: String?
    /// The weekly verdict. Nil on a stale card, whose pace is yesterday's.
    public let pace: Pace?
    /// True when a front end offers Sign in, by `SeatLogin.offers`.
    public let signsIn: Bool
    /// False for a token seat, which is read only when the user syncs it.
    public let polls: Bool
    /// A token seat's age, since the synced line leaves it out.
    public let dated: String?
    public let isBest: Bool
    /// Why the seat is off the window, or nil when a card draws it.
    public let offstage: String?

    /// The stale line of a seat that signed itself out.
    public static let signedOut = "signed out"

    public init(id: SeatID, seat: Seat?, snapshot: Snapshot, now: Date,
                arrangement: CardArrangement = CardArrangement(), best: SeatID? = nil, pollMinutes: Int = 5) {
        let state = snapshot.states[id]
        self.id = id
        self.seat = seat
        self.state = state
        if let label = seat?.label, !label.isEmpty { self.label = label } else { label = id.rawValue }
        let provider = seat?.kind.provider ?? .claude
        self.provider = provider
        last = state?.lastReading
        shown = last ?? snapshot.reported[id]
        windows = shown.map { WindowView.of($0, provider: provider) } ?? []
        fresh = state?.isFresh(now: now, pollMinutes: pollMinutes) ?? false
        plan = PlanText.resolve(tier: shown?.tier, declared: seat?.plan, wire: shown?.plan)
        account = PlanText.said(seat?.account)
        signsIn = SeatLogin.offers(seat, state)
        polls = seat?.pollsAutomatically ?? true
        isBest = best == id
        var stale: String?
        var offstage: String?
        switch state {
        case .live:
            break
        case let .unreadable(_, last?):
            stale = "stale · \(Countdown.text(until: now, now: last.takenAt))"
        case let .dormant(why), let .unreadable(why, nil):
            // Drawn only when the user asked for it. A seat that signed itself
            // out is drawn anyway, so its loss is seen the moment it happens.
            stale = signsIn ? Self.signedOut : why
            if !signsIn && !arrangement.shown.contains(id) { offstage = why }
        case nil:
            offstage = "not read yet"
        }
        // A hidden seat is still read and still in `headroom.json`; it is only
        // off the window, the ALL card and the pick.
        if arrangement.hidden.contains(id) { offstage = "hidden" }
        self.stale = stale
        self.offstage = offstage
        let weekly = windows.first { $0.kind == .weekly }?.window
        pace = stale == nil ? weekly.flatMap { Pace(weekly: $0, now: now) } : nil
        dated = polls || stale != nil ? nil : shown.map { "synced \(Countdown.text(until: now, now: $0.takenAt)) ago" }
    }
}

extension WindowView {
    /// The window as `seatgauge-cli` prints it: the kind, the count-up
    /// percentage and how long until it resets. Seconds are never shown.
    public func describe(now: Date) -> String {
        "\(kind.word) \(usedPercent)% " + (resetsAt == nil ? "not started" : "resets in \(countdown(now: now))")
    }
}

extension SeatView {
    /// The seat as `seatgauge-cli` prints it, with the same windows its card
    /// draws, a failed read's held ones included.
    public func describe(now: Date) -> String {
        let shown = windows.map { $0.describe(now: now) }.joined(separator: ", ")
        switch state {
        case .live:
            return "live    " + shown
        case let .dormant(reason):
            return "dormant \(reason)"
        case let .unreadable(reason, last):
            return "stale   \(reason)" + (last == nil ? "" : ", last read held: " + shown)
        case nil:
            return "not read yet"
        }
    }
}

/// Every seat's view, in the user's arrangement, and the title bar's synced
/// line over them.
public struct GaugeView: Equatable, Sendable {
    /// The configured seats, then any the snapshot alone names, in the user's
    /// order. Hidden and offstage seats are here with their `offstage` reason.
    public let seats: [SeatView]
    public let synced: String

    public init(snapshot: Snapshot, seats declared: [Seat], now: Date, pollMinutes: Int = 5,
                arrangement: CardArrangement = CardArrangement()) {
        let byID = Dictionary(declared.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // The config's seats, so one with no restored reading is offered by
        // the `+` before the first poll, then any the snapshot alone names.
        let configured = declared.map(\.id) + snapshot.order.filter { byID[$0] == nil }
        let arranged = arrangement.arranged(configured)
        let best = Snapshot(states: snapshot.states, order: arranged.filter { !arrangement.hidden.contains($0) }).best
        seats = arranged.map {
            SeatView(id: $0, seat: byID[$0], snapshot: snapshot, now: now, arrangement: arrangement, best: best,
                     pollMinutes: pollMinutes)
        }
        let polled = seats.filter { $0.offstage != "hidden" && $0.polls && $0.state?.canSync == true }
            .compactMap(\.state)
        synced = Self.synced(polled, now: now, pollMinutes: pollMinutes)
    }

    /// The synced line over the seats that poll themselves: all of them fresh
    /// says how old the oldest is, else how many are.
    static func synced(_ states: [SeatState], now: Date, pollMinutes: Int) -> String {
        guard !states.isEmpty else { return "not polled yet" }
        let fresh = states.filter { $0.isFresh(now: now, pollMinutes: pollMinutes) }.compactMap(\.lastReading)
        guard fresh.count == states.count, let oldest = fresh.map(\.takenAt).min() else {
            return "\(fresh.count) of \(states.count) synced"
        }
        return "all seats synced \(Countdown.text(until: now, now: oldest)) ago"
    }
}
