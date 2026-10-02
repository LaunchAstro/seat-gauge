import Foundation
import Testing

import SeatGaugeCore

/// The minute tick, and the two things the loop must not lose: a config edit,
/// which is read within a minute rather than at the next poll, and a
/// `seats.json` that will not parse at launch, which must not take `watch` down.
@Suite struct PollerTickTests {

    /// A clock that records what it was asked to sleep and parks the sleeper
    /// until the case lets it go, so a case can stand inside an interval. The
    /// poll loop and the minute tick each get one, so releasing a tick does not
    /// also release a poll.
    final class TestClock: Clock, @unchecked Sendable {
        typealias Instant = ContinuousClock.Instant
        private let lock = NSLock()
        private var current = ContinuousClock().now
        private var asked: [Swift.Duration] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var minimumResolution: Swift.Duration { .nanoseconds(1) }
        var now: Instant { lock.withLock { current } }
        var sleeps: [Swift.Duration] { lock.withLock { asked } }

        func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
            lock.withLock { asked.append(deadline - current) }
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiter in lock.withLock { waiters.append(waiter) } }
            } onCancel: { self.release() }
            try Task.checkCancellation()
        }

        /// Wakes every parked sleeper, as the interval running out would.
        func release() {
            let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
                let waiting = waiters; waiters = []; return waiting
            }
            waiting.forEach { $0.resume() }
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var log = (fetches: 0, lines: [String]())
        func begin() { lock.withLock { log.fetches += 1 } }
        func say(_ line: String) { lock.withLock { log.lines.append(line) } }
        var fetches: Int { lock.withLock { log.fetches } }
        var lines: [String] { lock.withLock { log.lines } }
    }

    struct CountingFetcher: SeatFetching {
        let counter: Counter
        func fetch(_ seat: Seat, now: Date, last: Reading?) async -> Fetched {
            counter.begin()
            return Fetched(state: .dormant(reason: "not logged in"), lines: [])
        }
    }

    struct Waited: Error { let what: String }

    static func waitUntil(_ what: String, _ reached: @Sendable () -> Bool) async throws {
        for _ in 0..<2000 {
            if reached() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw Waited(what: what)
    }

    static func scratch() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-tick-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes the file with its mtime moved on, so the watcher sees a change
    /// however fast the case ran.
    static func write(_ text: String, to file: URL, age: TimeInterval) {
        try? Data(text.utf8).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(age)], ofItemAtPath: file.path)
    }

    static let work = "{ \"id\": \"work\", \"label\": \"Work\", \"kind\": \"claude\", \"profile\": \"~/.claude-seat-work\" }"
    static let codex = "{ \"id\": \"codex\", \"label\": \"Codex\", \"kind\": \"codex\" }"
    static func config(_ seats: String) -> String { "{ \"seats\": [\(seats)], \"pollMinutes\": 5 }" }

    @Test("the minute tick reads an edit inside a minute, and never polls")
    func theTickReadsTheConfigWithoutPolling() async throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seats = directory.appendingPathComponent("seats.json")
        Self.write(Self.config("\(Self.work), \(Self.codex)"), to: seats, age: 0)
        let polls = TestClock(), ticker = TestClock()
        let counter = Counter()
        let watcher = try ConfigWatcher(loader: ConfigLoader(file: seats))
        let poller = Poller(
            watcher: watcher,
            service: RefreshService(clock: ContinuousClock(), gap: .zero) { _ in CountingFetcher(counter: counter) },
            store: GaugeStore(file: directory.appendingPathComponent("readings.json")),
            clock: polls, ticks: ticker, log: { counter.say($0) })

        let loop = Task { await poller.run() }
        try await Self.waitUntil("the first poll, its interval and the first tick") {
            counter.fetches == 2 && polls.sleeps.contains(.seconds(300)) && !ticker.sleeps.isEmpty
        }
        #expect(ticker.sleeps.first == .seconds(60))

        // A file that will not parse says its line and column on the tick, four
        // minutes before the next poll would.
        Self.write("{\n  \"seats\": [\n    { \"id\": ,, }\n  ],\n}\n", to: seats, age: 5)
        ticker.release()
        try await Self.waitUntil("the tick to report the malformed file") {
            counter.lines.contains { $0.contains("line") && $0.contains("column") }
        }
        #expect(await watcher.config.seats.count == 2)
        #expect(counter.fetches == 2)
        try await Self.waitUntil("the tick to park again") { ticker.sleeps.count >= 2 }

        // A good edit is in use on the tick after it, still without a poll.
        Self.write(Self.config(Self.work), to: seats, age: 10)
        ticker.release()
        try await Self.waitUntil("the tick to take the new seat list") {
            counter.lines.contains { $0.contains("1 seat(s)") }
        }
        #expect(await watcher.problem == nil)
        #expect(counter.fetches == 2)
        #expect(polls.sleeps == [.seconds(300)])

        loop.cancel(); polls.release(); ticker.release()
        _ = await loop.value

        // The dropped seat is gone from the next poll.
        let snapshot = await poller.poll()
        #expect(snapshot.order.map(\.rawValue) == ["work"])
    }

    @Test("a malformed seats.json at launch is reported and watch keeps polling")
    func failsClosedOnAMalformedFileAtLaunch() async throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let seats = directory.appendingPathComponent("seats.json")
        Self.write("{ \"seats\": [ { \"id\": ,, } ] }\n", to: seats, age: 0)
        let counter = Counter()
        // A machine with two profiles and a signed-in codex.
        let home = directory.appendingPathComponent("home", isDirectory: true)
        for id in ["work", "team"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".seat-gauge/profiles/\(id)"),
                                                    withIntermediateDirectories: true)
        }
        let codex = directory.appendingPathComponent("auth.json")
        try Data("{}".utf8).write(to: codex)
        let loader = ConfigLoader(file: seats, machine: SeatDiscovery(home: home, codexLogin: codex))
        let watcher = try ConfigWatcher(loader: loader)

        let problem = await watcher.problem ?? ""
        #expect(problem.contains("line"))
        #expect(problem.contains("column"))
        // The seats first launch would seed stand in, so there is a seat list to poll.
        #expect(await watcher.config.seats.map(\.id)
                == (try ConfigLoader.decode(Data(loader.seed().utf8)).seats.map(\.id)))

        let clock = TestClock()
        let poller = Poller(
            watcher: watcher,
            service: RefreshService(clock: ContinuousClock(), gap: .zero) { _ in CountingFetcher(counter: counter) },
            store: GaugeStore(file: directory.appendingPathComponent("readings.json")),
            clock: clock, log: { counter.say($0) })
        let snapshot = await poller.poll()
        #expect(snapshot.order.count == 3)
        #expect(counter.lines.first?.contains("config: seats.json") == true)
    }

    @Test("a store that cannot write says so instead of going stale in silence")
    func theStoreReportsAWriteItCouldNotDo() async throws {
        let work = SeatID(rawValue: "work")
        // A path under a file is a folder that cannot be made, which is the
        // unwritable folder of the note, without needing one.
        let store = GaugeStore(file: URL(fileURLWithPath: "/dev/null/seat-gauge/readings.json"))
        #expect(await store.problem == nil)
        _ = await store.apply(states: [work: .dormant(reason: "not logged in")], order: [work])
        let problem = await store.problem ?? ""
        #expect(problem.contains("readings.json"))
    }
}
