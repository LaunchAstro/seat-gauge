import Foundation

/// One round of reading every seat, one after another and never at once, so a
/// slow seat delays the others rather than four CLIs starting together. A 1 s
/// gap separates the spawns.
public struct RefreshService: Sendable {
    let clock: any Clock<Duration>
    let gap: Duration
    let fetcher: @Sendable (Seat) -> any SeatFetching

    public init(clock: any Clock<Duration> = ContinuousClock(), gap: Duration = .seconds(1),
                fetcher: @escaping @Sendable (Seat) -> any SeatFetching = { seat in seatFetcher(for: seat) }) {
        self.clock = clock
        self.gap = gap
        self.fetcher = fetcher
    }

    /// Last seen live first, unknown next, dormant last, so a cold start has
    /// the cards that will draw inside the 10 s budget.
    public static func order(_ seats: [Seat], states: [SeatID: SeatState]) -> [Seat] {
        seats.enumerated()
            .sorted { one, two in
                let first = rank(states[one.element.id]), second = rank(states[two.element.id])
                return first == second ? one.offset < two.offset : first < second
            }
            .map(\.element)
    }

    /// A seat with a last reading was last seen live, whatever went wrong
    /// since, so it is read before the ones nothing is known about.
    static func rank(_ state: SeatState?) -> Int {
        if case .dormant = state { return 2 }
        return last(state) == nil ? 1 : 0
    }

    static func last(_ state: SeatState?) -> Reading? {
        if case let .live(reading) = state { return reading }
        if case let .unreadable(_, last) = state { return last }
        return nil
    }

    /// Reads the seats given and keys the answer by them and nothing else.
    /// `now` is when the round starts; each seat is dated `now` plus the real
    /// time the round has taken, so a seat read after a slow one says when it
    /// was read.
    public func refresh(_ seats: [Seat], states: [SeatID: SeatState], now: Date) async -> [SeatID: SeatState] {
        var fresh: [SeatID: SeatState] = [:]
        let start = ContinuousClock.now
        for (index, seat) in Self.order(seats, states: states).enumerated() {
            if index > 0 {
                try? await clock.sleep(for: gap, tolerance: .zero)
            }
            let at = now.addingTimeInterval(start.duration(to: .now).seconds)
            fresh[seat.id] = await fetcher(seat)
                .fetch(seat, now: at, last: Self.last(states[seat.id])).state
        }
        return fresh
    }
}
