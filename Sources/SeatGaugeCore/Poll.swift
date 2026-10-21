import Foundation

/// The seat loop, started the same way by every front end: from the config
/// file and a few options. It holds what each front end used to wire by hand:
/// the config watcher, the readings store, the refresh order, the primer the
/// Claude reads run in, the login shell's `PATH` for finding the CLIs, the
/// spend roll-up on its schedule, and a poll after each wake.
public final class Poll<C: Clock>: Sendable where C.Duration == Duration {
    public struct Options: Sendable {
        /// Observe which seat the main login is, once per poll. Only the app
        /// does: a second observer would write a second observation.
        public var identity: Bool
        /// One element per wake of the machine. Each is a timer poll, after
        /// `wakeDelay`, so it reads the free seats only and never runs a
        /// token seat's paid turn.
        public var wakes: AsyncStream<Void>
        /// Long enough for the network to come back after a wake.
        public var wakeDelay: Duration
        public var log: @Sendable (String) -> Void
        /// Every poll's answer, with the watcher it was read through, for
        /// whoever draws it.
        public var notify: @Sendable (Snapshot, [Seat], ConfigWatcher) -> Void
        /// The ids a poll is about to read, then `[]`.
        public var syncing: @Sendable (Set<SeatID>) -> Void
        /// Runs after each spend roll-up, for a front end that reads the record.
        public var rolledUp: @Sendable () async -> Void
        /// Each seat's fetcher. Nil is the seat's CLI, found wherever the
        /// user's login shell would find it, run in the primer `Poll` makes.
        public var fetcher: (@Sendable (Seat) -> any SeatFetching)?

        public init(identity: Bool = false,
                    wakes: AsyncStream<Void> = AsyncStream { $0.finish() },
                    wakeDelay: Duration = .seconds(5),
                    log: @escaping @Sendable (String) -> Void = PollLog.system,
                    notify: @escaping @Sendable (Snapshot, [Seat], ConfigWatcher) -> Void = { _, _, _ in },
                    syncing: @escaping @Sendable (Set<SeatID>) -> Void = { _ in },
                    rolledUp: @escaping @Sendable () async -> Void = {},
                    fetcher: (@Sendable (Seat) -> any SeatFetching)? = nil) {
            self.identity = identity
            self.wakes = wakes
            self.wakeDelay = wakeDelay
            self.log = log
            self.notify = notify
            self.syncing = syncing
            self.rolledUp = rolledUp
            self.fetcher = fetcher
        }
    }

    public let watcher: ConfigWatcher
    public let store: GaugeStore
    public let poller: Poller<C, ContinuousClock>

    /// Throws when the config file cannot be watched at all. A primer that
    /// cannot be made is logged, since every Claude read then says why.
    /// `clock` is the one the loop sleeps its interval and a wake's delay on.
    public init(file: URL = ConfigLoader.defaultFile, readings: URL = GaugeStore.defaultFile,
                primer: URL = AppPaths.primer, options: Options = Options(), clock: C) throws {
        let watcher = try ConfigWatcher(loader: ConfigLoader(file: file))
        // The Claude fetcher runs in this folder and does not make it, so a
        // fresh install with none fails every Claude read.
        do { try AppPaths.makePrimer(primer) } catch {
            options.log("poll: the primer folder could not be made: \(error.localizedDescription)")
        }
        let spend = SpendCoordinator(primer: primer, log: options.log)
        let store = GaugeStore(file: readings)
        var identity: @Sendable ([Seat]) async -> Void = { _ in }
        if options.identity { identity = IdentityObserver.hook(writer: AttributionWriter()) }
        self.watcher = watcher
        self.store = store
        let fetcher = options.fetcher ?? { seat in
            seatFetcher(for: seat, runner: RealProcessRunner(searchPath: .loginShell), primer: primer)
        }
        poller = Poller(watcher: watcher, service: RefreshService(clock: clock, fetcher: fetcher),
                        store: store, clock: clock,
                        wakes: Wake.after(options.wakes, delay: options.wakeDelay, clock: clock),
                        rollup: {
                            // At launch and every sixth poll, after the cards are up.
                            let seats = await watcher.config.seats
                            _ = try? await spend.run(profiles: SpendProfile.from(seats: seats),
                                                     rates: RateCard.load(), now: Date())
                            await options.rolledUp()
                        },
                        identity: identity,
                        log: options.log,
                        notify: { snapshot, seats in options.notify(snapshot, seats, watcher) },
                        syncing: options.syncing)
    }

    /// The loop, until its task is cancelled.
    public func run() async { await poller.run() }

}

extension Poll where C == ContinuousClock {
    public convenience init(file: URL = ConfigLoader.defaultFile, readings: URL = GaugeStore.defaultFile,
                            primer: URL = AppPaths.primer, options: Options = Options()) throws {
        try self.init(file: file, readings: readings, primer: primer, options: options, clock: ContinuousClock())
    }
}

public enum Wake {
    /// Each wake passed on after `delay` on `clock`.
    public static func after<C: Clock>(_ wakes: AsyncStream<Void>, delay: Duration,
                                       clock: C) -> AsyncStream<Void> where C.Duration == Duration {
        AsyncStream { continuation in
            let forwarding = Task {
                for await _ in wakes {
                    if delay > .zero { try? await clock.sleep(for: delay) }
                    guard !Task.isCancelled else { break }
                    continuation.yield(())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in forwarding.cancel() }
        }
    }
}
