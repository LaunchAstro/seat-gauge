import AppKit
import Foundation
import SwiftUI
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// The two faces, the account on hover, the hover value and the detail face's
/// heights. Renders go through `CardWidthTests`' bitmap.
@Suite(.serialized, .sharedMirror) @MainActor struct DetailFaceTests {

    typealias Widths = CardWidthTests
    typealias Glance = GlanceFaceTests

    static let now = Glance.now

    /// A Claude card and a Codex card, the first with an account, a plan and
    /// an amber verdict.
    static func pair() -> PanelModel {
        Glance.panel(
            [Glance.claude("work", account: "office", plan: "Max 20x"), Glance.codex("codex")],
            [[Glance.window(.fable, used: 10), Glance.window(.weekly, used: 96),
              Glance.window(.fiveHour, used: 20, in: 3600)],
             [Glance.window(.weekly, used: 30)]])
    }

    static func copy(_ card: CardModel, pace: PaceLine?, stale: String?,
                     account: String?, plan: String?) -> CardModel {
        CardModel(id: card.id, label: card.label, isBest: card.isBest,
                  lines: card.lines, pace: pace, stale: stale, mark: card.mark, account: account, plan: plan)
    }

    static func height<V: View>(_ view: V, width: CGFloat, factor: CGFloat = 1) -> Int {
        Widths.render(view.environment(\.pinnedVerticalFactor, factor), width: width)?.height ?? -1
    }

    // MARK: - The glance face draws no pace line and no account

    @Test func theGlanceFaceDrawsTheWindowsAndNeitherThePaceNorTheIdentity() {
        let runsOut = PaceLine(weekly: Glance.window(.weekly, used: 96), now: Self.now)
        let unused = PaceLine(weekly: Glance.window(.weekly, used: 10), now: Self.now)
        let onPace = PaceLine(weekly: Glance.window(.weekly, used: 86), now: Self.now)
        #expect(runsOut?.text.hasPrefix("runs out ") == true)
        #expect(runsOut?.text.hasSuffix(" at this rate") == true)
        #expect(runsOut?.tone == .amber)
        #expect(unused?.text == "88% will go unused at this rate")
        #expect(unused?.tone == .muted)
        #expect(onPace?.text == "on pace to use it all")
        #expect(onPace?.tone == .green)
        #expect(PaceLine(weekly: Glance.window(.weekly, used: 0), now: Self.now) == nil)

        let model = Self.pair()
        #expect(model.cards.count == 2)
        guard model.cards.count == 2 else { return }
        #expect(model.cards[0].lines.map(\.name) == ["5H", "WK", "FABLE"])
        #expect(model.cards[1].lines.map(\.name) == ["WK"])
        #expect(model.cards[0].pace?.tone == .amber)
        #expect(model.cards[0].seat(on: .glance) == "work")

        let with = model.cards[0]
        let without = Self.copy(with, pace: nil, stale: nil, account: nil, plan: with.plan)
        Glance.appearances { light in
            Widths.atOrdinaryStep { step in
                let width = CardMetrics.minimumWidth + 40
                #expect(Glance.same(GlanceFace(card: with).modifier(CardBox()),
                                    GlanceFace(card: without).modifier(CardBox()), width: width),
                        "light \(light), step \(step)")
            }
        }
    }

    // MARK: - The account the config declares, on the detail face

    @Test func theDetailFaceShowsTheAccountItsConfigDeclares() {
        typealias Old = GlanceTests
        let named = Old.seat("personal", account: "personal account")
        let bare = Old.seat("work")
        let blank = Old.seat("team", account: "   ")
        let seats = [named, bare, blank]
        let model = PanelModel.make(snapshot: Old.snapshot(seats, plans: [nil, nil, nil], now: Self.now),
                                    seats: seats, now: Self.now)

        #expect(model.cards.count == 3)
        #expect(model.cards.first { $0.id == named.id }?.account == "personal account")
        #expect(model.cards.first { $0.id == named.id }?.seat(on: .detail) == "personal account")
        // Nothing declared is nothing drawn, and whitespace is nothing.
        #expect(model.cards.first { $0.id == bare.id }?.account == nil)
        #expect(model.cards.first { $0.id == blank.id }?.account == nil)
        #expect(model.details[bare.id] != nil)
        #expect(model.cards.first { $0.id == bare.id }?.seat(on: .detail) == bare.label)
        #expect(model.cards.first { $0.id == blank.id }?.seat(on: .detail) == blank.label)
        #expect(model.cards.allSatisfy { $0.account?.isEmpty != true })
    }

    // MARK: - The plan printed by `read` and drawn on the detail face

    @Test func theDetailFaceAndTheReadLineCarryThePlan() async throws {
        typealias Plan = PlanTests
        let home = try Plan.temporary()
        defer { try? FileManager.default.removeItem(at: home) }
        try Plan.write(Plan.claudeJSON(tier: "default_claude_max_20x"), named: ".claude.json", into: home)
        let seat = Seat(id: SeatID(rawValue: "work"), label: "Work",
                        kind: .claude(profileDir: home), account: "office account")
        let fetched = await Plan.claude(seat, replies: try Plan.claudeReplies())
        #expect(PlanText.shown(for: seat, state: fetched.fetched.state) == "Max 20x")
        let model = PanelModel.make(
            snapshot: Snapshot(states: [seat.id: fetched.fetched.state], order: [seat.id]),
            seats: [seat], now: Plan.now)
        #expect(model.cards.first?.seat(on: .detail) == "office account")
        #expect(model.cards.first?.plan == "Max 20x")

        #expect(PlanText.column("enterprise max", width: 10) == "enterprise max")
        #expect(PlanText.column("Max 5x", width: 10) == "Max 5x    ")

        // Fails closed: nothing reported and nothing declared is no plan.
        #expect(PlanText.shown(for: seat, state: .dormant(reason: "not logged in")) == nil)
        let bare = Seat(id: SeatID(rawValue: "personal"), label: "Personal", kind: .claude(profileDir: home))
        let reading = Reading(seat: bare.id, windows: [], takenAt: Plan.now, plan: nil)
        #expect(PlanText.shown(for: bare, state: .live(reading)) == nil)
        #expect(PlanText.shown(for: bare, state: .unreadable(reason: "x", last: reading)) == nil)
    }

    // MARK: - The account in the detail face's header

    @Test func theIdentityLineIsTheDetailFacesSecondRowAndMiddleTruncates() throws {
        let model = Self.pair()
        #expect(model.cards.count == 2)
        guard model.cards.count == 2 else { return }
        let claude = model.cards[0], codex = model.cards[1]
        #expect(claude.seat(on: .detail) == "office")
        #expect(codex.seat(on: .detail) == codex.label)
        for card in model.cards {
            #expect(!card.seat(on: .detail).contains(card.provider))
            #expect(!card.seat(on: .detail).contains(card.plan ?? "\u{0}"))
        }
        let accountOnly = Self.copy(claude, pace: claude.pace, stale: nil, account: "office", plan: nil)
        #expect(accountOnly.seat(on: .detail) == "office")

        // Sixty characters of account keep the face its height.
        let long = Self.copy(claude, pace: claude.pace, stale: nil,
                             account: String(repeating: "a", count: 48) + " seat account", plan: "Max 20x")
        #expect(long.seat(on: .detail).count >= 60)
        Glance.appearances { light in
            Widths.atOrdinaryStep { step in
                let width = CardMetrics.minimumWidth
                let short = Self.height(DetailFace(card: claude, detail: CardDetail.make(
                    card: claude, history: nil, selected: nil)).modifier(CardBox()), width: width)
                let wide = Self.height(DetailFace(card: long, detail: CardDetail.make(
                    card: long, history: nil, selected: nil)).modifier(CardBox()), width: width)
                #expect(short > 0 && short == wide, "light \(light), step \(step)")
            }
        }
    }

    // MARK: - Hover is a value, and the frame never moves

    @Test func hoverIsAValueAndNeverMovesTheCard() {
        #expect(CardDetailMetrics.fade == 0.2)
        let mirror = GaugeMirror.shared
        let (seats, snapshot) = PanelHeightTests.populate(now: Self.now)
        let was = (mirror.snapshot, mirror.seats, mirror.hovered)
        defer {
            mirror.apply(was.0, seats: was.1)
            mirror.hover(was.2)
        }
        mirror.apply(snapshot, seats: seats)
        mirror.hover(seats[1].id)
        let model = mirror.model(at: Self.now)
        #expect(model.hovered == seats[1].id)
        #expect(model.face(seats[1].id) == .detail)
        #expect(seats.filter { $0.id != seats[1].id }.allSatisfy { model.face($0.id) == .glance })
        mirror.hover(nil)
        #expect(mirror.model(at: Self.now).hovered == nil)

        let card = model.cards[0]
        let detail = model.details[card.id]
        Glance.appearances { light in
            Widths.atOrdinaryStep { step in
                for width in [CardMetrics.minimumWidth] {
                    let glance = Widths.render(CardView(card: card, detail: detail, face: .glance), width: width)
                    let shown = Widths.render(CardView(card: card, detail: detail, face: .detail), width: width)
                    #expect(glance != nil && glance?.width == shown?.width && glance?.height == shown?.height,
                            "light \(light), step \(step), width \(width)")
                    let faces = [Self.height(GlanceFace(card: card).modifier(CardBox()), width: width),
                                 Self.height(DetailFace(card: card, detail: detail ?? CardDetail.make(
                                    card: card, history: nil, selected: nil)).modifier(CardBox()), width: width)]
                    #expect(abs((glance?.height ?? 0) - faces[0]) <= 1 && faces[1] <= faces[0],
                            "light \(light), step \(step): \(glance?.height ?? 0) against \(faces)")
                }
            }
        }
    }

    // MARK: - `CardDetailMetrics` owns the detail face's heights

    @Test func theDetailFaceIsItsHeaderAndItsMetricsWhateverItHolds() {
        typealias Base = CardDetailMetrics.Base
        #expect([Base.headerToStatus, Base.statusToPlot, Base.plotToControls, Base.plotFloor] == [4, 4, 4, 16])
        #expect(Base.controlsSpacing == 8)
        for factor: CGFloat in [1, 2, 3] {
            let gaps = [Base.headerToStatus, Base.statusToPlot, Base.plotToControls]
                .map { CardMetrics.scaled($0) * factor }.reduce(0, +)
            let body = gaps + CardMetrics.scaled(Base.plotFloor) + CardDetailMetrics.lineHeight * 2
            #expect(abs(CardDetailMetrics.minimumBody(factor) - body) < 0.01)
            #expect(abs(CardDetailMetrics.plotFloor - CardMetrics.scaled(Base.plotFloor)) < 0.01)
        }

        let model = Self.pair()
        guard let card = model.cards.first else { Issue.record("no card"); return }
        let bare = Self.copy(card, pace: nil, stale: nil, account: nil, plan: nil)
        Glance.appearances { light in
            Widths.atOrdinaryStep { step in
                for factor: CGFloat in [1, 3] {
                    let width = CardMetrics.minimumWidth
                    let header = Self.height(CardHeader(card: card).fixedSize(horizontal: false, vertical: true),
                                             width: width - (CardMetrics.horizontalPadding + PanelLayout.boxInset) * 2)
                    let expected = CGFloat(header) / Widths.scale + VerticalFit.boxPadding(factor) * 2
                        + PanelLayout.boxInset * 2 + CardDetailMetrics.minimumBody(factor)
                    for shown in [card, bare] {
                        let drawn = Self.height(DetailFace(card: shown, detail: CardDetail.make(
                            card: shown, history: nil, selected: nil)).modifier(CardBox()),
                            width: width, factor: factor)
                        #expect(abs(CGFloat(drawn) / Widths.scale - expected) <= 1,
                                "light \(light), step \(step), factor \(factor): \(drawn) against \(expected)")
                    }
                }
            }
        }
    }
}
