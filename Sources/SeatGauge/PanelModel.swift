import Foundation
import SeatGaugeCore
import SwiftUI

/// Everything the panel draws, as values. The views draw this model rather
/// than a snapshot, so a case reads the card the user sees without a screen.

/// The meter's colour: the used percent on `MeterLines`, or on a weekly
/// line with a pace, the pace's grade.
enum MeterTone: Equatable {
    case good, warning, danger

    static func of(usedPercent: Int) -> MeterTone {
        usedPercent >= MeterLines.danger ? .danger : usedPercent >= MeterLines.warning ? .warning : .good
    }

    /// An unstarted window has no pace and nothing used.
    static func of(_ window: WindowView, now: Date) -> MeterTone {
        window.window.map { of($0, now: now) } ?? .of(usedPercent: window.usedPercent)
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
    case ink, muted, dim, amber, green, warning, danger

    var color: Color {
        switch self {
        case .ink: Tone.ink
        case .muted: Tone.inkMuted
        case .dim: Tone.inkDim
        case .amber, .warning: Tone.warning
        case .green: Tone.success
        case .danger: Tone.danger
        }
    }
}

/// The three pace verdicts, in words, over `Pace`. There is no line for a
/// week nothing has been spent in, which is what `Pace` returning nil means.
struct PaceLine: Equatable {
    let text: String
    let tone: LineTone

    init?(weekly window: SeatGaugeCore.Window?, now: Date) {
        self.init(window.flatMap { Pace(weekly: $0, now: now) }, now: now)
    }

    init?(_ pace: Pace?, now: Date) {
        guard let pace else { return nil }
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

/// A seat's subscription date under its windows: the date while it is a week
/// or more away, the days left under a week, and red from three days out.
struct BillingLine: Equatable {
    let text: String
    let tone: LineTone

    init(_ billing: Billing, now: Date, calendar: Calendar = .current) {
        let verb = if case .renews = billing { "renews" } else { "expires" }
        let days = billing.daysLeft(now: now, calendar: calendar)
        let shape = DateFormatter()
        shape.locale = Locale(identifier: "en_AU")
        shape.calendar = calendar
        shape.timeZone = calendar.timeZone
        shape.dateFormat = "d MMM"
        let day = shape.string(from: billing.next(now: now, calendar: calendar))
        text = switch days {
        case ..<0: "expired \(day)"
        case 0: "\(verb) today"
        case 1: "\(verb) tomorrow"
        case 2..<7: "\(verb) in \(days) days"
        default: "\(verb) \(day)"
        }
        tone = days <= 3 ? .danger : .muted
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
    /// then the wire's, then nothing at all. Never "Free" where nobody
    /// reported it.
    let plan: String?
    /// When the subscription renews or expires, where the config says.
    var billing: BillingLine?
    /// A token seat's age, since it is read only when the user syncs it and
    /// the title bar's synced line leaves it out.
    var dated: String?
    /// True while a sync or poll is reading this seat.
    var isSyncing = false
    /// True when the card offers Sign in, by `SeatLogin.offers`. Such a seat
    /// signed itself out: its stale line is the warning, in red, and its
    /// header's × puts the card away in place of a sync that cannot read it.
    var signsIn = false

    /// The stale line of a seat that signed itself out.
    static let signedOut = SeatView.signedOut
    /// True when the seat has an `open` command, which a click on the
    /// header's mark or name runs.
    var opens = false

    /// What VoiceOver reads for that click.
    var openLabel: String { "Open \(label)" }

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
    case seats, load, spend, log
    var title: String {
        switch self {
        case .seats: "SEATS"
        case .spend: "SPEND"
        case .load: "LOAD"
        case .log: "LOG"
        }
    }
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

    /// Boxes on the tab, the ALL card's included.
    var boxes: Int { cards.count + (summary == nil ? 0 : 1) }

    /// Each seat's history by its name in the record; none before a read.
    static func histories(seats: [Seat], spend: SpendView?, choice: DetailChoice, now: Date,
                          calendar: Calendar) -> [SeatID: SeatHistory] {
        guard let spend else { return [:] }
        return Dictionary(seats.map { seat in
            (seat.id, spend.history(seat: seat.historyName, range: choice.range, measure: choice.measure,
                                    now: now, calendar: calendar))
        }, uniquingKeysWith: { first, _ in first })
    }

    static func make(snapshot: Snapshot, seats: [Seat], now: Date, hovered: SeatID? = nil, selected: Int? = nil,
                     spend: SpendRecord? = nil, through: AttributionRecord? = nil,
                     choice: DetailChoice = DetailChoice(), calendar: Calendar = .current) -> PanelModel {
        make(snapshot: snapshot, seats: seats, now: now, hovered: hovered, selected: selected,
             histories: histories(seats: seats,
                                  spend: spend.map {
                                      SpendView(record: $0, attribution: through.map { .record($0) } ?? .missing,
                                                rates: .load(), zone: calendar.timeZone)
                                  },
                                  choice: choice, now: now, calendar: calendar))
    }

    static func make(snapshot: Snapshot, seats: [Seat], now: Date, hovered: SeatID?, selected: Int?,
                     histories: [SeatID: SeatHistory], syncing: Set<SeatID> = [],
                     pollMinutes: Int = 5, arrangement: CardArrangement = CardArrangement()) -> PanelModel {
        let gauge = GaugeView(snapshot: snapshot, seats: seats, now: now, pollMinutes: pollMinutes,
                              arrangement: arrangement)
        var cards: [CardModel] = []
        var notes: [String] = []
        var live: [Reading] = []
        var offstage: [Offstage] = []
        for view in gauge.seats {
            if let why = view.offstage {
                // Only a seat with nothing to draw has a note; one the user
                // hid, or one not read yet, has the `+` alone.
                if !arrangement.hidden.contains(view.id), view.state != nil { notes.append("\(view.label): \(why)") }
                offstage.append(Offstage(id: view.id, label: view.label, why: why))
                continue
            }
            if case let .live(read) = view.state { live.append(read) }
            cards.append(CardModel(
                id: view.id, label: view.label, isBest: view.isBest,
                // A stale card's pace is yesterday's, so its meters keep the
                // usage colours.
                lines: view.windows.map {
                    WindowLine(kind: $0.kind, usedPercent: $0.usedPercent,
                               countdown: $0.countdown(now: now),
                               tone: view.stale == nil ? MeterTone.of($0, now: now) : nil)
                },
                pace: PaceLine(view.pace, now: now),
                stale: view.stale,
                mark: view.provider,
                account: view.account,
                plan: view.plan,
                billing: view.seat?.billing.map { BillingLine($0, now: now) },
                dated: view.dated,
                isSyncing: view.shown != nil && syncing.contains(view.id),
                signsIn: view.signsIn,
                opens: view.seat?.open != nil))
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
            updated: gauge.synced,
            hovered: shown, details: details, offstage: offstage)
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
