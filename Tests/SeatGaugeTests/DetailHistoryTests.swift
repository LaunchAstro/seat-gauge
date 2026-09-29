import AppKit
import Foundation
import SwiftUI
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// The detail face's history: the plot, the status line, the controls, each
/// history outcome and what fails closed. The calendar and the clock are
/// `SeatHistoryTests`' own.
@Suite(.serialized, .sharedMirror) @MainActor struct DetailHistoryTests {

    typealias Widths = CardWidthTests
    typealias Glance = GlanceFaceTests
    typealias History = SeatHistoryTests

    static let now = History.now
    static let utc = History.utc

    static func row(_ seat: String, _ day: String, input: Int = 1_000, usd: String? = nil) -> SpendRow {
        SpendRow(seat: seat, day: day, hour: "10", model: "claude-opus-5",
                 counts: TokenCounts(responses: 1, input: input), usd: usd.flatMap { Decimal(string: $0) },
                 sealed: true)
    }

    static func window(_ kind: WindowKind, used: Int) -> SeatGaugeCore.Window {
        SeatGaugeCore.Window(kind: kind, usedPercent: used, resetsAt: now.addingTimeInterval(86_400),
                             length: .seconds(kind == .fiveHour ? 5 * 3600 : 7 * 86_400))
    }

    /// Work (Claude, weekly 96%, so an amber verdict) and codex, both live.
    static func model(record: SpendRecord?, hovered: SeatID? = nil, selected: Int? = nil,
                      choice: DetailChoice = DetailChoice()) -> PanelModel {
        let seats = [Glance.claude("work", account: "office", plan: "Max 20x"), Glance.codex("codex")]
        let states: [SeatID: SeatState] = [
            seats[0].id: .live(Reading(seat: seats[0].id, windows: [window(.weekly, used: 96)], takenAt: now, plan: nil)),
            seats[1].id: .live(Reading(seat: seats[1].id, windows: [window(.weekly, used: 30)], takenAt: now, plan: nil)),
        ]
        return PanelModel.make(snapshot: Snapshot(states: states, order: seats.map(\.id)), seats: seats, now: now,
                               hovered: hovered, selected: selected, spend: record,
                               through: History.noSpans, choice: choice, calendar: utc)
    }

    static let work = SeatID(rawValue: "work")
    static let codex = SeatID(rawValue: "codex")

    // MARK: - The plot, its bars and every bucket selectable

    @Test func everyBucketIsSelectableAtTheMinimumPlotWidth() {
        Widths.atOrdinaryStep { step in
            let line = CardMetrics.minimumWidth - (CardMetrics.horizontalPadding + PanelLayout.boxInset) * 2
            #expect(abs(CardDetailMetrics.minimumPlotWidth - line) < 0.01, "step \(step)")
            let floor = CardMetrics.meterWidth(cardWidth: CardMetrics.minimumWidth)
                + CardMetrics.countdownWidth + CardMetrics.percentWidth
            #expect(CardDetailMetrics.minimumPlotWidth >= floor, "step \(step)")
        }
        let width = CardDetailMetrics.minimumPlotWidth
        for count in HistoryRange.allCases.map(\.count) + [100] {
            for plot in [width, 50] {
                guard let bars = CardDetailMetrics.bars(count: count, width: plot) else {
                    Issue.record("no bars for \(count) at \(plot)"); continue
                }
                let spaced = (plot - CGFloat(count - 1)) / CGFloat(count)
                if spaced >= 2 {
                    #expect(bars.gap == 1 && abs(bars.bar - spaced) < 0.001, "\(count) at \(plot)")
                } else {
                    #expect(bars.gap == 0 && abs(bars.bar - plot / CGFloat(count)) < 0.001, "\(count) at \(plot)")
                }
                var seen = Set<Int>(), last = -1
                for tenth in 0 ..< Int(plot * 10) {
                    guard let index = CardDetailMetrics.bucket(at: CGFloat(tenth) / 10, count: count, width: plot)
                    else { Issue.record("x \(CGFloat(tenth) / 10) selects nothing"); break }
                    #expect(index >= last)
                    last = index
                    seen.insert(index)
                }
                #expect(seen == Set(0 ..< count), "\(count) at \(plot)")
            }
        }
        // Seven bars across 69 pt are 9 pt wide with 1 pt gaps: the pick
        // changes in the middle of each gap, not at a bar's edge.
        #expect(CardDetailMetrics.bucket(at: 9.4, count: 7, width: 69) == 0)
        #expect(CardDetailMetrics.bucket(at: 9.6, count: 7, width: 69) == 1)
        #expect(CardDetailMetrics.bucket(at: -1, count: 7, width: width) == nil)
        #expect(CardDetailMetrics.bucket(at: width, count: 7, width: width) == nil)

        let record = SpendRecord.available([Self.row("work", "2026-09-23", input: 3_000),
                                            Self.row("work", "2026-09-25", input: 1_500)])
        guard case let .bars(shares, _) = Self.model(record: record).details[Self.work]?.plot else {
            Issue.record("no bars"); return
        }
        #expect(shares.count == 7)
        #expect(shares.max() == 1)
        #expect(shares[2] == 1 && shares[4] == 0.5 && shares[0] == 0)
    }

    // MARK: - The status line and the read-out

    @Test func theStatusLineIsThePaceOrTheSelectedReadOut() {
        let record = SpendRecord.available([Self.row("work", "2026-09-23", input: 1_200_000),
                                            Self.row("work", "2026-09-22", input: 10, usd: "41.20")])
        let plain = Self.model(record: record, hovered: Self.work)
        let pace = plain.cards.first?.pace
        #expect(pace?.tone == .amber)
        #expect(plain.details[Self.work]?.status == DetailLine(text: pace?.text ?? "?", tone: .amber))

        let picked = Self.model(record: record, hovered: Self.work, selected: 2)
        #expect(picked.details[Self.work]?.status == DetailLine(text: "Wed 23 Sep · 1.2M tokens", tone: .ink))
        let weeks = Self.model(record: record, hovered: Self.work, selected: 25,
                               choice: DetailChoice(range: .halfYear, measure: .usd))
        #expect(weeks.details[Self.work]?.status == DetailLine(text: "wk of 21 Sep · $41.20", tone: .ink))
        // Only the hovered card reads out its selection.
        #expect(picked.details[Self.codex]?.status == nil)

        let stale = CardModel(id: Self.work, label: "work", isBest: false, lines: [],
                              pace: nil, stale: "stale · 23m", mark: .claude, account: nil, plan: nil)
        #expect(CardDetail.make(card: stale, history: nil, selected: nil).status
            == DetailLine(text: "stale · 23m", tone: .dim))

        let mirror = GaugeMirror.shared
        let was = mirror.hovered
        defer { mirror.hover(was) }
        mirror.hover(Self.work)
        mirror.select(2)
        #expect(mirror.selected == 2)
        mirror.hover(Self.codex)
        #expect(mirror.selected == nil)
        mirror.select(1)
        mirror.hover(nil)
        #expect(mirror.selected == nil)
    }

    // MARK: - The controls row and the remembered choice

    @Test func theControlsRowChoosesAndRemembersTheRangeAndMeasure() throws {
        let words = ControlsRow.words(for: DetailChoice(range: .month, measure: .usd))
        #expect(words.ranges.map(\.text) == ["W", "M", "6M", "Y"])
        #expect(words.ranges.map(\.tone) == [.dim, .ink, .dim, .dim])
        #expect(words.measures.map(\.text) == ["TOKENS", "$"])
        #expect(words.measures.map(\.tone) == [.dim, .ink])

        let faces = Type.registered
        defer { Type.registered = faces }
        for registered in [Set<String>(), Widths.registerBundledFaces()] {
            Type.registered = registered
            Widths.atOrdinaryStep { step in
                #expect(abs(CardDetailMetrics.controlsSpacing - CardMetrics.scaled(8)) < 0.01)
                for range in HistoryRange.allCases {
                    let row = ControlsRow(choice: DetailChoice(range: range, measure: .tokens)).fixedSize()
                    let width = NSHostingView(rootView: row).fittingSize.width
                    #expect(width <= CardDetailMetrics.minimumPlotWidth, "step \(step): \(width)")
                }
            }
        }

        let (store, folder) = GlanceTests.temporaryState()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mirror = GaugeMirror.shared
        let was = mirror.choice
        defer { mirror.choice = was }
        try mirror.choose(range: .halfYear, store: store)
        try mirror.choose(measure: .usd, store: store)
        #expect(mirror.choice == DetailChoice(range: .halfYear, measure: .usd))
        #expect(store.load().historyRange == .halfYear)
        #expect(DetailChoiceStore.load(store) == DetailChoice(range: .halfYear, measure: .usd))

        let record = SpendRecord.available([Self.row("work", "2026-09-23", usd: "1.00")])
        for range in HistoryRange.allCases {
            for measure in Measure.allCases {
                let history = Self.model(record: record, choice: DetailChoice(range: range, measure: measure))
                    .details[Self.work]?.history
                #expect(history?.range == range && history?.measure == measure)
                #expect(history?.outcome.buckets.count == range.count, "\(range) \(measure)")
            }
        }
    }

    // MARK: - Each history outcome draws its own face

    @Test func eachHistoryOutcomeDrawsItsOwnFace() {
        let rows = [Self.row("work", "2026-09-23"), Self.row("codex", "2026-09-24", input: 500)]
        let available = Self.model(record: .available(rows))
        if case let .bars(shares, _) = available.details[Self.work]?.plot {
            #expect(shares.count == 7)
        } else { Issue.record("available draws no bars") }
        // The Codex card charts the codex rows.
        #expect(available.details[Self.codex]?.history?.outcome.buckets.map(\.amount).reduce(0, +) == 500)

        let partial = Self.model(record: .partial(rows, "spend.csv: 1 line could not be read"))
        if case .bars = partial.details[Self.work]?.plot {} else { Issue.record("partial draws no bars") }
        let reason = DetailLine(text: "spend.csv: 1 line could not be read", tone: .dim)
        #expect(CardDetail.make(card: partial.cards[0], history: partial.details[Self.work]?.history,
                                selected: nil).status == reason)

        let empty = Self.model(record: .empty).details[Self.work]
        #expect(empty?.plot == .line(DetailLine(text: "no usage recorded in this range", tone: .dim)))
        let broken = Self.model(record: .unavailable("spend.csv has the wrong header"))
        let unavailable = CardDetail.make(card: broken.cards[0], history: broken.details[Self.work]?.history,
                                          selected: nil)
        #expect(unavailable.status == DetailLine(text: "spend.csv has the wrong header", tone: .warning))
        #expect(unavailable.plot == .bars([], selected: nil))
        let unpriced = Self.model(record: .available(rows), choice: DetailChoice(range: .week, measure: .usd))
        #expect(unpriced.details[Self.codex]?.plot == .line(DetailLine(text: "no list price for this seat", tone: .dim)))

        #expect(Glance.codex("anything").historyName == "codex")
        // A Claude seat's history is filed under its id, whatever its
        // profile directory is called.
        let profiled = Seat(id: SeatID(rawValue: "renamed"), label: "renamed",
                            kind: .claude(profileDir: URL(fileURLWithPath: "/tmp/any-profile")))
        #expect(profiled.historyName == "renamed")
        #expect(Glance.claude("work").historyName == "work")
        #expect(Seat(id: SeatID(rawValue: "solo"), label: "solo", kind: .claude(profileDir: URL(fileURLWithPath: "/tmp/seat-gauge-profile"))).historyName == "solo")
    }

    // MARK: - Fails closed

    @Test func aStaleCardAStrayHoverAndAnUnreadRecordStillDrawPlainly() {
        let now = Glance.now
        let emptier = Reading(seat: SeatID(rawValue: "work"), windows: [Glance.window(.fiveHour, used: 5)],
                              takenAt: now.addingTimeInterval(-23 * 60), plan: nil)
        let fuller = Reading(seat: SeatID(rawValue: "personal"), windows: [Glance.window(.fiveHour, used: 70)],
                             takenAt: now, plan: nil)
        let stray = Reading(seat: SeatID(rawValue: "stray"), windows: [Glance.window(.fiveHour, used: 90)],
                            takenAt: now, plan: nil)
        let states: [SeatID: SeatState] = [emptier.seat: .unreadable(reason: "login expired", last: emptier),
                                           fuller.seat: .live(fuller), stray.seat: .live(stray)]
        let model = PanelModel.make(
            snapshot: Snapshot(states: states, order: [emptier.seat, fuller.seat, stray.seat]),
            seats: [Glance.claude("work"), Glance.codex("personal")], now: now,
            hovered: SeatID(rawValue: "nobody"))
        #expect(model.cards.count == 3)
        guard model.cards.count == 3 else { return }
        let stale = model.cards[0]
        #expect(stale.stale == "stale · 23m")
        #expect(stale.isDimmed)
        #expect(!stale.isBest)
        #expect(model.cards.filter(\.isBest).map(\.label) == ["personal"])

        // The stale line is still drawn on the glance face.
        let fresh = Glance.copy(stale, pace: nil, stale: nil)
        Glance.appearances { light in
            let width = CardMetrics.minimumWidth + 40
            let old = Widths.render(GlanceFace(card: stale).modifier(CardBox()), width: width)
            let new = Widths.render(GlanceFace(card: fresh).modifier(CardBox()), width: width)
            #expect((old?.height ?? 0) > (new?.height ?? 0) + Int(8 * Widths.scale), "light \(light)")
        }

        #expect(model.cards[2].mark == .claude)
        #expect(model.cards[2].provider == "Claude")

        // A hover that names no card is no hover.
        #expect(model.hovered == nil)
        #expect(model.cards.allSatisfy { model.face($0.id) == .glance })
        // A selection outside the history is no selection.
        let record = SpendRecord.available([Self.row("work", "2026-09-23")])
        let far = Self.model(record: record, hovered: Self.work, selected: 99)
        #expect(far.details[Self.work]?.status?.tone == .amber)
        // A record never read is said, not drawn as nothing.
        #expect(model.details[stale.id]?.plot == .line(DetailLine(text: "spend record not read yet", tone: .warning)))
    }
}
