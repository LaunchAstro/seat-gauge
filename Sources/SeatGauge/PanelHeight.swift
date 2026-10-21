import CoreGraphics

/// The content's height at a vertical factor, a number of card rows and a
/// width: the one thing the height rule needs from the panel it sizes.
protocol ContentMeasuring {
    func contentHeight(at factor: CGFloat, width: CGFloat) -> CGFloat
    func contentHeight(at factor: CGFloat, rows: Int, width: CGFloat) -> CGFloat
    /// The most rows any tab can stack its cards in: one card a row.
    var maxRows: Int { get }
}

extension ContentMeasuring {
    /// A content with one row has nothing to stack.
    func contentHeight(at factor: CGFloat, rows: Int, width: CGFloat) -> CGFloat {
        contentHeight(at: factor, width: width)
    }

    var maxRows: Int { 1 }
}

/// What the window does after one event: draw at `factor` in `rows`, hold the
/// content at `lock`, and let a drag cover `range`. No lock and no range is a
/// content that could not be measured, and the window keeps the frame it has.
struct HeightFit: Equatable {
    let factor: CGFloat
    var rows = 1
    let lock: CGFloat?
    let range: ClosedRange<CGFloat>?

    init(factor: CGFloat, rows: Int = 1, lock: CGFloat?, range: ClosedRange<CGFloat>?) {
        self.factor = factor
        self.rows = rows
        self.lock = lock
        self.range = range
    }
}

/// The window's height rule. Each number of rows has its own span, from its
/// cards at factor 1 to the top of `VerticalFit.range`. The user's chosen
/// height takes the most rows whose span starts at or under it, and the
/// factor places it inside that span, so the cards grow to their tallest and
/// then a row more fits. Capped by the screen's room; a chosen height the
/// cards outgrow gives way to them.
final class PanelHeight {
    /// The content height the user last dragged to or saved; nil is the
    /// minimum. It outlives a raised minimum, so the window returns to it
    /// when the cards shrink again.
    var chosen: CGFloat?

    /// The factor and rows last handed out. A drag keeps them until the
    /// drag ends: a content redrawn mid-drag would be locked again under the
    /// pointer.
    private var factor: CGFloat = 1
    private var rows = 1
    private var dragging = false
    private var drag: Ladder?
    private let measuring: any ContentMeasuring

    /// One span: the content at `rows` from factor 1 to the top.
    private struct Step {
        let rows: Int
        let low: CGFloat
        let high: CGFloat
    }

    /// Every row count's span at one width, fewest rows first.
    private struct Ladder {
        let width: CGFloat
        let steps: [Step]

        var low: CGFloat { steps[0].low }
        var high: CGFloat { steps.map(\.high).max() ?? low }
    }

    init(measuring: any ContentMeasuring) {
        self.measuring = measuring
    }

    /// The cards, the text size, the tab or the width changed. Mid-drag the
    /// range follows the content and the fit waits for the drag's end.
    func contentChanged(width: CGFloat, room: CGFloat) -> HeightFit {
        guard let ladder = ladder(at: width) else { return unreadable() }
        if dragging {
            drag = ladder
            return HeightFit(factor: factor, rows: rows, lock: nil, range: Self.range(ladder, room: room))
        }
        let top = min(ladder.high, room)
        let step = Self.step(chosen: chosen.map { min($0, top) }, ladder)
        let fitted = Self.factor(chosen: chosen.map { min($0, top) }, minimum: step.low, maximum: step.high)
        let lock = switch fitted {
        case VerticalFit.range.lowerBound: step.low
        case VerticalFit.range.upperBound: step.high
        default: measuring.contentHeight(at: fitted, rows: step.rows, width: width)
        }
        guard Self.readable(lock) else { return unreadable() }
        factor = fitted
        rows = step.rows
        return HeightFit(factor: fitted, rows: step.rows, lock: lock, range: Self.range(ladder, room: room))
    }

    func dragStarted(width: CGFloat, room: CGFloat) -> HeightFit {
        dragging = true
        drag = nil
        return dragStepped(width: width, room: room)
    }

    /// A new width is measured again; the fit waits for the drag's end,
    /// unless the content cannot be read.
    func dragStepped(width: CGFloat, room: CGFloat) -> HeightFit {
        if drag.map({ abs($0.width - width) >= 1 }) ?? true { drag = ladder(at: width) }
        guard let drag else { return unreadable() }
        return HeightFit(factor: factor, rows: rows, lock: nil, range: Self.range(drag, room: room))
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

    /// The content between events, at the fit last handed out: the height
    /// the window rests at, at this width. Nil is a content that could not be
    /// read.
    func resting(width: CGFloat) -> CGFloat? {
        let height = measuring.contentHeight(at: factor, rows: rows, width: width)
        return Self.readable(height) ? height : nil
    }

    /// The heights a drag may cover at this width, with no event in it.
    func range(width: CGFloat, room: CGFloat) -> ClosedRange<CGFloat>? {
        ladder(at: width).map { Self.range($0, room: room) }
    }

    private func ladder(at width: CGFloat) -> Ladder? {
        var steps: [Step] = []
        for count in 1...max(1, measuring.maxRows) {
            let low = measuring.contentHeight(at: VerticalFit.range.lowerBound, rows: count, width: width)
            let high = measuring.contentHeight(at: VerticalFit.range.upperBound, rows: count, width: width)
            guard Self.readable(low), Self.readable(high) else { return nil }
            steps.append(Step(rows: count, low: low, high: max(low, high)))
        }
        return Ladder(width: width, steps: steps)
    }

    private func unreadable() -> HeightFit {
        factor = 1
        rows = 1
        return HeightFit(factor: 1, lock: nil, range: nil)
    }

    private static func readable(_ height: CGFloat) -> Bool { height.isFinite && height > 0 }

    /// The fewest rows at factor 1 up to the tallest span's top or the
    /// screen, whichever is lower.
    private static func range(_ ladder: Ladder, room: CGFloat) -> ClosedRange<CGFloat> {
        ladder.low...max(ladder.low, min(ladder.high, room))
    }

    /// The most rows whose span starts at or under the chosen height, and
    /// one row when nothing is chosen. Of counts that start at the same
    /// height, the fewest: a narrow window can already wrap one tab's cards
    /// into those rows, and a tab whose cards still fit across keeps them so.
    private static func step(chosen: CGFloat?, _ ladder: Ladder) -> Step {
        guard let chosen, let most = ladder.steps.last(where: { $0.low <= chosen + 0.5 }) else {
            return ladder.steps[0]
        }
        return ladder.steps.first { abs($0.low - most.low) < 0.5 } ?? most
    }

    /// No height, a height under the minimum, or a content with nothing to
    /// scale is factor 1.
    private static func factor(chosen: CGFloat?, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        guard let chosen, maximum - minimum >= 1, chosen > minimum else { return 1 }
        let share = (chosen - minimum) / (maximum - minimum)
        return VerticalFit.clamped(1 + share * (VerticalFit.range.upperBound - 1))
    }
}
