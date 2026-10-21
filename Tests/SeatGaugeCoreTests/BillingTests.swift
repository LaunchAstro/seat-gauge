import Foundation
import Testing

import SeatGaugeCore

/// A seat's subscription date: how `seats.json` spells it and which day it
/// lands on.
@Suite struct BillingTests {

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        return calendar
    }()

    static func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    static func decode(_ fields: String) throws -> Billing? {
        let text = #"{ "seats": [{ "id": "codex", "label": "Codex", "kind": "codex"\#(fields) }] }"#
        return try ConfigLoader.decode(Data(text.utf8)).seats.first?.billing
    }

    @Test func aRenewalRollsOnAMonthAtATime() {
        let renews = Billing.renews(Self.day(2026, 7, 29))
        #expect(renews.next(now: Self.day(2026, 10, 21, hour: 15), calendar: Self.calendar) == Self.day(2026, 10, 29))
        #expect(renews.daysLeft(now: Self.day(2026, 10, 21, hour: 15), calendar: Self.calendar) == 8)
        // On the day it is today, and the day after it is next month's.
        #expect(renews.daysLeft(now: Self.day(2026, 10, 29, hour: 23), calendar: Self.calendar) == 0)
        #expect(renews.next(now: Self.day(2026, 10, 30), calendar: Self.calendar) == Self.day(2026, 11, 29))
    }

    @Test func aThirtyFirstComesBackAfterAShortMonth() {
        let renews = Billing.renews(Self.day(2026, 1, 31))
        #expect(renews.next(now: Self.day(2026, 2, 10), calendar: Self.calendar) == Self.day(2026, 2, 28))
        #expect(renews.next(now: Self.day(2026, 3, 1), calendar: Self.calendar) == Self.day(2026, 3, 31))
    }

    @Test func anEndKeepsItsDayAndGoesBelowZeroOnceItPasses() {
        let ends = Billing.ends(Self.day(2026, 10, 29))
        #expect(ends.daysLeft(now: Self.day(2026, 10, 26), calendar: Self.calendar) == 3)
        #expect(ends.daysLeft(now: Self.day(2026, 10, 31), calendar: Self.calendar) == -2)
    }

    @Test func seatsJSONReadsEitherAndRefusesBothOrABadDay() throws {
        #expect(try Self.decode("") == nil)
        #expect(try Self.decode(#", "renews": "2026-10-29""#) != nil)
        guard case .ends = try Self.decode(#", "ends": "2026-10-29""#) else {
            Issue.record("an ends day reads as an end")
            return
        }
        #expect(throws: ConfigProblem.self) { try Self.decode(#", "renews": "2026-10-29", "ends": "2026-10-29""#) }
        #expect(throws: ConfigProblem.self) { try Self.decode(#", "renews": "29 Oct""#) }
        #expect(throws: ConfigProblem.self) { try Self.decode(#", "ends": "2026-02-30""#) }
    }
}
