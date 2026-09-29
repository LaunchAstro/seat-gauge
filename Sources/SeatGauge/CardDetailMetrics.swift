import AppKit

/// The detail face's gaps and plot floor, written at the ordinary text size
/// like `CardMetrics`, the vertical ones times the user's factor. The face
/// fits inside the glance face's height: the plot takes whatever the two text
/// rows and the gaps leave, and never less than its floor.
enum CardDetailMetrics {
    enum Base {
        static let headerToStatus: CGFloat = 4
        static let statusToPlot: CGFloat = 4
        static let plotToControls: CGFloat = 4
        /// The least the plot is drawn at, which only a card with fewer
        /// window lines than the face needs ever meets. It follows the text
        /// and not the factor, so a taller window never lifts it over the
        /// glance face.
        static let plotFloor: CGFloat = 16
        /// Across the row, so it follows the text and not the factor.
        static let controlsSpacing: CGFloat = 8
        static let text: CGFloat = 10
        static let barGap: CGFloat = 1
        /// Under this a bar gives up its gap, so thirty bars still read.
        static let narrowestBar: CGFloat = 2
        static let calloutPadding: CGFloat = 4
    }

    static let fade = 0.2

    static func gap(_ base: CGFloat, _ factor: CGFloat) -> CGFloat {
        CardMetrics.scaled(base) * VerticalFit.clamped(factor)
    }

    static var plotFloor: CGFloat { CardMetrics.scaled(Base.plotFloor) }

    static var controlsSpacing: CGFloat { CardMetrics.scaled(Base.controlsSpacing) }

    /// One row of the face's type, as AppKit sets it.
    static var lineHeight: CGFloat {
        let face = CardMetrics.face(Base.text)
        return (face.ascender - face.descender + face.leading).rounded(.up)
    }

    /// The least the face needs under its header: the status and controls
    /// rows, the three gaps and the plot at its floor.
    static func minimumBody(_ factor: CGFloat) -> CGFloat {
        [Base.headerToStatus, Base.statusToPlot, Base.plotToControls].map { gap($0, factor) }.reduce(0, +)
            + plotFloor + lineHeight * 2
    }

    /// The line width at the narrowest card, which the plot spans.
    static var minimumPlotWidth: CGFloat {
        CardMetrics.minimumWidth - (CardMetrics.horizontalPadding + PanelLayout.boxInset) * 2
    }

    /// Each bar's width and the gap after it, dropped under the narrowest bar.
    static func bars(count: Int, width: CGFloat) -> (bar: CGFloat, gap: CGFloat)? {
        guard count > 0, width.isFinite, width > 0 else { return nil }
        let spaced = (width - Base.barGap * CGFloat(count - 1)) / CGFloat(count)
        return spaced >= Base.narrowestBar ? (spaced, Base.barGap) : (width / CGFloat(count), 0)
    }

    /// The bar whose drawn centre is nearest the pointer, so the pick changes
    /// halfway between two bars and every x across the plot picks one.
    static func bucket(at x: CGFloat, count: Int, width: CGFloat) -> Int? {
        guard let bars = bars(count: count, width: width), x >= 0, x < width else { return nil }
        return min(count - 1, Int((x + bars.gap / 2) / (bars.bar + bars.gap)))
    }
}
