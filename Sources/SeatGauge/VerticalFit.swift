import CoreGraphics
import SeatGaugeCore
import SwiftUI

/// Where the user's extra height goes: one factor over the
/// meter's thickness, the gap between window lines and the box's padding, so
/// the text stays on its `Cmd +` ladder. The range's top keeps the tallest
/// window reading as the same panel.
enum VerticalFit {
    static let range: ClosedRange<CGFloat> = 1...3

    /// The three at factor 1, at the ordinary text size.
    enum Base {
        /// The thinnest meter drawn.
        static let meter: CGFloat = 5
        /// The gap a window line gains at the top of the range.
        static let rowGap: CGFloat = 12
        /// The box's padding above and below its lines.
        static let boxPadding: CGFloat = 9
    }

    /// The factor the panel is drawn at, read inside a view body.
    static var current: CGFloat { GaugeMirror.shared.verticalFactor }

    static func clamped(_ factor: CGFloat) -> CGFloat {
        min(range.upperBound, max(range.lowerBound, factor.isFinite ? factor : 1))
    }

    private static func share(_ factor: CGFloat) -> CGFloat {
        (clamped(factor) - 1) / (range.upperBound - 1)
    }

    static func meterHeight(_ factor: CGFloat) -> CGFloat { Base.meter * clamped(factor) }

    /// Extra space between lines, scaled with the text as every gap is.
    static func rowGap(_ factor: CGFloat) -> CGFloat {
        CardMetrics.scaled(Base.rowGap) * share(factor)
    }

    static func boxPadding(_ factor: CGFloat) -> CGFloat {
        CardMetrics.scaled(Base.boxPadding) * clamped(factor)
    }
}

/// A factor pinned for one tree, for measuring; nil is the user's.
private struct PinnedVerticalFactor: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var pinnedVerticalFactor: CGFloat? {
        get { self[PinnedVerticalFactor.self] }
        set { self[PinnedVerticalFactor.self] = newValue }
    }
}
