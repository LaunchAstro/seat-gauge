import CoreGraphics

/// The content's height at a vertical factor and a width: the one thing the
/// height rule needs from the panel it sizes.
protocol ContentMeasuring {
    func contentHeight(at factor: CGFloat, width: CGFloat) -> CGFloat
}

/// What the window does after one event: draw at `factor`, hold the content
/// at `lock`, and let a drag cover `range`. No lock and no range is a content
/// that could not be measured, and the window keeps the frame it has.
struct HeightFit: Equatable {
    let factor: CGFloat
    let lock: CGFloat?
    let range: ClosedRange<CGFloat>?
}

/// The window's height rule. The window is as tall as its content
/// at a factor, and the factor places the user's chosen height between the
/// content's height at factor 1 and at the top of `VerticalFit.range`, capped
/// by the screen's room. A chosen height the cards outgrow gives way to them.
final class PanelHeight {
    /// The content height the user last dragged to or saved; nil is the
    /// minimum. It outlives a raised minimum, so the window returns to it
    /// when the cards shrink again.
    var chosen: CGFloat?

    /// The factor last handed out. A drag keeps it until the drag ends: a
    /// content redrawn mid-drag would be locked again under the pointer.
    private var factor: CGFloat = 1
    private var dragging = false
    private var drag: Ends?
    private let measuring: any ContentMeasuring

    private struct Ends {
        let width: CGFloat
        let low: CGFloat
        let high: CGFloat
    }

    init(measuring: any ContentMeasuring) {
        self.measuring = measuring
    }

    /// The cards, the text size, the tab or the width changed. Mid-drag the
    /// range follows the content and the factor waits for the drag's end.
    func contentChanged(width: CGFloat, room: CGFloat) -> HeightFit {
        guard let ends = ends(at: width) else { return unreadable() }
        if dragging {
            drag = ends
            return HeightFit(factor: factor, lock: nil, range: Self.range(ends, room: room))
        }
        let top = min(ends.high, room)
        let fitted = Self.factor(chosen: chosen.map { min($0, top) }, minimum: ends.low, maximum: ends.high)
        let lock = switch fitted {
        case VerticalFit.range.lowerBound: ends.low
        case VerticalFit.range.upperBound: ends.high
        default: measuring.contentHeight(at: fitted, width: width)
        }
        guard Self.readable(lock) else { return unreadable() }
        factor = fitted
        return HeightFit(factor: fitted, lock: lock, range: Self.range(ends, room: room))
    }

    func dragStarted(width: CGFloat, room: CGFloat) -> HeightFit {
        dragging = true
        drag = nil
        return dragStepped(width: width, room: room)
    }

    /// A new width is measured again; the factor waits for the drag's end,
    /// unless the content cannot be read.
    func dragStepped(width: CGFloat, room: CGFloat) -> HeightFit {
        if drag.map({ abs($0.width - width) >= 1 }) ?? true { drag = ends(at: width) }
        guard let drag else { return unreadable() }
        return HeightFit(factor: factor, lock: nil, range: Self.range(drag, room: room))
    }

    /// The drag's height is the user's.
    func dragEnded(shown: CGFloat, width: CGFloat, room: CGFloat) -> HeightFit {
        dragging = false
        drag = nil
        chosen = shown
        return contentChanged(width: width, room: room)
    }

    /// A saved height over the one the window opens at is the user's; at or
    /// under it, it is not taken, as a width under the minimum is not.
    func restored(savedContent: CGFloat, opensAt: CGFloat) {
        if savedContent > opensAt + 1 { chosen = savedContent }
    }

    /// The content between events, at the factor last handed out: the height
    /// the window rests at, at this width. Nil is a content that could not be
    /// read.
    func resting(width: CGFloat) -> CGFloat? {
        let height = measuring.contentHeight(at: factor, width: width)
        return Self.readable(height) ? height : nil
    }

    /// The heights a drag may cover at this width, with no event in it.
    func range(width: CGFloat, room: CGFloat) -> ClosedRange<CGFloat>? {
        ends(at: width).map { Self.range($0, room: room) }
    }

    private func ends(at width: CGFloat) -> Ends? {
        let low = measuring.contentHeight(at: VerticalFit.range.lowerBound, width: width)
        let high = measuring.contentHeight(at: VerticalFit.range.upperBound, width: width)
        guard Self.readable(low), Self.readable(high) else { return nil }
        return Ends(width: width, low: low, high: max(low, high))
    }

    private func unreadable() -> HeightFit {
        factor = 1
        return HeightFit(factor: 1, lock: nil, range: nil)
    }

    private static func readable(_ height: CGFloat) -> Bool { height.isFinite && height > 0 }

    /// Factor 1 up to the top of the range or the screen, whichever is lower.
    private static func range(_ ends: Ends, room: CGFloat) -> ClosedRange<CGFloat> {
        ends.low...max(ends.low, min(ends.high, room))
    }

    /// No height, a height under the minimum, or a content with nothing to
    /// scale is factor 1.
    private static func factor(chosen: CGFloat?, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        guard let chosen, maximum - minimum >= 1, chosen > minimum else { return 1 }
        let share = (chosen - minimum) / (maximum - minimum)
        return VerticalFit.clamped(1 + share * (VerticalFit.range.upperBound - 1))
    }
}
