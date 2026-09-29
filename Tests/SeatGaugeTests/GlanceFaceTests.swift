import AppKit
import CoreText
import Foundation
import SwiftUI
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// The glance face: provider-first headers, the mark, the card box and the
/// type sizes. Renders go through `ImageRenderer` bitmaps, so no window opens.
@Suite(.serialized, .sharedMirror) @MainActor struct GlanceFaceTests {

    typealias Widths = CardWidthTests

    static let root = Widths.root
    static let now = Date(timeIntervalSince1970: 1_758_500_100)

    static func claude(_ id: String, account: String? = nil, plan: String? = nil) -> Seat {
        Seat(id: SeatID(rawValue: id), label: id,
             kind: .claude(profileDir: URL(fileURLWithPath: "/tmp/seat-gauge-\(id)")),
             account: account, plan: plan)
    }

    static func codex(_ id: String) -> Seat {
        Seat(id: SeatID(rawValue: id), label: id, kind: .codex)
    }

    static func window(_ kind: WindowKind, used: Int, in seconds: Double = 86_400) -> SeatGaugeCore.Window {
        SeatGaugeCore.Window(kind: kind, usedPercent: used, resetsAt: now.addingTimeInterval(seconds),
                             length: .seconds(kind == .fiveHour ? 5 * 3600 : 7 * 86_400))
    }

    static func panel(_ seats: [Seat], _ windows: [[SeatGaugeCore.Window]]) -> PanelModel {
        var states: [SeatID: SeatState] = [:]
        for (seat, read) in zip(seats, windows) {
            states[seat.id] = .live(Reading(seat: seat.id, windows: read, takenAt: now, plan: nil))
        }
        return PanelModel.make(snapshot: Snapshot(states: states, order: seats.map(\.id)), seats: seats, now: now)
    }

    /// The same card with a different verdict or stale line.
    static func copy(_ card: CardModel, pace: PaceLine?, stale: String?) -> CardModel {
        CardModel(id: card.id, label: card.label, isBest: card.isBest,
                  lines: card.lines, pace: pace, stale: stale, mark: card.mark,
                  account: card.account, plan: card.plan)
    }

    /// Drawn once more if it differs: the renderer's first pass at a size can
    /// set text a shade differently from its later ones.
    static func same<A: View, B: View>(_ a: A, _ b: B, width: CGFloat, scale: CGFloat = Widths.scale) -> Bool {
        (0..<2).contains { _ in
            let then = Widths.render(a, width: width, scale: scale)
            return then != nil && then == Widths.render(b, width: width, scale: scale)
        }
    }

    /// The default (dark) appearance, put back afterwards. The light one
    /// swaps the palette and draws the same layout.
    static func appearances(_ body: (Bool) throws -> Void) rethrows {
        let was = GaugeMirror.shared.lightAppearance
        defer { GaugeMirror.shared.lightAppearance = was }
        GaugeMirror.shared.lightAppearance = false
        try body(false)
    }

    static func rgba(_ color: Color) -> [CGFloat] {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .clear
        return [ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent]
    }

    static func sameColour(_ a: Color, _ b: Color) -> Bool {
        zip(rgba(a), rgba(b)).allSatisfy { abs($0 - $1) < 0.002 }
    }

    static func fittingWidth<V: View>(_ view: V) -> CGFloat {
        NSHostingView(rootView: view.fixedSize()).fittingSize.width
    }

    // MARK: - Provider first, in ink, with a plain pick

    @Test func theHeaderReadsProviderFirstInInkWithAPlainPick() throws {
        let model = Self.panel([Self.claude("work"), Self.codex("personal")],
                               [[Self.window(.fiveHour, used: 20)], [Self.window(.weekly, used: 50)]])
        #expect(model.cards.count == 2)
        guard model.cards.count == 2 else { return }
        let claude = model.cards[0], codex = model.cards[1]
        #expect(claude.heading == "CLAUDE  work")
        #expect(claude.provider == "Claude" && claude.label == "work" && claude.mark == .claude)
        #expect(codex.heading == "CODEX  personal")
        #expect(codex.provider == "Codex" && codex.label == "personal" && codex.mark == .codex)
        // Headroom alone picks, and one card carries it.
        #expect(claude.isBest && !codex.isBest)
        #expect(CardMetrics.Header.seat < CardMetrics.Header.provider)
        #expect(CardMetrics.Header.pick == "▲ USE")

        // Every pixel of a best card's header is a grey: the ink, the muted
        // ink or their edges, never the accent.
        Self.appearances { light in
            Widths.atOrdinaryStep { step in
                for card in [claude, codex] {
                    let header = CardHeader(card: card).padding(.horizontal, CardMetrics.horizontalPadding)
                    guard let bitmap = Widths.render(header, width: CardMetrics.minimumWidth) else {
                        Issue.record("no header render, light \(light), step \(step)")
                        continue
                    }
                    var coloured = 0, inked = 0
                    for y in 0..<bitmap.height {
                        for x in 0..<bitmap.width where bitmap.alpha(x, y) > 0 {
                            inked += 1
                            let p = bitmap.pixel(x, y).map(Int.init)
                            if abs(p[0] - p[1]) > 3 || abs(p[1] - p[2]) > 3 || abs(p[0] - p[2]) > 3 { coloured += 1 }
                        }
                    }
                    #expect(inked > 0, "light \(light), step \(step), \(card.label)")
                    #expect(coloured == 0, "light \(light), step \(step), \(card.label): \(coloured) coloured pixels")
                }
            }
        }
    }

    // MARK: - The mark steps with the text

    @Test func theMarkScalesWithTheTextAndHoldsItsFloor() {
        #expect(SeatMark.baseSide >= 14)
        var sides: [CGFloat] = []
        for step in TextScale.steps {
            let side = SeatMark.side(TextScale(step: step))
            #expect(side >= SeatMark.minimumSide)
            sides.append(side)
        }
        #expect(zip(sides, sides.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(SeatMark.side(.largest) > SeatMark.side(.smallest))
    }

    // MARK: - One box for every card

    @Test func everyCardSitsInTheSameBox() throws {
        #expect(PanelLayout.boxInset > 0)
        for palette in [Palette.dark, Palette.light] {
            #expect(!Self.sameColour(palette.box, palette.bg))
        }

        // The best card's box and a plain card's, read inside each box's
        // left padding, where nothing but the box is drawn.
        let pair = [Widths.card("work", picked: true, provider: "Claude"), Widths.card("personal", picked: false)]
        Self.appearances { light in
            Widths.atOrdinaryStep { step in
                let width = PanelLayout.minimumContentWidth(cards: 2) + 100
                guard let bitmap = Widths.render(ComboLayout(cards: pair), width: width) else {
                    Issue.record("no render, light \(light), step \(step)")
                    return
                }
                let shares = PanelLayout.cardWidths(contentWidth: width, cards: 2)
                let y = bitmap.height / 2
                let xs = [PanelLayout.boxInset + 4, shares[0] + PanelLayout.ruleWidth + PanelLayout.boxInset + 4]
                    .map { Int(($0 * Widths.scale).rounded()) }
                let best = bitmap.pixel(xs[0], y), plain = bitmap.pixel(xs[1], y)
                #expect(bitmap.alpha(xs[0], y) > 0, "light \(light), step \(step)")
                #expect(Array(best) == Array(plain), "light \(light), step \(step): \(Array(best)) \(Array(plain))")
            }
        }

        Widths.atOrdinaryStep { _ in
            for count in 1...4 {
                let floor = PanelLayout.minimumContentWidth(cards: count)
                #expect(floor >= CGFloat(count) * CardMetrics.minimumWidth)
                for width in stride(from: floor, through: 6016, by: 311) {
                    let widths = PanelLayout.cardWidths(contentWidth: width, cards: count)
                    #expect(widths.allSatisfy { $0 >= CardMetrics.minimumWidth })
                    let drawn = widths.reduce(0, +) + CGFloat(count - 1) * PanelLayout.ruleWidth
                    #expect(abs(drawn - width) < 1)
                }
            }
        }
    }

    // MARK: - Type sizes, and the countdowns fit their column

    @Test func theTypeIsAStepBiggerButTheCountdowns() throws {
        #expect(CardMetrics.Glance.label == 10)
        #expect(CardMetrics.Glance.percent == 10)
        #expect(CardMetrics.Glance.note == 10)
        #expect(CardMetrics.Glance.countdown == 12)
        #expect(CardMetrics.Header.provider == 11)
        #expect(CardMetrics.Header.seat == 10)
        #expect(CardMetrics.Header.pickSize == 10)

        let faces = Type.registered
        defer { Type.registered = faces }
        for registered in [Set<String>(), Widths.registerBundledFaces()] {
            Type.registered = registered
            Widths.atOrdinaryStep { step in
                let name = Self.fittingWidth(SeatGauge.Label(text: "FABLE", size: CardMetrics.Glance.label))
                let percent = Self.fittingWidth(Text("100%").font(Type.mono(CardMetrics.Glance.percent))
                    .tracking(CardMetrics.digitTracking))
                let countdown = Self.fittingWidth(Text("12d 23h").font(Type.display(CardMetrics.Glance.countdown))
                    .monospacedDigit().tracking(CardMetrics.digitTracking))
                let faces = registered.isEmpty ? "system" : "bundled"
                #expect(name <= CardMetrics.nameWidth + 0.5, "\(faces), step \(step): FABLE \(name)")
                #expect(percent <= CardMetrics.percentWidth + 0.5, "\(faces), step \(step): 100% \(percent)")
                #expect(countdown <= CardMetrics.countdownWidth + 0.5, "\(faces), step \(step): 12d 23h \(countdown)")
            }
        }
    }

    // MARK: - The bar 4 pt closer to its numbers

    @Test func theBarSitsFourPointsCloserToItsNumbers() {
        #expect(CardMetrics.Base.meterGap == CardMetrics.Base.columnSpacing - 4)
        Widths.atOrdinaryStep { step in
            #expect(abs(CardMetrics.meterGap - CardMetrics.scaled(CardMetrics.Base.meterGap)) < 0.001)
            let fixed = CardMetrics.nameWidth + CardMetrics.countdownWidth + CardMetrics.percentWidth
                + CardMetrics.columnSpacing * 2 + CardMetrics.meterGap
                + CardMetrics.horizontalPadding * 2 + PanelLayout.boxInset * 2
            #expect(abs(CardMetrics.fixedColumns - fixed) < 0.001, "step \(step)")

            let width = CardMetrics.minimumWidth + 90.5
            guard let full = Widths.render(CardView(card: Widths.oneLine(used: 100)), width: width),
                  let empty = Widths.render(CardView(card: Widths.oneLine(used: 0)), width: width),
                  full.width == empty.width, full.height == empty.height else {
                Issue.record("renders differ in size at step \(step)")
                return
            }
            var longest = (length: 0, start: 0, row: 0)
            for y in 0..<full.height {
                var run = 0
                for x in 0..<full.width {
                    run = full.pixel(x, y) == empty.pixel(x, y) ? 0 : run + 1
                    if run > longest.length { longest = (run, x - run + 1, y) }
                }
            }
            let start = CGFloat(longest.start) / Widths.scale
            let fill = CGFloat(longest.length) / Widths.scale
            let lineStart = PanelLayout.boxInset + CardMetrics.horizontalPadding
            #expect(abs(start - (lineStart + CardMetrics.nameWidth + CardMetrics.columnSpacing)) <= 1,
                    "step \(step): fill starts at \(start)")
            #expect(abs(fill - (width - CardMetrics.fixedColumns)) <= 1, "step \(step): fill \(fill)")

            // The percent's last ink, over every row the line spans.
            let lineEnd = width - lineStart
            let band = Int(CardMetrics.scaled(8) * Widths.scale)
            var last = 0
            for y in max(0, longest.row - band)..<min(full.height, longest.row + band) {
                for x in 0..<full.width where full.alpha(x, y) > 100 { last = max(last, x + 1) }
            }
            let end = CGFloat(last) / Widths.scale
            #expect(end <= lineEnd + 0.5, "step \(step): percent ends at \(end), line at \(lineEnd)")
            #expect(end >= lineEnd - CardMetrics.scaled(3), "step \(step): percent ends at \(end), line at \(lineEnd)")
        }
    }
}
