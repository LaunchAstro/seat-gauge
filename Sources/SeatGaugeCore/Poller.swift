import Foundation
import os

/// Where a poll is written. The subsystem is the bundle identifier, so
/// `log stream` reads the app and the CLI as one thing. A line's leading word
/// (`poll:`, `config:`, `spend:`) is public; the rest can name seats and their
/// headroom, so the system log keeps it private.
public enum PollLog {
    public static let subsystem = AppPaths.bundleID
    public static let system: @Sendable (String) -> Void = { line in
        let (kind, rest) = parts(line)
        Logger(subsystem: subsystem, category: "poll")
            .notice("\(kind, privacy: .public)\(rest, privacy: .private)")
    }

    /// The words a line may open with in public. Only these: a line that
    /// opened with a seat id would otherwise show it.
    static let kinds: Set<String> = ["poll", "config", "spend", "rates", "notifications"]

    /// The line split after its leading `kind:`. A line that opens any other
    /// way is all private.
    static func parts(_ line: String) -> (kind: String, rest: String) {
        guard let colon = line.firstIndex(of: ":"), kinds.contains(String(line[..<colon]))
        else { return ("", line) }
        let after = line.index(after: colon)
        return (String(line[..<after]), String(line[after...]))
    }
}

/// The power assertion each poll runs inside, so App Nap does not throttle a
/// panel that is never the foreground app. It counts its own
/// begins and ends, which is what a case reads.
public final class PollActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [any NSObjectProtocol] = []
    private var counts = (begins: 0, ends: 0)

    public init() {}
    public var begins: Int { lock.withLock { counts.begins } }
    public var ends: Int { lock.withLock { counts.ends } }

    public func begin() {
        let token = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "seat poll")
        lock.withLock { tokens.append(token); counts.begins += 1 }
    }

    public func end() {
        let token = lock.withLock { counts.ends += 1; return tokens.popLast() }
        if let token { ProcessInfo.processInfo.endActivity(token) }
    }
}

/// Which seats one poll reads. A scheduled poll reads the seats that poll
/// themselves; a sync reads the seats it names, token seats included.
struct PollAsk: Sendable {
    var scheduled = false
    var named: Set<SeatID> = []
    var all = false

    var isEmpty: Bool { !scheduled && !all && named.isEmpty }

    func reads(_ seat: Seat) -> Bool {
        all || named.contains(seat.id) || (scheduled && seat.pollsAutomatically)
    }
}

/// The one loop. The panel drives it and so does `seatgauge-cli watch`: one
/// sleep between polls, one poll at a time, and a "poll now" or a sync that
/// coalesces, so two requests during a poll produce one more poll and not
/// two. Beside it runs a minute tick, which reads the config's mtime once a
/// minute whatever the poll interval is. It has a clock of its own so the
/// interval the panel is held to stays the one the poll loop sleeps.
public actor Poller<C: Clock, T: Clock> where C.Duration == Duration, T.Duration == Duration {
    let watcher: ConfigWatcher
    let service: RefreshService
    let store: GaugeStore
    let clock: C
    let ticks: T
    let activity: PollActivity
    let wakes: AsyncStream<Void>
    /// The spend roll-up, run at launch and every sixth poll after it. It
    /// reads a month of transcripts, so it is handed in rather than reached
    /// for: nothing about a poll waits on it and no case walks a real home.
    let rollup: @Sendable () async -> Void
    /// Which seat the main login is, observed once per poll after the cards
    /// are read. The app hands in its attribution writer's hook; the
    /// CLI's `watch` hands in nothing, so it never writes a second observation.
    let identity: @Sendable ([Seat]) async -> Void
    let log: @Sendable (String) -> Void
    /// Every poll's answer, for whoever draws it. The panel's mirror lives on
    /// the main actor and this target has no AppKit, so the snapshot and the
    /// seats it was read against are handed over rather than reached for.
    let notify: @Sendable (Snapshot, [Seat]) -> Void
    /// The ids a poll is about to read, then `[]` once its answer is in, so a
    /// card can say it is being read.
    let syncing: @Sendable (Set<SeatID>) -> Void
    /// What the next poll reads. The first poll at launch is a scheduled one.
    private var ask = PollAsk(scheduled: true)
    private var polls = 0
    private var sleeper: Task<Bool, Never>?
    /// When the next scheduled poll is due. A sync leaves it where it was, so
    /// reading one seat does not push back the others.
    private var due: C.Instant?

    public init(watcher: ConfigWatcher, service: RefreshService, store: GaugeStore, clock: C,
                ticks: T = ContinuousClock(),
                activity: PollActivity = PollActivity(),
                wakes: AsyncStream<Void> = AsyncStream { $0.finish() },
                rollup: @escaping @Sendable () async -> Void = {},
                identity: @escaping @Sendable ([Seat]) async -> Void = { _ in },
                log: @escaping @Sendable (String) -> Void = PollLog.system,
                notify: @escaping @Sendable (Snapshot, [Seat]) -> Void = { _, _ in },
                syncing: @escaping @Sendable (Set<SeatID>) -> Void = { _ in }) {
        self.watcher = watcher
        self.service = service
        self.store = store
        self.clock = clock
        self.ticks = ticks
        self.activity = activity
        self.wakes = wakes
        self.rollup = rollup
        self.identity = identity
        self.log = log
        self.notify = notify
        self.syncing = syncing
    }

    /// A wake is a poll: the machine has been asleep, so every figure on the
    /// panel is old. The stream is filled from `NSWorkspace.didWakeNotification`
    /// where AppKit already is, since this target is Foundation only.
    public func run() async {
        let waking = Task { [weak self, wakes] in
            for await _ in wakes {
                guard let self else { return }
                await self.pollNow()
            }
        }
        let ticking = Task { [weak self] in await self?.tick() }
        defer { waking.cancel(); ticking.cancel() }
        while !Task.isCancelled {
            let asked = ask
            ask = PollAsk()
            await poll(asked)
            if ask.isEmpty { await rest() }
        }
    }

    /// The minute tick: one `Task.sleep(until:tolerance:clock:)` loop of its
    /// own, a minute at a time, reading nothing but the config's mtime. An edit
    /// is in use inside a minute and a file that will not parse says its line
    /// and column then, rather than waiting out the poll interval. A tick never
    /// polls, so the polls stay at `pollMinutes` and a dropped seat leaves the
    /// next one.
    private func tick() async {
        while !Task.isCancelled {
            let deadline = ticks.now.advanced(by: .seconds(60))
            guard (try? await Task.sleep(until: deadline, tolerance: .seconds(5),
                                         clock: ticks)) != nil else { return }
            let before = await watcher.problem
            let changed = await watcher.refresh()
            let problem = await watcher.problem
            if changed {
                let config = await watcher.config
                log("config: \(config.seats.count) seat(s), every \(config.pollMinutes) min")
            } else if problem != before, let problem {
                log("config: \(problem)")
            }
        }
    }

    /// Asks for a scheduled poll as soon as the one in flight is done. A
    /// second request while the first is unanswered adds nothing.
    public func pollNow() { ask.scheduled = true; sleeper?.cancel() }

    /// Asks for these seats to be read as soon as the loop is free, token
    /// seats included.
    public func sync(_ ids: Set<SeatID>) {
        guard !ids.isEmpty else { return }
        ask.named.formUnion(ids)
        sleeper?.cancel()
    }

    /// Asks for every configured seat to be read, token seats included.
    public func syncAll() { ask.all = true; sleeper?.cancel() }

    /// A scheduled poll: every seat that polls itself.
    @discardableResult
    public func poll() async -> Snapshot { await poll(PollAsk(scheduled: true)) }

    private func poll(_ asked: PollAsk) async -> Snapshot {
        activity.begin()
        defer { activity.end() }
        await watcher.refresh()
        let config = await watcher.config
        let states = await store.snapshot.states
        let seats = config.seats.filter(asked.reads)
        syncing(Set(seats.map(\.id)))
        let fresh = await service.refresh(seats, states: states, now: Date())
        // A seat this poll did not read keeps what it had; one the config no
        // longer lists is dropped.
        let listed = Set(config.seats.map(\.id))
        let kept = states.filter { listed.contains($0.key) }.merging(fresh) { $1 }
        let snapshot = await store.apply(states: kept, order: config.seats.map(\.id),
                                         seats: config.seats, pollMinutes: config.pollMinutes)
        // A config that will not parse is said on every poll, since the seats
        // being read are the last good ones.
        let problem = await watcher.problem.map { "  config: \($0)" } ?? ""
        let unwritten = await store.problem.map { "  readings: \($0)" } ?? ""
        log(Self.line(snapshot) + problem + unwritten)
        notify(snapshot, config.seats)
        syncing([])
        await identity(config.seats)
        guard asked.scheduled else { return snapshot }
        // After the cards, never before them: the roll-up walks a month of
        // transcripts and the panel is what the user is waiting on.
        if SpendSchedule.due(poll: polls) { await rollup() }
        polls += 1
        // The next scheduled poll is an interval after this one, whatever
        // syncs run in between. The interval is read now, so an edit made
        // while this poll ran is in use for the next sleep.
        let minutes = await watcher.config.pollMinutes
        due = clock.now.advanced(by: .seconds(60 * minutes))
        return snapshot
    }

    /// One `Task.sleep(until:tolerance:clock:)` until the next poll is due,
    /// ended early by a wake, by "poll now" or by a sync.
    private func rest() async {
        // Read the interval before the deadline is taken: a "poll now" arriving
        // while this suspension is open is answered now, not an interval later.
        let minutes = await watcher.config.pollMinutes
        guard ask.isEmpty, !Task.isCancelled else { return }
        let deadline = due ?? clock.now.advanced(by: .seconds(60 * minutes))
        let sleeping = Task<Bool, Never> { [clock] in
            (try? await Task.sleep(until: deadline, tolerance: .seconds(20), clock: clock)) != nil
        }
        sleeper = sleeping
        let slept = await withTaskCancellationHandler { await sleeping.value } onCancel: { sleeping.cancel() }
        sleeper = nil
        if slept { ask.scheduled = true }
    }

    static func line(_ snapshot: Snapshot) -> String {
        "poll: " + snapshot.order.map { id in
            switch snapshot.states[id] {
            case let .live(reading): "\(id.rawValue) live \(reading.headroom)% headroom"
            case .dormant: "\(id.rawValue) dormant"
            case .unreadable: "\(id.rawValue) stale"
            case .none: "\(id.rawValue) unread"
            }
        }.joined(separator: ", ")
    }
}
