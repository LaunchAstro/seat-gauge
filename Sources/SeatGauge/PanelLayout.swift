import AppKit
import SeatGaugeCore
import SwiftUI

/// The width rules, as functions over widths, so the layout can be read at any
/// width without a display that size plugged in. The layouts at the end of
/// this file place the cards and their lines with these, so what a case reads
/// is what the cards get. Every number is written at the ordinary text size
/// and read at the one the user chose, so a bigger size is a wider card rather than a second set of
/// numbers beside the first.
enum CardMetrics {
    /// The rules as they are written, at the ordinary text size.
    enum Base {
        static let name: CGFloat = 34
        static let countdown: CGFloat = 62
        static let percent: CGFloat = 30
        static let columnSpacing: CGFloat = 8
        /// The gap between the meter and its countdown, 4 pt under the others,
        /// so the bar reads with its numbers as one unit.
        static let meterGap: CGFloat = columnSpacing - 4
        static let horizontalPadding: CGFloat = 12
        /// The narrowest meter still worth drawing. Under this the fill is a
        /// smudge and the card says nothing the percent does not.
        static let minimumMeter: CGFloat = 48
    }

    /// A written number, read at the size the panel is drawn at.
    static func scaled(_ base: CGFloat) -> CGFloat {
        CGFloat(TextScale.current.scaled(Double(base)))
    }

    /// The fixed columns on a window line, left to right.
    static var nameWidth: CGFloat { scaled(Base.name) }
    static var countdownWidth: CGFloat { scaled(Base.countdown) }
    static var percentWidth: CGFloat { scaled(Base.percent) }
    static var columnSpacing: CGFloat { scaled(Base.columnSpacing) }
    static var meterGap: CGFloat { scaled(Base.meterGap) }
    static var horizontalPadding: CGFloat { scaled(Base.horizontalPadding) }
    static var minimumMeter: CGFloat { scaled(Base.minimumMeter) }

    /// The countdown and percent digits' letter spacing, about a point at the
    /// ordinary size and growing with it, so the numbers stop reading as one
    /// block. The two columns above are wide enough for
    /// `12d 23h` and `100%` with it.
    static var digitTracking: CGFloat { scaled(1) }

    /// The glance face's type, written at the ordinary text size.
    enum Glance {
        static let label: CGFloat = 10
        static let percent: CGFloat = 10
        static let countdown: CGFloat = 12
        /// The stale line under the windows.
        static let note: CGFloat = 10
        /// One gap between the header and every line under it.
        static let rowSpacing: CGFloat = 8
    }

    static var rowSpacing: CGFloat { scaled(Glance.rowSpacing) }

    /// Everything on a line that does not stretch: three columns, the gaps
    /// between the four of them, the box's own padding, and the ground left
    /// either side of the box.
    static var fixedColumns: CGFloat {
        nameWidth + countdownWidth + percentWidth + columnSpacing * 2 + meterGap + horizontalPadding * 2
            + PanelLayout.boxInset * 2
    }

    /// The narrowest a card can be drawn before the meter is squeezed out.
    static var minimumWidth: CGFloat { fixedColumns + minimumMeter }

    /// What the meter gets at a given card width: the card's padding and box
    /// inset come off, and the line width left answers.
    static func meterWidth(cardWidth: CGFloat, overflow: CGFloat = 0) -> CGFloat {
        meterWidth(lineWidth: cardWidth - (horizontalPadding + PanelLayout.boxInset) * 2, overflow: overflow)
    }

    /// What the meter gets on a line of a given width, less whatever a
    /// countdown or percent wider than its column takes. Worked from the line
    /// in the order an `HStack` takes its columns off, so the columns after the
    /// meter land on the pixels the stack's did. A width that is no
    /// width at all gets the floor.
    static func meterWidth(lineWidth: CGFloat, overflow: CGFloat = 0) -> CGFloat {
        let room = lineWidth - columnSpacing * 2 - meterGap - nameWidth - countdownWidth - percentWidth - max(0, overflow)
        return room.isFinite && room > minimumMeter ? room : minimumMeter
    }

    /// The header's faces, written at the ordinary text size like everything
    /// above: the provider in the header type, the seat after it in the
    /// smaller muted `Label` face, and the pick as `Cards.swift` draws it.
    enum Header {
        static let provider: CGFloat = 11
        static let providerTracking: CGFloat = 1.0
        static let seat: CGFloat = 10
        static let seatTracking: CGFloat = 0.3
        static let spacing: CGFloat = 6
        static let pick = "▲ USE"
        static let pickSize: CGFloat = 10
        static let pickTracking: CGFloat = 0.5
        /// The plan in the tile's top-right corner, in the seat's face.
        static let plan: CGFloat = 10
        /// The least the `Spacer` after the seat gives, on every card and at
        /// every size: SwiftUI's own default, which does not scale.
        static let spacer: CGFloat = 8
    }

    static var headerSpacing: CGFloat { scaled(Header.spacing) }

    /// How wide a header draws, card padding and box inset included, at the
    /// size the panel is drawn at: the mark when the provider has one, the
    /// provider in capitals, the seat, the spacer after it, the pick when the
    /// card carries it, the plan when it has one and the sync icon.
    /// Measured in the faces `Type` draws, so a case reads the width
    /// `CardHeader` gets.
    static func headerWidth(provider: String, seat: String, picked: Bool, plan: String? = nil,
                            marked: Bool = true) -> CGFloat {
        var width = horizontalPadding * 2 + PanelLayout.boxInset * 2
            + (marked ? SeatMark.side(TextScale.current) + headerSpacing : 0)
            + measured(provider.uppercased(), Header.provider, tracking: scaled(Header.providerTracking),
                       family: "Funnel Display")
            + headerSpacing + measured(seat, Header.seat, tracking: scaled(Header.seatTracking))
            + headerSpacing + Header.spacer
            + headerSpacing + SeatMark.side(TextScale.current)
        if picked {
            width += headerSpacing + measured(Header.pick, Header.pickSize, tracking: Header.pickTracking)
        }
        if let plan {
            width += headerSpacing + measured(plan, Header.plan, tracking: scaled(Header.seatTracking))
        }
        return width
    }

    /// A run of text at a written size, as AppKit lays it out: the bundled
    /// face where it registered, the system face where not.
    private static func measured(_ text: String, _ size: CGFloat, tracking: CGFloat,
                                 family: String = "Chivo Mono") -> CGFloat {
        let run = (text as NSString).size(withAttributes: [.font: face(size, family: family), .kern: tracking]).width
        return run.rounded(.up)
    }

    /// A face at a written size, read at the size the panel is drawn at, in
    /// the one weight `Type` draws. The mono unless another family is named.
    static func face(_ size: CGFloat, family: String = "Chivo Mono") -> NSFont {
        let points = scaled(size)
        let fallback: NSFont = family == "Chivo Mono" ? .monospacedSystemFont(ofSize: points, weight: .light)
            : .systemFont(ofSize: points, weight: .light)
        return FontManifest.familyName(family, registered: Type.registered).flatMap {
            NSFontManager.shared.font(withFamily: $0, traits: [], weight: 3, size: points)
        } ?? fallback
    }
}

/// How the cards share the window's width.
enum PanelLayout {
    /// What separates two cards' shares of the width. Nothing is drawn in it:
    /// each card is its own box, and the gap between two boxes is this and the
    /// ground each box leaves either side of itself.
    static let ruleWidth: CGFloat = 1

    /// The ground left round every card's box.
    static let boxInset: CGFloat = 4

    /// The row's minimum width for a card count: every card at its own
    /// minimum, box and ground included, with the gaps between them. A window
    /// narrower than this scrolls the row sideways rather than drawing a card
    /// under it, and a first launch opens at least this wide.
    static func minimumContentWidth(cards: Int) -> CGFloat {
        guard cards > 0 else { return CardMetrics.minimumWidth }
        return CGFloat(cards) * CardMetrics.minimumWidth + CGFloat(cards - 1) * ruleWidth
    }

    /// The scrolling row's width: as many whole cards as the viewport holds
    /// at their minimum, at least one, each widened to fill it, and every
    /// other card at that width past the edge. A pitch of whole cards keeps
    /// an arrow's step landing a card on the edge.
    static func scrolledRowWidth(viewport: CGFloat, cards: Int) -> CGFloat {
        guard cards > 0, viewport.isFinite, viewport > 0 else { return minimumContentWidth(cards: cards) }
        let shown = min(cards, max(1, Int((viewport + ruleWidth) / (CardMetrics.minimumWidth + ruleWidth))))
        let card = max(CardMetrics.minimumWidth, (viewport - CGFloat(shown - 1) * ruleWidth) / CGFloat(shown))
        return CGFloat(cards) * card + CGFloat(cards - 1) * ruleWidth
    }

    /// Even shares of whatever the gaps leave, never under the card
    /// minimum. A width under the minimum is not a width the window can be
    /// dragged to, and the share is held rather than squeezed. Neither is a
    /// width that is not a number. Each card takes its share of what the
    /// cards before it left, as an `HStack` of equal cards splits a width, so
    /// every share lands on the fraction of a point the stack's did.
    static func cardWidths(contentWidth: CGFloat, cards: Int) -> [CGFloat] {
        guard cards > 0 else { return [] }
        guard contentWidth.isFinite else { return Array(repeating: CardMetrics.minimumWidth, count: cards) }
        var left = contentWidth - CGFloat(cards - 1) * ruleWidth
        return (0..<cards).map { placed in
            let share = max(CardMetrics.minimumWidth, left / CGFloat(cards - placed))
            left -= share
            return share
        }
    }
}

/// The cards side by side at the widths `cardWidths` gives, one rule apart and
/// each as tall as the tallest. Asked for its ideal or its largest size, it
/// answers as an `HStack` would, from the cards' own.
nonisolated struct CardRow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        MainActor.assumeIsolated {
            let gaps = CGFloat(max(0, subviews.count - 1)) * PanelLayout.ruleWidth
            guard let width = proposal.width, width.isFinite else {
                let sizes = subviews.map { $0.sizeThatFits(proposal) }
                return CGSize(width: sizes.map(\.width).reduce(0, +) + gaps, height: sizes.map(\.height).max() ?? 0)
            }
            let widths = PanelLayout.cardWidths(contentWidth: width, cards: subviews.count)
            let heights = zip(subviews, widths).map { card, share in
                card.sizeThatFits(ProposedViewSize(width: share, height: proposal.height)).height
            }
            return CGSize(width: widths.reduce(0, +) + gaps, height: heights.max() ?? 0)
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        MainActor.assumeIsolated {
            var x = bounds.minX
            for (card, share) in zip(subviews, PanelLayout.cardWidths(contentWidth: bounds.width, cards: subviews.count)) {
                card.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: share, height: bounds.height))
                // Two steps, as the stack adds them, so a card's edge rounds
                // to the pixel the stack's did.
                x += share
                x += PanelLayout.ruleWidth
            }
        }
    }
}

/// One window line: the name, the meter, the countdown and the percent,
/// centred on the line. The name's and the percent's gaps are a column
/// spacing, the meter's is `meterGap`, and the meter gets `meterWidth` for the
/// line less whatever a column wider than its rule takes.
nonisolated struct CardLine: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        MainActor.assumeIsolated {
            let sizes = sizes(proposal.width, subviews)
            let ideal: CGFloat = sizes.map(\.width).reduce(0, +) + gaps.reduce(0, +)
            let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ideal
            return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        MainActor.assumeIsolated {
            var x = bounds.minX
            for (index, (column, size)) in zip(subviews, sizes(bounds.width, subviews)).enumerated() {
                column.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(size))
                // Two steps, as a stack adds them, so a column lands on the
                // pixel a stack's would.
                x += size.width
                x += index < gaps.count ? gaps[index] : 0
            }
        }
    }

    @MainActor private var gaps: [CGFloat] {
        [CardMetrics.columnSpacing, CardMetrics.meterGap, CardMetrics.columnSpacing]
    }

    /// The four columns at their own sizes and the meter at `meterWidth`, the
    /// overflow of any column wider than its rule taken off the meter.
    @MainActor private func sizes(_ width: CGFloat?, _ subviews: Subviews) -> [CGSize] {
        guard subviews.count == 4 else { return subviews.map { $0.sizeThatFits(.unspecified) } }
        let name = subviews[0].sizeThatFits(.unspecified)
        let countdown = subviews[2].sizeThatFits(.unspecified)
        let percent = subviews[3].sizeThatFits(.unspecified)
        let wider: [CGFloat] = [name.width - CardMetrics.nameWidth, countdown.width - CardMetrics.countdownWidth,
                                percent.width - CardMetrics.percentWidth]
        let overflow = wider.map { max(0, $0) }.reduce(0, +)
        let meter = width.map { CardMetrics.meterWidth(lineWidth: $0, overflow: overflow) } ?? CardMetrics.minimumMeter
        let track = subviews[1].sizeThatFits(ProposedViewSize(width: meter, height: nil))
        return [name, CGSize(width: meter, height: track.height), countdown, percent]
    }
}
