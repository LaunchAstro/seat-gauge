import AppKit
import Foundation
import SwiftUI
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// The window hugs the cards, and hover fits inside them. Every case is at the
/// ordinary text step, in the dark appearance.
@Suite(.serialized, .sharedMirror) @MainActor struct HugAndHoverTests {

    typealias Height = PanelHeightTests
    typealias Widths = CardWidthTests
    typealias Glance = GlanceFaceTests
    typealias Envelope = EnvelopeTests
    typealias Spend = SpendAccountsTests

    /// The mirror at the ordinary step with `cards` of the populated seats.
    static func ordinary(cards: Int = 4) -> () -> Void {
        let restore = Envelope.populated(cards: cards)
        GaugeMirror.shared.textScale = .normal
        return restore
    }

    /// A live Claude card with three window lines, an account and a plan.
    static func claude(account: String? = "office", plan: String? = "Max 20x", best: Bool = false) -> CardModel {
        let lines = [WindowKind.fiveHour, .weekly, .fable].map {
            WindowLine(kind: $0, usedPercent: 40, countdown: "5d 20h")
        }
        return CardModel(id: SeatID(rawValue: "work"), label: "Work", isBest: best,
                         lines: lines, pace: nil, stale: nil, mark: .claude, account: account, plan: plan)
    }

    static func height<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        CGFloat(Widths.render(view.environment(\.pinnedVerticalFactor, 1), width: width)?.height ?? -1) / Widths.scale
    }

    /// The last column with any ink, in points.
    static func lastInk<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        guard let bitmap = Widths.render(view, width: width) else { return -1 }
        return (0..<bitmap.height).compactMap { bitmap.inked(row: $0).last?.end }.max() ?? -1
    }

    // MARK: - The window hugs the Seats content

    @Test func theWindowHugsTheSeatsContent() async {
        let restore = Self.ordinary()
        defer { restore() }
        let name = Height.freshName()
        defer { Height.forget(name) }
        let built = Height.controller(name)
        defer { built.window.close() }
        built.show()
        await Height.settle()
        let seats = Envelope.contents(width: built.window.contentLayoutRect.width).seats
        for tab in [Tab.seats, .spend] {
            GaugeMirror.shared.tab = tab
            await Height.settle()
            #expect(abs(built.window.contentLayoutRect.height - seats) <= 1,
                    "\(tab): \(built.window.contentLayoutRect.height) against the cards' \(seats)")
            #expect(abs(built.heightBounds().lowerBound - seats) <= 1, "\(tab): \(built.heightBounds())")
        }
    }

    // MARK: - The Spend tab fits inside the cards

    @Test func theSpendTabFitsInsideTheCards() {
        let restore = Self.ordinary()
        defer { restore() }
        let width: CGFloat = 520
        let four = Envelope.contents(width: width).seats
        let one = Self.height(ComboLayout(cards: [Self.claude()]).fixedSize(horizontal: false, vertical: true),
                              width: width)
        #expect(SpendTab.chartFloor > 0)
        for measure in Measure.allCases {
            let available = Spend.chart(Spend.rows, measure)
            let partial = SpendChart.make(record: .partial(Spend.rows, "2 malformed row(s) skipped"),
                                          through: Spend.attribution, rates: .bundled, measure: measure,
                                          now: Spend.now, calendar: Spend.utc)
            #expect(SpendTab.reason(partial) == "2 malformed row(s) skipped")
            let drawn = [available, partial].map {
                Self.height(SpendTab(chart: $0).fixedSize(horizontal: false, vertical: true), width: width)
            }
            #expect(drawn[0] > 0 && abs(drawn[0] - drawn[1]) <= 1, "\(measure): \(drawn)")
            #expect(drawn.allSatisfy { $0 <= min(one, four) + 0.5 }, "\(measure): \(drawn) against \(one), \(four)")
        }
        // Five families in tokens, six in dollars: the totals list scrolls
        // rather than setting the tab's height.
        let heights = Measure.allCases.map {
            Self.height(SpendTab(chart: Spend.chart(Spend.rows, $0)).fixedSize(horizontal: false, vertical: true),
                        width: width)
        }
        #expect(abs(heights[0] - heights[1]) <= 1, "\(heights)")
    }

    @Test func anEmptyPartialRecordShowsItsReason() throws {
        let old = Spend.row("work", "2026-08-01", "03", "claude-opus-5")
        let partial = SpendChart.make(record: .partial([old], "1 malformed row skipped"),
                                      through: Spend.attribution, rates: .bundled,
                                      measure: .tokens, now: Spend.now, calendar: Spend.utc)
        let whole = SpendChart.make(record: .available([old]),
                                    through: Spend.attribution, rates: .bundled,
                                    measure: .tokens, now: Spend.now, calendar: Spend.utc)
        try Widths.atOrdinaryStep { _ in
            let a = try #require(Widths.render(SpendTab(chart: partial)
                .fixedSize(horizontal: false, vertical: true), width: 520))
            let b = try #require(Widths.render(SpendTab(chart: whole)
                .fixedSize(horizontal: false, vertical: true), width: 520))
            #expect(a != b)
        }
    }

    // MARK: - A card is as tall as its glance face

    @Test func aCardIsAsTallAsItsGlanceFace() {
        let restore = Self.ordinary()
        defer { restore() }
        let card = Self.claude()
        let detail = CardDetail.make(card: card, history: nil, selected: nil)
        let width = CardMetrics.minimumWidth + 60
        let glance = Self.height(GlanceFace(card: card).modifier(CardBox()), width: width)
        for face in [CardFace.glance, .detail] {
            #expect(abs(Self.height(CardView(card: card, detail: detail, face: face), width: width) - glance) <= 0.5,
                    "\(face)")
        }
        let row = Self.height(ComboLayout(cards: Array(repeating: card, count: 4))
            .fixedSize(horizontal: false, vertical: true), width: width * 4 + 3)
        #expect(abs(row - glance) <= 0.5, "row \(row) against \(glance)")
        #expect(CardMetrics.Glance.rowSpacing == 8)
        #expect(CardMetrics.rowSpacing == 8)
        #expect(VerticalFit.Base.meter == 5)
    }

    // MARK: - The account on hover and the plan in the corner

    @Test func theHeaderNamesTheAccountOnHoverAndThePlanInTheCorner() {
        let restore = Self.ordinary()
        defer { restore() }
        let card = Self.claude()
        #expect(card.seat(on: .glance) == "Work")
        #expect(card.seat(on: .detail) == "office")
        let width = CardMetrics.minimumWidth + 120
        for face in [CardFace.glance, .detail] {
            let plain = Self.lastInk(CardHeader(card: card, face: face), width: width)
            let best = Self.lastInk(CardHeader(card: Self.claude(best: true), face: face), width: width)
            #expect(plain > width - 2 && abs(plain - best) <= 0.5, "\(face): \(plain), \(best)")
            #expect(!Glance.same(CardHeader(card: card, face: face), CardHeader(card: Self.claude(best: true), face: face),
                                 width: width))
        }
        // The sync icon holds the corner with or without a plan beside it.
        let unplanned = Self.lastInk(CardHeader(card: Self.claude(plan: nil)), width: width)
        #expect(unplanned > width - 2, "\(unplanned)")
        #expect(!Glance.same(CardHeader(card: card), CardHeader(card: Self.claude(plan: nil)), width: width))
        #expect(CardMetrics.headerWidth(provider: "Claude", seat: "Work", picked: true, plan: "Max 20x")
                > CardMetrics.headerWidth(provider: "Claude", seat: "Work", picked: true) + 30)
    }

    // MARK: - The status line carries the reason; no note

    @Test func theStatusLineCarriesTheReasonAndThereIsNoNote() {
        typealias History = DetailHistoryTests
        let rows = [History.row("work", "2026-09-23")]
        let selected = History.model(record: .available(rows), hovered: History.work, selected: 6)
        #expect(selected.details[History.work]?.status?.tone == .ink)
        let paced = History.model(record: .available(rows), hovered: History.work)
        #expect(paced.details[History.work]?.status?.tone == .amber)
        let partial = History.model(record: .partial(rows, "1 line skipped"), hovered: History.work)
        #expect(partial.details[History.work]?.status == DetailLine(text: "1 line skipped", tone: .dim))
        let broken = History.model(record: .unavailable("wrong header"), hovered: History.work)
        #expect(broken.details[History.work]?.status == DetailLine(text: "wrong header", tone: .warning))
        #expect(broken.details[History.work]?.plot == .bars([], selected: nil))

        let detail = CardDetail.make(card: Self.claude(), history: nil, selected: nil)
        #expect(Mirror(reflecting: detail).children.compactMap(\.label) == ["status", "plot", "history"])
        #expect(Type.weight == .light)
    }

    // MARK: - Fails closed

    @Test func aOneLineRowStillFitsTheHoverAndBlanksStayBlank() {
        let restore = Self.ordinary()
        defer { restore() }
        let card = Widths.oneLine(used: 30)
        let width = CardMetrics.minimumWidth + 60
        let line = width - (CardMetrics.horizontalPadding + PanelLayout.boxInset) * 2
        let header = Self.height(CardHeader(card: card).fixedSize(horizontal: false, vertical: true), width: line)
        let expected = header + VerticalFit.boxPadding(1) * 2 + PanelLayout.boxInset * 2
            + CardDetailMetrics.minimumBody(1)
        let drawn = Self.height(CardView(card: card), width: width)
        #expect(abs(drawn - expected) <= 1, "\(drawn) against \(expected)")
        #expect(drawn > Self.height(GlanceFace(card: card).modifier(CardBox()), width: width))

        #expect(card.plan == nil)
        #expect(CardMetrics.headerWidth(provider: "Claude", seat: "work", picked: false, plan: nil)
                == CardMetrics.headerWidth(provider: "Claude", seat: "work", picked: false))
        #expect(Self.claude(account: nil).seat(on: .detail) == "Work")
    }
}
