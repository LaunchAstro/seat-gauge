import Foundation

/// The user's text size, as a step on a short ladder rather than a free point
/// size. One step is one `Cmd +`, and everything drawn multiplies by the same
/// factor: the type in `Type` and the width rules in `CardMetrics` and
/// `PanelLayout`, so the panel scales rather than growing a second set of
/// numbers beside the first.
public struct TextScale: Equatable, Sendable {
    /// The ladder: each step's factor on the written numbers, and its label
    /// as the user reads it. Factor 1 is the size the numbers are written at;
    /// the labels count from the default, step 2, so it reads 100 percent.
    public static let factors: [Double] = [0.85, 1, 1.15, 1.35, 1.6, 1.85, 2.15]
    public static let percents = [75, 85, 100, 115, 135, 160, 185]
    public static let steps: ClosedRange<Int> = 0...(factors.count - 1)

    public let step: Int

    /// A step off either end is the end, not a crash and not an unreadable
    /// window: a held `Cmd +` stops at the largest size.
    public init(step: Int) {
        self.step = min(Self.steps.upperBound, max(Self.steps.lowerBound, step))
    }

    public var factor: Double { Self.factors[step] }
    public var percent: Int { Self.percents[step] }

    /// The written size, factor 1, which the drawing tests run at. Not the
    /// default, which is one up.
    public static let normal = TextScale(step: 1)
    public static let `default` = TextScale(step: 2)
    public static let smallest = TextScale(step: steps.lowerBound)
    public static let largest = TextScale(step: steps.upperBound)

    public func stepped(by rungs: Int) -> TextScale { TextScale(step: step + rungs) }

    /// A number written in points at the ordinary size, read at this one.
    public func scaled(_ base: Double) -> Double { base * factor }
}
