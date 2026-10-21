import Foundation
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// The subscription line under a card's windows: the date while it is a
/// week or more away, the days under a week, red from three days out.
@MainActor @Suite struct BillingLineTests {

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        return calendar
    }()

    static func day(_ day: Int, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 9))!
    }

    static func line(_ billing: Billing, on today: Int) -> BillingLine {
        BillingLine(billing, now: day(today), calendar: calendar)
    }

    @Test func aWeekOrMoreOutShowsTheDateQuietly() {
        let line = Self.line(.renews(Self.day(29, month: 7)), on: 21)
        #expect(line.said == ("renews 29 Oct", .muted))
    }

    @Test func underAWeekCountsTheDaysAndTurnsRedAtThree() {
        let ends = Billing.ends(Self.day(29))
        #expect(Self.line(ends, on: 23).said == ("expires in 6 days", .muted))
        #expect(Self.line(ends, on: 25).said == ("expires in 4 days", .muted))
        #expect(Self.line(ends, on: 26).said == ("expires in 3 days", .danger))
        #expect(Self.line(ends, on: 28).said == ("expires tomorrow", .danger))
        #expect(Self.line(ends, on: 29).said == ("expires today", .danger))
        #expect(Self.line(ends, on: 30).said == ("expired 29 Oct", .danger))
    }
}

@MainActor private extension BillingLine {
    var said: (String, LineTone) { (text, tone) }
}
