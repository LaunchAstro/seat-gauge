import Foundation

/// How a weekly window is tracking against its own reset: the elapsed fraction, the dry moment projected from it,
/// and the 5% slack that separates running out from landing on the reset.
/// There is no pace for a window nothing has been spent in.
public enum Pace: Equatable, Sendable {
    /// The dry moment, more than 5% of the window's length before the reset.
    case runsOut(at: Date)
    /// Projected usage at the reset is under 90%, and this much goes unused.
    case unused(percent: Int)
    case onPace

    public init?(weekly window: Window, now: Date) {
        guard window.usedPercent > 0 else { return nil }
        let length = window.length.seconds
        guard length > 0 else { return nil }
        let remaining = max(0, window.resetsAt.timeIntervalSince(now))
        let elapsed = length - remaining
        let fraction = max(0.01, elapsed / length)
        let start = window.resetsAt.addingTimeInterval(-length)
        let dry = start.addingTimeInterval(elapsed * 100 / Double(window.usedPercent))
        let slack = length * 0.05
        let projectedAtReset = min(100, Double(window.usedPercent) / fraction)
        if dry < window.resetsAt.addingTimeInterval(-slack) {
            self = .runsOut(at: dry)
        } else if projectedAtReset < 90 {
            self = .unused(percent: Int(100 - projectedAtReset))
        } else {
            self = .onPace
        }
    }
}

/// How far off pace a weekly window is, for its meter's colour. Finishing
/// a few days before the reset is the goal, so that much early is still good.
public enum PaceGrade: Equatable, Sendable {
    case good, warning, danger

    /// Every threshold the grade reads, in one place.
    public enum Threshold {
        /// Running out up to this many days before the reset is good.
        public static let goodDaysEarly: Double = 2
        /// Past the good days and up to this many is a warning; more is danger.
        public static let warningDaysEarly: Double = 4
        /// Unused percent at the reset from which the grade is a warning.
        public static let warningUnused = 10
        /// Unused percent at the reset from which the grade is danger.
        public static let dangerUnused = 50
    }

    /// Nil where `Pace` has no verdict, so the meter keeps its usage colour.
    public init?(weekly window: Window, now: Date) {
        guard let pace = Pace(weekly: window, now: now) else { return nil }
        switch pace {
        case .onPace:
            self = .good
        case let .runsOut(at):
            let days = window.resetsAt.timeIntervalSince(at) / 86_400
            self = days <= Threshold.goodDaysEarly ? .good : days <= Threshold.warningDaysEarly ? .warning : .danger
        case let .unused(percent):
            self = percent >= Threshold.dangerUnused ? .danger : percent >= Threshold.warningUnused ? .warning : .good
        }
    }
}

/// A countdown, taking two instants so a test can name the
/// moment it reads from. Minutes, then hours and minutes, then days and hours.
/// Seconds are never drawn.
public enum Countdown {
    public static func text(until: Date, now: Date) -> String {
        let total = Int(max(0, until.timeIntervalSince(now)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        return hours > 0 ? String(format: "%d:%02d", hours, minutes) : "\(minutes)m"
    }
}

extension Window {
    /// Several seats' readings of one window as one: the plain average of
    /// their used percent, reset at the average of their resets, so `Pace`
    /// reads the average elapsed share. Nil when no seat reports it.
    public static func combined(_ windows: [Window]) -> Window? {
        guard let first = windows.first else { return nil }
        let count = Double(windows.count)
        let used = Double(windows.map(\.usedPercent).reduce(0, +)) / count
        let reset = windows.map(\.resetsAt.timeIntervalSince1970).reduce(0, +) / count
        return Window(kind: first.kind, usedPercent: Int(used.rounded()),
                      resetsAt: Date(timeIntervalSince1970: reset), length: first.length)
    }
}
