import Foundation
import Testing

import SeatGaugeCore

/// The weekly meter's colour from its pace: a few cases either side of each
/// threshold, not a matrix.
struct PaceGradeTests {
    static let day = 86_400.0
    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// `used` percent spent `days` into a seven-day week.
    static func grade(_ used: Int, after days: Double) -> PaceGrade? {
        let window = Window(kind: .weekly, usedPercent: used, resetsAt: start.addingTimeInterval(7 * day),
                            length: .seconds(7 * 86_400))
        return PaceGrade(weekly: window, now: start.addingTimeInterval(days * day))
    }

    @Test func onPaceOrRunningOutUpToTwoDaysEarlyIsGood() {
        #expect(Self.grade(50, after: 3.5) == .good)
        // Dry on day 5, two days before the reset.
        #expect(Self.grade(50, after: 2.5) == .good)
    }

    @Test func runningOutTwoToFourDaysEarlyOrLeavingATenthIsAWarning() {
        // Dry on day 4.5, two and a half days early.
        #expect(Self.grade(50, after: 2.25) == .warning)
        // Dry on day 3.5, three and a half days early.
        #expect(Self.grade(50, after: 1.75) == .warning)
        // Four fifths used by the reset: a fifth unused.
        #expect(Self.grade(40, after: 3.5) == .warning)
    }

    @Test func runningOutMoreThanFourDaysEarlyOrLeavingHalfIsDanger() {
        // Dry on day 2, five days early.
        #expect(Self.grade(50, after: 1) == .danger)
        // A fifth used by the reset: four fifths unused.
        #expect(Self.grade(10, after: 3.5) == .danger)
    }

    @Test func nothingSpentHasNoGrade() {
        #expect(Self.grade(0, after: 3.5) == nil)
    }
}
