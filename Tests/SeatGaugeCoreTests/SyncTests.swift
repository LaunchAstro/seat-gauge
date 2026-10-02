import Foundation
import Testing

import SeatGaugeCore

/// A token seat costs a model turn to read, so the scheduled poll skips it and
/// only a sync reads it. An own login is read on the timer for free.
extension ConfigAndPollTests {

    /// A token seat: it names the file its token is read from.
    static let tokenLine = "{ \"id\": \"personal\", \"label\": \"Personal\", \"kind\": \"claude\", \"profile\": \"~/profiles/personal\", \"token\": \"~/personal.token\" }"

    /// What the poller said it was about to read, in order.
    final class Syncing: @unchecked Sendable {
        private let lock = NSLock()
        private var said: [Set<String>] = []
        func add(_ ids: Set<SeatID>) { lock.withLock { said.append(Set(ids.map(\.rawValue))) } }
        var all: [Set<String>] { lock.withLock { said } }
    }

    @Test("Only a Claude seat with a token file waits to be synced")
    func pollsAutomaticallyIsFalseOnlyForATokenSeat() throws {
        let scratch = Scratch()
        scratch.write(Self.config("\(Self.workLine), \(Self.tokenLine), \(Self.codexLine)"), to: scratch.seats)
        let seats = try ConfigLoader(file: scratch.seats).load().seats
        #expect(seats.map(\.pollsAutomatically) == [true, false, true])
    }

    @Test("A scheduled poll skips a token seat, which keeps its last reading on the card and on disk")
    func aScheduledPollKeepsATokenSeatsLastReading() async throws {
        let scratch = Scratch()
        scratch.write(Self.config("\(Self.workLine), \(Self.tokenLine)"), to: scratch.seats)
        let held = Self.reading("personal", used: 30, at: Date(timeIntervalSince1970: 1_790_000_000))
        try JSONEncoder().encode([held]).write(to: scratch.readings)
        let counter = Counter()
        let poller = Poller(
            watcher: try ConfigWatcher(loader: ConfigLoader(file: scratch.seats)),
            service: RefreshService(clock: ContinuousClock(), gap: .zero) { _ in CountingFetcher(counter: counter, gate: nil) },
            store: GaugeStore(file: scratch.readings),
            clock: TestClock(), log: { _ in })

        let snapshot = await poller.poll()
        #expect(counter.seats == ["work"])
        guard case let .unreadable(_, last) = snapshot.states[SeatID(rawValue: "personal")] else {
            Issue.record("the token seat lost its restored reading"); return
        }
        #expect(last == held)
        let written = try JSONDecoder().decode([Reading].self, from: Data(contentsOf: scratch.readings))
        #expect(written.map(\.seat.rawValue) == ["work", "personal"])
        #expect(written.last == held)
    }

    @Test("sync reads the seats it names, syncAll reads every seat, and the timer reads only the free ones")
    func syncReadsTokenSeatsOnRequest() async throws {
        let scratch = Scratch()
        scratch.write(Self.config("\(Self.workLine), \(Self.tokenLine)"), to: scratch.seats)
        let clock = TestClock(parks: true)
        let counter = Counter()
        let syncing = Syncing()
        let poller = Poller(
            watcher: try ConfigWatcher(loader: ConfigLoader(file: scratch.seats)),
            service: RefreshService(clock: ContinuousClock(), gap: .zero) { _ in CountingFetcher(counter: counter, gate: nil) },
            store: GaugeStore(file: scratch.readings),
            clock: clock, log: { _ in }, syncing: { syncing.add($0) })

        let loop = Task { await poller.run() }
        try await Self.waitUntil("the first poll and its sleep") { clock.sleeps.count == 1 }
        #expect(counter.seats == ["work"])

        await poller.sync([SeatID(rawValue: "personal")])
        try await Self.waitUntil("the sync and the sleep after it") { clock.sleeps.count == 2 }
        #expect(counter.seats == ["work", "personal"])
        let synced = await poller.poll()
        #expect(synced.states.count == 2, "the synced reading is kept by the next scheduled poll")

        await poller.syncAll()
        try await Self.waitUntil("the sync of every seat") { clock.sleeps.count == 3 }
        #expect(counter.seats == ["work", "personal", "work", "work", "personal"])

        // The interval running out is a scheduled poll again.
        // Released until the next sleep is asked for, since the sleeper may
        // not have parked yet when the first release comes.
        try await Self.waitUntil("the scheduled poll") {
            if clock.sleeps.count < 4 { clock.release() }
            return clock.sleeps.count >= 4
        }
        #expect(counter.seats.last == "work")
        #expect(counter.seats.count == 6)
        #expect(syncing.all == [["work"], [], ["personal"], [], ["work"], [],
                                ["work", "personal"], [], ["work"], []])

        loop.cancel()
        clock.release()
        _ = await loop.value
    }
}

extension ConfigAndPollTests {
    final class AdvancingClock: Clock, @unchecked Sendable {
        typealias Instant = ContinuousClock.Instant
        private let lock = NSLock()
        private var instant = ContinuousClock().now
        private var recorded: [Duration] = []

        var minimumResolution: Duration { .nanoseconds(1) }
        var now: Instant { lock.withLock { instant } }
        var sleeps: [Duration] { lock.withLock { recorded } }

        func advance(by amount: Duration) {
            lock.withLock { instant = instant.advanced(by: amount) }
        }

        func sleep(until deadline: Instant, tolerance: Duration?) async throws {
            lock.withLock { recorded.append(deadline - instant) }
            try await Task.sleep(for: .seconds(3600))
        }
    }

    @Test("A queued sync does not postpone the scheduled poll")
    func syncKeepsScheduledDeadline() async throws {
        let scratch = Scratch()
        scratch.write(Self.config("\(Self.workLine), \(Self.tokenLine)"), to: scratch.seats)
        let clock = AdvancingClock()
        let counter = Counter()
        let first = Gate()
        let token = Gate()
        await first.close()
        await token.close()

        let poller = Poller(
            watcher: try ConfigWatcher(loader: ConfigLoader(file: scratch.seats)),
            service: RefreshService(clock: ContinuousClock(), gap: .zero) { seat in
                CountingFetcher(counter: counter,
                                gate: seat.id.rawValue == "work" ? first : token)
            },
            store: GaugeStore(file: scratch.readings),
            clock: clock, log: { _ in })

        let loop = Task { await poller.run() }
        try await Self.waitUntil("first poll started") { counter.seats == ["work"] }
        await poller.sync([SeatID(rawValue: "personal")])
        await first.release()
        try await Self.waitUntil("token sync started") {
            counter.seats == ["work", "personal"]
        }

        clock.advance(by: .seconds(120))
        await token.release()
        try await Self.waitUntil("next scheduled sleep") { clock.sleeps.count == 1 }
        #expect(clock.sleeps == [.seconds(180)])

        loop.cancel()
        _ = await loop.value
    }
}

extension ConfigAndPollTests {
    @Test("An interval edit during a poll applies to the next sleep")
    func changedIntervalAppliesAfterPoll() async throws {
        let scratch = Scratch()
        scratch.write(Self.config(Self.workLine, minutes: 5), to: scratch.seats)
        let watcher = try ConfigWatcher(loader: ConfigLoader(file: scratch.seats))
        let clock = AdvancingClock()
        let counter = Counter()
        let gate = Gate()
        await gate.close()

        let poller = Poller(
            watcher: watcher,
            service: RefreshService(clock: ContinuousClock(), gap: .zero) { _ in
                CountingFetcher(counter: counter, gate: gate)
            },
            store: GaugeStore(file: scratch.readings),
            clock: clock, log: { _ in })

        let loop = Task { await poller.run() }
        try await Self.waitUntil("poll started") { counter.started == 1 }
        scratch.write(Self.config(Self.workLine, minutes: 1), to: scratch.seats, age: 5)
        #expect(await watcher.refresh())

        await gate.release()
        try await Self.waitUntil("next sleep") { clock.sleeps.count == 1 }
        #expect(clock.sleeps == [.seconds(60)])

        loop.cancel()
        _ = await loop.value
    }
}
