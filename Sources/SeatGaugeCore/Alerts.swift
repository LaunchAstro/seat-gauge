import Foundation

/// The two things the gauge ever says out loud, in the order they become
/// urgent. One alert only, and never a second kind.
public enum AlertStage: Int, CaseIterable, Sendable, Codable, Comparable {
    case twoDays = 1, oneDay = 2

    public static func < (a: AlertStage, b: AlertStage) -> Bool { a.rawValue < b.rawValue }
}

/// A seat and the week it is in. The reset instant is the week's name, so a
/// new week is a new key and nothing has to be swept when one turns over.
public struct AlertKey: Hashable, Sendable, Codable {
    public let seat: SeatID
    public let resetsAt: Date

    public init(seat: SeatID, resetsAt: Date) {
        self.seat = seat
        self.resetsAt = resetsAt
    }
}

/// What has already been said. It is written as a list rather than as a map,
/// because a JSON object cannot be keyed on a seat and a date, and a list is
/// what a person reading `state.json` can follow.
public struct AlertLedger: Equatable, Sendable, Codable {
    public var fired: [AlertKey: Set<AlertStage>]

    public init(fired: [AlertKey: Set<AlertStage>] = [:]) { self.fired = fired }

    public func has(_ stage: AlertStage, for key: AlertKey) -> Bool {
        fired[key]?.contains(stage) ?? false
    }

    /// The stage that fired, and every stage below it: once the one-day alert
    /// has been posted, the two-day one has nothing left to add.
    public mutating func mark(_ stage: AlertStage, for key: AlertKey) {
        var stages = fired[key] ?? []
        for one in AlertStage.allCases where one <= stage { stages.insert(one) }
        fired[key] = stages
    }

    private struct Entry: Codable {
        let seat: String
        let resetsAt: Date
        let stages: [Int]
    }

    public init(from decoder: any Decoder) throws {
        let entries = try [Entry](from: decoder)
        fired = entries.reduce(into: [:]) { out, entry in
            out[AlertKey(seat: SeatID(rawValue: entry.seat), resetsAt: entry.resetsAt)] =
                Set(entry.stages.compactMap(AlertStage.init(rawValue:)))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        try fired
            .map { Entry(seat: $0.key.seat.rawValue, resetsAt: $0.key.resetsAt,
                         stages: $0.value.map(\.rawValue).sorted()) }
            .sorted { ($0.seat, $0.resetsAt) < ($1.seat, $1.resetsAt) }
            .encode(to: encoder)
    }
}

/// When a week is running out with usage left in it. Both stages ask the same
/// question: is there enough left to be worth moving work onto this seat, and
/// enough time to move it.
public enum AlertPolicy {
    /// The stage a seat's weekly window is due, or nil. The most urgent due
    /// stage wins, so a window inside both thresholds says the sharper thing.
    public static func due(reading: Reading, now: Date,
                           ledger: AlertLedger) -> (stage: AlertStage, window: Window)? {
        guard let weekly = reading.windows.first(where: { $0.kind == .weekly }) else { return nil }
        let left = weekly.resetsAt.timeIntervalSince(now)
        guard left > 0 else { return nil }
        var stage: AlertStage?
        if left <= 48 * 3600, weekly.headroom >= 50 { stage = .twoDays }
        if left <= 24 * 3600, weekly.headroom >= 30 { stage = .oneDay }
        guard let stage,
              !ledger.has(stage, for: AlertKey(seat: reading.seat, resetsAt: weekly.resetsAt))
        else { return nil }
        return (stage, weekly)
    }

    /// The first seat with something due, among live seats only: a stale card
    /// is numbers from before whatever went wrong, and is never alerted on.
    public static func due(in snapshot: Snapshot, now: Date,
                           ledger: AlertLedger) -> (seat: SeatID, stage: AlertStage, window: Window)? {
        for id in snapshot.order {
            guard case let .live(reading) = snapshot.states[id],
                  let due = due(reading: reading, now: now, ledger: ledger) else { continue }
            return (id, due.stage, due.window)
        }
        return nil
    }

    /// "Work: 54% of the week unused, resets Sat 8pm".
    public static func text(label: String, window: Window, now: Date) -> String {
        "\(label): \(window.headroom)% of the week unused, resets \(when(window.resetsAt))"
    }

    /// A day and a twelve-hour time, with the minutes left off when there are
    /// none. Seconds are never shown anywhere.
    static func when(_ date: Date) -> String {
        let shape = DateFormatter()
        shape.locale = Locale(identifier: "en_AU")
        shape.amSymbol = "am"
        shape.pmSymbol = "pm"
        shape.dateFormat = Calendar.current.component(.minute, from: date) == 0
            ? "EEE ha" : "EEE h:mma"
        return shape.string(from: date)
    }
}
