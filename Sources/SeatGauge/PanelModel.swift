import Foundation
import SeatGaugeCore
import SwiftUI

/// Everything the panel draws, as values. The views draw this model rather
/// than a snapshot, so a case reads the card the user sees without a screen.

extension WindowKind {
    /// The row labels.
    var shortName: String {
        switch self {
        case .fiveHour: "5H"
        case .weekly: "WK"
        case .fable: "FABLE"
        }
    }
}

/// The meter's colour: the used percent on two thresholds, or on a weekly
/// line with a pace, the pace's grade.
enum MeterTone: Equatable {
    case good, warning, danger

    static func of(usedPercent: Int) -> MeterTone {
        usedPercent >= 85 ? .danger : usedPercent >= 60 ? .warning : .good
    }

    static func of(_ window: SeatGaugeCore.Window, now: Date) -> MeterTone {
        guard window.kind == .weekly, let grade = PaceGrade(weekly: window, now: now) else {
            return .of(usedPercent: window.usedPercent)
        }
        switch grade {
        case .good: return .good
        case .warning: return .warning
        case .danger: return .danger
        }
    }

    var color: Color {
        switch self {
        case .good: Tone.success
        case .warning: Tone.warning
        case .danger: Tone.danger
        }
    }
}

/// One window on one card: the name, the bar, the countdown and the percent.
struct WindowLine: Equatable, Identifiable {
    let kind: WindowKind
    let usedPercent: Int
    let countdown: String
    /// The countdown is to the moment the window runs dry at this pace, not
    /// to its reset. Only the ALL card draws one.
    var runsOut = false
    var tone: MeterTone

    init(kind: WindowKind, usedPercent: Int, countdown: String, runsOut: Bool = false, tone: MeterTone? = nil) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.countdown = countdown
        self.runsOut = runsOut
        self.tone = tone ?? .of(usedPercent: usedPercent)
    }

    var id: WindowKind { kind }
    var name: String { kind.shortName }
    var fill: Double { Double(usedPercent) / 100 }
}

/// A line's tone: the pace verdicts', and the detail face's other lines'.
enum LineTone: Equatable {
    case ink, muted, dim, amber, green, warning

    var color: Color {
        switch self {
        case .ink: Tone.ink
        case .muted: Tone.inkMuted
        case .dim: Tone.inkDim
        case .amber, .warning: Tone.warning
        case .green: Tone.success
        }
    }
}

/// The three pace verdicts, in words, over `Pace`. There is no line for a week nothing has been
/// spent in, which is what `Pace` returning nil means.
struct PaceLine: Equatable {
    let text: String
    let tone: LineTone

    init?(weekly window: SeatGaugeCore.Window?, now: Date) {
        guard let window, let pace = Pace(weekly: window, now: now) else { return nil }
        switch pace {
        case let .runsOut(at):
            text = "runs out \(Clock12.text(at, now: now)) at this rate"
            tone = .amber
        case let .unused(percent):
            text = "\(percent)% will go unused at this rate"
            tone = .muted
        case .onPace:
            text = "on pace to use it all"
            tone = .green
        }
    }
}

/// A twelve-hour time, taking the instant it reads "today" against.
enum Clock12 {
    static func text(_ date: Date, now: Date) -> String {
        let shape = DateFormatter()
        shape.locale = Locale(identifier: "en_AU")
        shape.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "h:mma" : "EEE h:mma"
        return shape.string(from: date).lowercased()
    }
}

/// One seat's card. A stale card carries the age of its last reading in place
/// of the pace line and is never the best: its numbers are from before
/// whatever went wrong.
struct CardModel: Identifiable, Equatable {
    let id: SeatID
    /// The seat, as the config names it: second in the header, after the
    /// provider.
    let label: String
    let isBest: Bool
    let lines: [WindowLine]
    let pace: PaceLine?
    let stale: String?
    /// Which provider the seat is, from its kind and never from its label, so
    /// a seat named anything at all still reads as the CLI it is.
    let mark: Provider
    /// Whose account the card is, when the config declares one. The app never
    /// guesses it, so nothing declared is nothing drawn.
    let account: String?
    /// What the card pays for: the login's own tier, then the config's word,
    /// then the wire's, then nothing at all. Never "Free" where
    /// nobody reported it.
    let plan: String?
    /// A token seat's age, since it is read only when the user syncs it and
    /// the title bar's synced line leaves it out.
    var dated: String?
    /// True while a sync or poll is reading this seat.
    var isSyncing = false
    /// True when the card offers Sign in, by `SeatLogin.offers`.
    var signsIn = false

    var isDimmed: Bool { stale != nil }

    /// The provider's name, first in the header.
    var provider: String { mark.name }

    /// The header as it reads, provider first and the seat beside it:
    /// `CLAUDE  personal`.
    var heading: String { "\(provider.uppercased())  \(label)" }

    /// The header's seat name: the label, and on the detail face the
    /// account where the config declares one.
    func seat(on face: CardFace) -> String {
        face == .detail ? account ?? label : label
    }
}

/// The ALL card: every live seat's 5-hour and weekly windows averaged, each
/// line's countdown to its run-out where the pace says it runs dry before the
/// reset, and the weekly verdict under them. Drawn only over two or more live
/// seats, since one seat's average is its own card.
struct SummaryModel: Equatable {
    let lines: [WindowLine]
    let pace: PaceLine?

    static let label = "ALL"

    static func make(_ readings: [Reading], now: Date) -> SummaryModel? {
        guard readings.count >= 2 else { return nil }
        let combined = [WindowKind.fiveHour, .weekly].compactMap { kind in
            SeatGaugeCore.Window.combined(readings.compactMap { reading in reading.windows.first { $0.kind == kind } })
        }
        guard !combined.isEmpty else { return nil }
        return SummaryModel(lines: combined.map { window in
            var dry: Date?
            if case let .runsOut(at) = Pace(weekly: window, now: now) { dry = at }
            return WindowLine(kind: window.kind, usedPercent: window.usedPercent,
                              countdown: Countdown.text(until: dry ?? window.resetsAt, now: now),
                              runsOut: dry != nil, tone: MeterTone.of(window, now: now))
        }, pace: PaceLine(weekly: combined.first { $0.kind == .weekly }, now: now))
    }
}

enum Tab: CaseIterable {
    case seats, spend
    var title: String { self == .seats ? "SEATS" : "SPEND" }
}

/// A configured seat not on the window, as the title bar's `+` offers it:
/// one the user hid, or one with no reading to draw and why.
struct Offstage: Equatable, Identifiable {
    let id: SeatID
    let label: String
    let why: String

    var title: String { "\(label) · \(why)" }
}

struct PanelModel: Equatable {
    let cards: [CardModel]
    /// The ALL card, first in the row when there is one.
    var summary: SummaryModel?
    /// Why a seat is not drawn, one line each, for the right-click menu.
    let notes: [String]
    let emptyMessage: String?
    let updated: String
    /// The card drawing its detail face, only ever one that is drawn.
    var hovered: SeatID?
    var details: [SeatID: CardDetail] = [:]
    var offstage: [Offstage] = []

    func face(_ id: SeatID) -> CardFace { hovered == id ? .detail : .glance }

    /// Boxes in the row, the ALL card's included.
    var columns: Int { cards.count + (summary == nil ? 0 : 1) }

    /// Each seat's history by its name in the record; none before a read.
    static func histories(seats: [Seat], spend: SpendRecord?, through: AttributionRecord?,
                          choice: DetailChoice, now: Date, calendar: Calendar) -> [SeatID: SeatHistory] {
        guard let spend else { return [:] }
        let attribution = through ?? AttributionRecord(timeZone: calendar.timeZone.identifier)
        return Dictionary(seats.map { seat in
            (seat.id, SeatHistory.make(record: spend, through: attribution, seat: seat.historyName,
                                       range: choice.range, measure: choice.measure, now: now, calendar: calendar))
        }, uniquingKeysWith: { first, _ in first })
    }

    static func make(snapshot: Snapshot, seats: [Seat], now: Date, hovered: SeatID? = nil, selected: Int? = nil,
                     spend: SpendRecord? = nil, through: AttributionRecord? = nil,
                     choice: DetailChoice = DetailChoice(), calendar: Calendar = .current) -> PanelModel {
        make(snapshot: snapshot, seats: seats, now: now, hovered: hovered, selected: selected,
             histories: histories(seats: seats, spend: spend, through: through, choice: choice,
                                  now: now, calendar: calendar))
    }

    static func make(snapshot: Snapshot, seats: [Seat], now: Date, hovered: SeatID?, selected: Int?,
                     histories: [SeatID: SeatHistory], syncing: Set<SeatID> = [],
                     pollMinutes: Int = 5, arrangement: CardArrangement = CardArrangement()) -> PanelModel {
        let declared = Dictionary(seats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // An empty label is not a name, so the card falls back to the id
        // rather than drawing the provider alone.
        func name(_ id: SeatID) -> String {
            guard let label = declared[id]?.label, !label.isEmpty else { return id.rawValue }
            return label
        }
        var cards: [CardModel] = []
        var notes: [String] = []
        var polled: [SeatState] = []
        var live: [Reading] = []
        var offstage: [Offstage] = []
        // A hidden seat is still read and still in `headroom.json`; it is
        // only off the window, the ALL card and the pick.
        // The config's seats, so one with no restored reading is offered by
        // the `+` before the first poll, then any the snapshot alone names.
        let configured = seats.map(\.id) + snapshot.order.filter { declared[$0] == nil }
        let onWindow = arrangement.arranged(configured).filter { id in
            guard arrangement.hidden.contains(id) else { return true }
            offstage.append(Offstage(id: id, label: name(id), why: "hidden"))
            return false
        }
        let best = Snapshot(states: snapshot.states, order: onWindow).best
        for id in onWindow {
            let state = snapshot.states[id]
            let polls = declared[id]?.pollsAutomatically ?? true
            if polls, let state, state.canSync { polled.append(state) }
            var reading: Reading?
            var stale: String?
            switch state {
            case let .live(read):
                reading = read
                live.append(read)
            case let .unreadable(_, last?):
                reading = last
                stale = "stale · \(Countdown.text(until: now, now: last.takenAt))"
            case let .dormant(why), let .unreadable(why, nil):
                // Drawn only when the user asked for it: an inactive card with
                // whatever it last reported and why it has nothing now.
                guard arrangement.shown.contains(id) else {
                    notes.append("\(name(id)): \(why)")
                    offstage.append(Offstage(id: id, label: name(id), why: why))
                    continue
                }
                reading = snapshot.reported[id]
                stale = why
            case nil:
                offstage.append(Offstage(id: id, label: name(id), why: "not read yet"))
                continue
            }
            let seat = declared[id]
            guard let reading else {
                cards.append(CardModel(id: id, label: name(id), isBest: false, lines: [], pace: nil, stale: stale,
                                       mark: seat?.kind.provider ?? .claude, account: PlanText.said(seat?.account),
                                       plan: PlanText.resolve(tier: nil, declared: seat?.plan, wire: nil),
                                       signsIn: SeatLogin.offers(seat, state)))
                continue
            }
            let windows = reading.windows.sorted { $0.kind < $1.kind }
            let mark = seat?.kind.provider ?? .claude
            cards.append(CardModel(
                id: id, label: name(id), isBest: best == id,
                // A stale card's pace is yesterday's, so its meters keep the
                // usage colours.
                lines: windows.map {
                    WindowLine(kind: $0.kind, usedPercent: $0.usedPercent,
                               countdown: Countdown.text(until: $0.resetsAt, now: now),
                               tone: stale == nil ? MeterTone.of($0, now: now) : nil)
                },
                pace: stale == nil ? PaceLine(weekly: windows.first { $0.kind == .weekly }, now: now) : nil,
                stale: stale,
                mark: mark,
                account: PlanText.said(seat?.account),
                plan: PlanText.resolve(tier: reading.tier, declared: seat?.plan, wire: reading.plan),
                dated: polls || stale != nil ? nil : "synced \(Countdown.text(until: now, now: reading.takenAt)) ago",
                isSyncing: syncing.contains(id),
                signsIn: SeatLogin.offers(seat, state)))
        }
        let shown = cards.contains { $0.id == hovered } ? hovered : nil
        // Only the hovered card's detail is drawn, so only it has a status.
        let details = Dictionary(cards.map { card in
            let detail = CardDetail.make(card: card, history: histories[card.id],
                                         selected: card.id == shown ? selected : nil)
            return (card.id, card.id == shown ? detail : detail.quiet)
        }, uniquingKeysWith: { first, _ in first })
        return PanelModel(
            cards: cards, summary: SummaryModel.make(live, now: now), notes: notes,
            emptyMessage: cards.isEmpty ? "no seat is readable" : nil,
            updated: synced(polled, now: now, pollMinutes: pollMinutes),
            hovered: shown, details: details, offstage: offstage)
    }
}

extension PanelModel {
    /// The title bar's synced line over the seats that poll themselves: all
    /// of them read within two intervals says how old the oldest is, else how
    /// many are.
    static func synced(_ states: [SeatState], now: Date, pollMinutes: Int) -> String {
        guard !states.isEmpty else { return "not polled yet" }
        let limit = TimeInterval(pollMinutes * 120)
        let fresh = states.compactMap { state -> Date? in
            guard case let .live(reading) = state, now.timeIntervalSince(reading.takenAt) < limit else { return nil }
            return reading.takenAt
        }
        guard fresh.count == states.count, let oldest = fresh.min() else {
            return "\(fresh.count) of \(states.count) synced"
        }
        return "all seats synced \(Countdown.text(until: now, now: oldest)) ago"
    }
}

extension SeatState {
    /// A seat the synced line counts: any but a dormant one, which is not
    /// drawn and has nothing to sync.
    var canSync: Bool {
        if case .dormant = self { return false }
        return true
    }
}

/// What the root `TimelineView` schedules from, so the countdowns turn over on
/// the wall-clock minute rather than a minute after launch.
enum PanelClock {
    static func nextMinute(after instant: Date) -> Date {
        let seconds = instant.timeIntervalSince1970
        return Date(timeIntervalSince1970: (seconds / 60).rounded(.down) * 60 + 60)
    }
}
