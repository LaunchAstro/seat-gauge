import Foundation
import Testing

import SeatGaugeCore

/// The config, the watcher, the refresh order, the store and the poller.
/// Every case runs in a temporary directory with a fetcher of its own, so none
/// reads the machine's config and none spawns a CLI.
@Suite struct ConfigAndPollTests {

    // MARK: - A scratch directory, a test clock, a gate and a counting fetcher

    /// A directory of this case's own, removed when the case ends.
    final class Scratch {
        let url: URL
        init() {
            url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("seat-gauge-config-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }

        var seats: URL { url.appendingPathComponent("seats.json") }
        var readings: URL { url.appendingPathComponent("readings.json") }

        /// Writes the file and moves its mtime on, so a watcher reading the
        /// timestamp sees a change however fast the case ran.
        func write(_ text: String, to file: URL, age: TimeInterval = 0) {
            try? text.data(using: .utf8)?.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(age)], ofItemAtPath: file.path)
        }
    }

    /// A clock that records every sleep it is asked for. In its parking mode a
    /// sleeper waits until the case releases it or the task is cancelled,
    /// which is what lets a case stand inside the loop's interval.
    final class TestClock: Clock, @unchecked Sendable {
        typealias Instant = ContinuousClock.Instant

        let parks: Bool
        private let lock = NSLock()
        private var current = ContinuousClock().now
        private var asked: [Swift.Duration] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(parks: Bool = false) { self.parks = parks }

        var minimumResolution: Swift.Duration { .nanoseconds(1) }
        var now: Instant { lock.withLock { current } }
        var sleeps: [Swift.Duration] { lock.withLock { asked } }

        func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
            lock.withLock {
                asked.append(deadline - current)
                if !parks { current = deadline }
            }
            guard parks else {
                await Task.yield()
                try Task.checkCancellation()
                return
            }
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiter in
                    lock.withLock { waiters.append(waiter) }
                }
            } onCancel: { self.release() }
            try Task.checkCancellation()
        }

        /// Wakes every parked sleeper, as the interval running out would.
        func release() {
            let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
                let waiting = waiters
                waiters = []
                return waiting
            }
            waiting.forEach { $0.resume() }
        }
    }

    /// A fetch held open, so a case can stand inside a poll that is still in
    /// flight and ask for another one.
    actor Gate {
        private var open = true
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func close() { open = false }

        func release() {
            open = true
            waiting.forEach { $0.resume() }
            waiting = []
        }

        func pass() async {
            guard !open else { return }
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    /// What the fetchers did: how many started and finished, how many ran at
    /// once, and the seats in the order they were read.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var log = (started: 0, finished: 0, running: 0, peak: 0, seats: [String]())

        func begin(_ seat: String) {
            lock.withLock {
                log.started += 1
                log.running += 1
                log.peak = max(log.peak, log.running)
                log.seats.append(seat)
            }
        }

        func end() { lock.withLock { log.running -= 1; log.finished += 1 } }

        var started: Int { lock.withLock { log.started } }
        var finished: Int { lock.withLock { log.finished } }
        var peak: Int { lock.withLock { log.peak } }
        var seats: [String] { lock.withLock { log.seats } }
    }

    struct CountingFetcher: SeatFetching {
        let counter: Counter
        let gate: Gate?

        func fetch(_ seat: Seat, now: Date, last: Reading?) async -> Fetched {
            counter.begin(seat.id.rawValue)
            await gate?.pass()
            counter.end()
            return Fetched(state: .live(reading(seat.id.rawValue, used: 10, at: now)), lines: [])
        }
    }

    struct Waited: Error { let what: String }

    /// Waits for the loop to reach a state, so no case races it. Two seconds
    /// is far past anything these cases do, and a case that waits it out has
    /// found a defect rather than a slow machine.
    static func waitUntil(_ what: String, _ reached: @Sendable () -> Bool) async throws {
        for _ in 0..<2000 {
            if reached() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw Waited(what: what)
    }

    static func reading(_ seat: String, used: Int, at now: Date) -> Reading {
        Reading(seat: SeatID(rawValue: seat),
                windows: [Window(kind: .fiveHour, usedPercent: used,
                                 resetsAt: now.addingTimeInterval(3600), length: .seconds(18000))],
                takenAt: now, plan: "max")
    }

    static func config(_ seats: String, minutes: Int = 5) -> String {
        "{ \"seats\": [\(seats)], \"pollMinutes\": \(minutes) }"
    }

    static let workLine = "{ \"id\": \"work\", \"label\": \"Work\", \"kind\": \"claude\", \"profile\": \"~/profiles/work\" }"
    static let codexLine = "{ \"id\": \"codex\", \"label\": \"Codex\", \"kind\": \"codex\" }"

    static func profile(_ seat: Seat) -> URL? {
        guard case let .claude(directory) = seat.kind else { return nil }
        return directory
    }

    // MARK: - The config

    @Test("ConfigLoader rejects a bad seat list and expands a profile")
    func rejectsABadSeatList() throws {
        let scratch = Scratch()
        let loader = ConfigLoader(file: scratch.seats)
        let twice = "\(Self.workLine), { \"id\": \"work\", \"label\": \"Again\", \"kind\": \"claude\", \"profile\": \"~/profiles/two\" }"
        let shouted = "{ \"id\": \"Work\", \"label\": \"Work\", \"kind\": \"claude\" }"
        let unknown = "{ \"id\": \"gemini\", \"label\": \"Gemini\", \"kind\": \"gemini\" }"
        let twoDefaults = "\(Self.workLine), { \"id\": \"second\", \"label\": \"Second\", \"kind\": \"claude\" }"

        for (name, seats) in [("a duplicate id", twice), ("a shouted id", shouted),
                              ("an unknown kind", unknown), ("a second default", twoDefaults)] {
            scratch.write(Self.config(seats), to: scratch.seats)
            #expect(throws: ConfigProblem.self, "\(name) is not a seat list") { try loader.load() }
        }

        let tilde = "{ \"id\": \"personal\", \"label\": \"Personal\", \"kind\": \"claude\", \"profile\": \"~/profiles/personal\" }"
        let codexWithProfile = "{ \"id\": \"codex\", \"label\": \"Codex\", \"kind\": \"codex\", \"profile\": \"~/.codex-seat\" }"
        scratch.write(Self.config("\(tilde), \(codexWithProfile)"), to: scratch.seats)
        let config = try loader.load()
        let expanded = Self.profile(config.seats[0])
        #expect(expanded?.path == NSHomeDirectory() + "/profiles/personal")
        #expect(expanded?.path.contains("~") == false)
        #expect(config.seats[1].kind == .codex)
    }

    // MARK: - The watcher

    @Test("ConfigWatcher re-reads on an mtime change, in file order")
    func reReadsWhenTheFileChanges() async throws {
        let scratch = Scratch()
        scratch.write(Self.config("\(Self.workLine), \(Self.codexLine)"), to: scratch.seats)
        let watcher = try ConfigWatcher(loader: ConfigLoader(file: scratch.seats))
        #expect(await watcher.config.seats.map(\.id.rawValue) == ["work", "codex"])

        // A tick with nothing changed reads nothing.
        #expect(await watcher.refresh() == false)

        scratch.write(Self.config("\(Self.codexLine), \(Self.workLine)", minutes: 9),
                      to: scratch.seats, age: 5)
        #expect(await watcher.refresh() == true)
        #expect(await watcher.config.seats.map(\.id.rawValue) == ["codex", "work"])
        #expect(await watcher.config.pollMinutes == 9)
        #expect(await watcher.problem == nil)
    }

    // MARK: - Refresh order

    @Test("RefreshService reads seats one at a time, 1 s apart, live first")
    func readsSeatsOneAtATime() async throws {
        let clock = TestClock()
        let counter = Counter()
        let service = RefreshService(clock: clock) { _ in CountingFetcher(counter: counter, gate: nil) }
        let seats = ["sleeper", "unknown", "current", "stale"].map {
            Seat(id: SeatID(rawValue: $0), label: $0, kind: .codex)
        }
        let now = Date()
        let states: [SeatID: SeatState] = [
            seats[0].id: .dormant(reason: "not logged in"),
            seats[2].id: .live(Self.reading("current", used: 4, at: now)),
            seats[3].id: .unreadable(reason: "timed out", last: Self.reading("stale", used: 7, at: now)),
        ]

        #expect(RefreshService.order(seats, states: states).map(\.id.rawValue)
                == ["current", "stale", "unknown", "sleeper"])

        let fresh = await service.refresh(seats, states: states, now: now)
        #expect(counter.seats == ["current", "stale", "unknown", "sleeper"])
        #expect(counter.peak == 1)
        #expect(counter.finished == 4)
        #expect(clock.sleeps == [.seconds(1), .seconds(1), .seconds(1)])
        #expect(fresh.count == 4)
    }

    // MARK: - The readings file

    @Test("GaugeStore writes readings.json every poll and loads it at launch")
    func keepsTheLastSnapshotOnDisk() async throws {
        let scratch = Scratch()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let work = SeatID(rawValue: "work")
        let personal = SeatID(rawValue: "personal")
        let store = GaugeStore(file: scratch.readings, order: [work, personal])
        #expect(await store.snapshot.visible.isEmpty)

        let reading = Self.reading("work", used: 42, at: now)
        _ = await store.apply(states: [work: .live(reading), personal: .dormant(reason: "not logged in")],
                              order: [work, personal])
        #expect(FileManager.default.fileExists(atPath: scratch.readings.path))

        // A cold start: a second store over the same file, nothing fetched yet.
        let restarted = GaugeStore(file: scratch.readings, order: [work, personal])
        let cold = await restarted.snapshot
        #expect(cold.visible == [work])
        guard case let .unreadable(_, last) = cold.states[work] else {
            Issue.record("a restored reading is drawn dimmed, not live")
            return
        }
        #expect(last?.windows.first?.usedPercent == 42)
        #expect(last?.takenAt == now)
        // A dormant seat is not a reading, so it is not carried across a launch.
        #expect(cold.states[personal] == nil)
    }

    // MARK: - The poller

    @Test("Poller sleeps one interval, asserts activity, wakes and coalesces")
    func runsOneCoalescedLoop() async throws {
        let scratch = Scratch()
        scratch.write(Self.config(Self.workLine), to: scratch.seats)
        let clock = TestClock(parks: true)
        let counter = Counter()
        let gate = Gate()
        let activity = PollActivity()
        let (wakes, wake) = AsyncStream<Void>.makeStream()
        let poller = Poller(
            watcher: try ConfigWatcher(loader: ConfigLoader(file: scratch.seats)),
            service: RefreshService(clock: clock) { _ in CountingFetcher(counter: counter, gate: gate) },
            store: GaugeStore(file: scratch.readings),
            clock: clock, activity: activity, wakes: wakes, log: { _ in })

        let loop = Task { await poller.run() }
        try await Self.waitUntil("the first poll and its sleep") {
            counter.finished == 1 && clock.sleeps.count == 1
        }
        #expect(clock.sleeps == [.seconds(300)])

        // A wake while the loop is parked polls at once, and that poll is held
        // open so two requests can arrive inside it.
        await gate.close()
        wake.yield(())
        try await Self.waitUntil("the wake poll to start") { counter.started == 2 }
        await poller.pollNow()
        await poller.pollNow()
        await gate.release()

        try await Self.waitUntil("the coalesced poll and its sleep") { clock.sleeps.count == 2 }
        #expect(counter.finished == 3)
        #expect(activity.begins == 3)
        #expect(activity.ends == 3)

        loop.cancel()
        clock.release()
        _ = await loop.value
    }

    // MARK: - Logging

    @Test("watch logs one line per poll under the app's subsystem")
    func logsEveryPoll() async throws {
        let scratch = Scratch()
        scratch.write(Self.config("\(Self.workLine), \(Self.codexLine)"), to: scratch.seats)
        let clock = TestClock()
        let counter = Counter()
        let lines = Counted()
        let poller = Poller(
            watcher: try ConfigWatcher(loader: ConfigLoader(file: scratch.seats)),
            service: RefreshService(clock: clock) { _ in CountingFetcher(counter: counter, gate: nil) },
            store: GaugeStore(file: scratch.readings),
            clock: clock, log: { lines.add($0) })

        #expect(PollLog.subsystem == AppPaths.bundleID)
        _ = await poller.poll()
        _ = await poller.poll()
        #expect(lines.all.count == 2)
        #expect(lines.all.allSatisfy { $0.contains("work") && $0.contains("codex") })
    }

    final class Counted: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }

    // MARK: - A removed seat

    @Test("a seat removed from seats.json is gone from the next poll")
    func dropsASeatOnTheNextPoll() async throws {
        let scratch = Scratch()
        scratch.write(Self.config("\(Self.workLine), \(Self.codexLine)"), to: scratch.seats)
        let clock = TestClock()
        let counter = Counter()
        let watcher = try ConfigWatcher(loader: ConfigLoader(file: scratch.seats))
        let poller = Poller(
            watcher: watcher,
            service: RefreshService(clock: clock) { _ in CountingFetcher(counter: counter, gate: nil) },
            store: GaugeStore(file: scratch.readings),
            clock: clock, log: { _ in })

        let first = await poller.poll()
        #expect(first.order.map(\.rawValue) == ["work", "codex"])

        scratch.write(Self.config(Self.workLine), to: scratch.seats, age: 5)
        let next = await poller.poll()
        #expect(next.order.map(\.rawValue) == ["work"])
        #expect(next.states[SeatID(rawValue: "codex")] == nil)
        #expect(counter.seats == ["work", "codex", "work"])

        // The poll writes readings.json and headroom.json and nothing else, so
        // a dropped seat's spend history is not something this phase can have
        // touched.
        let written = try FileManager.default.contentsOfDirectory(atPath: scratch.url.path).sorted()
        #expect(written == ["headroom.json", "readings.json", "seats.json"])
    }

    @Test("headroom dates each seat's own read")
    func headroomDatesEachSeat() async throws {
        let scratch = Scratch()
        scratch.write(Self.config("\(Self.workLine), \(Self.codexLine)"), to: scratch.seats)
        let counter = Counter()
        let poller = Poller(
            watcher: try ConfigWatcher(loader: ConfigLoader(file: scratch.seats)),
            service: RefreshService(clock: ContinuousClock(), gap: .seconds(2)) { _ in
                CountingFetcher(counter: counter, gate: nil)
            },
            store: GaugeStore(file: scratch.readings),
            clock: TestClock(),
            log: { _ in })

        _ = await poller.poll()
        let data = try Data(contentsOf: scratch.url.appendingPathComponent("headroom.json"))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let rows = object["seats"] as! [[String: Any]]
        let dates = ISO8601DateFormatter()
        let first = try #require(dates.date(from: rows[0]["read_at"] as! String))
        let second = try #require(dates.date(from: rows[1]["read_at"] as! String))

        #expect(counter.seats == ["work", "codex"])
        #expect(second > first)
    }

    // MARK: - Fails closed

    @Test("Fails closed: a malformed config is reported and the last good one stays")
    func failsClosedOnAMalformedConfig() async throws {
        let scratch = Scratch()
        scratch.write(Self.config("\(Self.workLine), \(Self.codexLine)"), to: scratch.seats)
        let clock = TestClock()
        let counter = Counter()
        let watcher = try ConfigWatcher(loader: ConfigLoader(file: scratch.seats))
        let poller = Poller(
            watcher: watcher,
            service: RefreshService(clock: clock) { _ in CountingFetcher(counter: counter, gate: nil) },
            store: GaugeStore(file: scratch.readings),
            clock: clock, log: { _ in })

        scratch.write("{\n  \"seats\": [\n    { \"id\": ,, }\n  ],\n}\n", to: scratch.seats, age: 5)
        #expect(await watcher.refresh() == false)
        let problem = await watcher.problem ?? ""
        #expect(problem.contains("line"))
        #expect(problem.contains("column"))
        #expect(await watcher.config.seats.map(\.id.rawValue) == ["work", "codex"])

        let snapshot = await poller.poll()
        #expect(snapshot.order.map(\.rawValue) == ["work", "codex"])
        #expect(counter.finished == 2)
    }
}
