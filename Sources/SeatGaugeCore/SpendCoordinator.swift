import Foundation

/// One Claude profile directory's transcripts. `seat` is the name the CSV
/// records them under: `default` for `~/.claude`, and the seat's own id for a
/// seat's profile, which is `Seat.historyName`.
public struct SpendProfile: Equatable, Sendable {
    public let seat: String
    public let projects: URL

    public init(seat: String, projects: URL) {
        self.seat = seat
        self.projects = projects
    }

    /// `~/.claude/projects`, for the default login's spend, and the
    /// `projects` folder of each Claude seat's profile, wherever the config
    /// puts it. A directory with no `projects` inside it has nothing to walk.
    public static func from(seats: [Seat],
                            home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [SpendProfile] {
        let main = SpendProfile(seat: SpendAttribution.mainDirectory,
                                projects: home.appendingPathComponent(".claude/projects", isDirectory: true))
        let own: [SpendProfile] = seats.compactMap { seat in
            guard case let .claude(profile) = seat.kind else { return nil }
            return SpendProfile(seat: seat.historyName,
                                projects: profile.appendingPathComponent("projects", isDirectory: true))
        }
        return ([main] + own).filter { profile in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: profile.projects.path, isDirectory: &directory)
                && directory.boolValue
        }
    }
}

extension Seat {
    /// The name the roll-up files this seat's usage under: `codex` for a Codex
    /// seat, and the seat's id for a Claude seat. The default login's spend is
    /// filed as `default` and given to seats through `attribution.json`.
    public var historyName: String {
        switch kind {
        case .codex: CodexRollout.seat
        case .claude: id.rawValue
        }
    }
}

/// What one roll-up did, for the log line and for the CLI.
public struct SpendRun: Sendable {
    public let rows: [SpendRow]
    public let responses: Int
    public let files: Int
    public let skipped: Int
    public let sessionCosts: [String: Double]
    public let took: Duration
}

/// When the roll-up runs: at launch, and every sixth poll after it. At the
/// shipped five minutes that is half an hour, which is far inside the 48 h a
/// cell takes to seal.
public enum SpendSchedule {
    public static let everyNthPoll = 6
    public static func due(poll: Int) -> Bool { poll % everyNthPoll == 0 }
}

/// What one collector found in one run, before it is priced or merged:
/// cells by `(seat, day, hour, model)`, and the counts for the log line.
/// Each collector returns one, and the coordinator adds them up.
public struct SpendCollection: Sendable {
    var cells: [SpendCell: TokenCounts] = [:]
    var responses = 0, files = 0, skipped = 0
    /// Each Claude session's own `cost-state` total. Codex has none.
    var sessionCosts: [String: Double] = [:]

    static func + (a: SpendCollection, b: SpendCollection) -> SpendCollection {
        SpendCollection(cells: a.cells.merging(b.cells, uniquingKeysWith: +),
                        responses: a.responses + b.responses, files: a.files + b.files,
                        skipped: a.skipped + b.skipped,
                        sessionCosts: a.sessionCosts.merging(b.sessionCosts) { _, fresh in fresh })
    }
}

/// The one writer of `spend.csv`. Each run collects the Claude
/// cells and the Codex cells side by side, merges both into one read of the
/// record and writes it once, so neither provider's roll-up can write over the
/// other's. Across processes, the app and `seatgauge-cli`, a run holds an
/// exclusive lock on `spend.csv.lock` from before it reads the record until
/// both the record and `state.json` are written; a run that cannot take the
/// lock in time writes nothing and returns nil. A record on disk that does not
/// read whole is never written over: the run collects nothing, writes nothing
/// and throws `SpendRecordUnreadable`. A record missing after a roll-up is
/// rebuilt from every transcript and rollout still on disk, as a first run
/// would read them, and `state.json` keeps the rebuild until a later run
/// reads the record whole. Once both are written, the run takes the day's
/// `HistoryBackup` of the record beside it.
public actor SpendCoordinator {
    let csv: URL
    let state: URL
    let primer: URL
    let codex: CodexCollector?
    let calendar: Calendar
    let lockTimeout: Duration
    let log: @Sendable (String) -> Void

    public init(csv: URL = SpendCSV.defaultFile, state: URL = StateStore.defaultFile,
                primer: URL = AppPaths.primer, codex: CodexCollector? = CodexCollector(),
                calendar: Calendar = .current, lockTimeout: Duration = .seconds(10),
                log: @escaping @Sendable (String) -> Void = PollLog.system) {
        self.csv = csv
        self.state = state
        self.primer = primer
        self.codex = codex
        self.calendar = calendar
        self.lockTimeout = lockTimeout
        self.log = log
    }

    public func run(profiles: [SpendProfile], rates: RateCard, now: Date) async throws -> SpendRun? {
        try await holdingRecord {
            try await self.locked(profiles: profiles, rates: rates, now: now)
        }
    }

    /// Every Codex rollout still on disk, read from the start of each session
    /// and merged as a roll-up merges: a missing cell is added, an open one is
    /// completed and a sealed one is left as it is, so a second import changes
    /// nothing and no response is counted twice. The roll-ups since Codex
    /// joined passed by the older sessions, which is the history this brings
    /// back. Once `state.json` exists it buckets in the zone recorded there,
    /// and an import that writes records its own, so a record written in
    /// another zone gains no second copy of an hour. Returns what it added:
    /// each new cell whole, and each completed cell's new tokens only. Nil
    /// when the lock was busy.
    public func importCodex(rates: RateCard, now: Date) async throws -> [SpendRow]? {
        guard let codex else { return [] }
        var calendar = calendar
        if FileManager.default.fileExists(atPath: state.path),
           let zone = TimeZone(identifier: StateStore(file: state).load().timeZone) {
            calendar.timeZone = zone
        }
        return try await holdingRecord { [calendar] in
            let existing = SpendCSV.read(self.csv, state: self.state)
            if let reason = existing.reason { throw SpendRecordUnreadable(reason: reason) }
            let collected = codex.collect(rolledUpAt: nil, now: now, calendar: calendar)
            let rows = SpendCSV.merge(existing.rows, with: Self.priced(collected.cells, rates: rates),
                                      now: now, calendar: calendar)
            let held = Dictionary(existing.rows.map { ($0.cell, $0.counts) }) { first, _ in first }
            let changed = rows.filter { held[$0.cell] != $0.counts }
            guard !changed.isEmpty else { return [] }
            try SpendCSV.write(rows, to: self.csv)
            try StateStore(file: self.state).update { $0.timeZone = calendar.timeZone.identifier }
            return changed.map { row in
                guard let before = held[row.cell] else { return row }
                return SpendRow(seat: row.seat, day: row.day, hour: row.hour, model: row.model,
                                counts: row.counts - before, usd: nil, sealed: row.sealed)
            }
        }
    }

    /// `body` with the record's lock held, or nil when another run holds it.
    func holdingRecord<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T? {
        let lock = FileLock.file(for: csv)
        do {
            return try await FileLock.holdingAsync(lock, timeout: lockTimeout, body)
        } catch let busy as FileLock.Busy where busy.lock == lock {
            log("spend: \(busy), so this run writes nothing")
            return nil
        }
    }

    static func priced(_ cells: [SpendCell: TokenCounts], rates: RateCard) -> [SpendRow] {
        cells.map { cell, counts in
            SpendRow(seat: cell.seat, day: cell.day, hour: cell.hour, model: cell.model,
                     counts: counts, usd: rates.usd(model: cell.model, counts: counts), sealed: false)
        }
    }

    /// One run, with the record's lock held throughout.
    func locked(profiles: [SpendProfile], rates: RateCard, now: Date) async throws -> SpendRun {
        let started = ContinuousClock.now
        let existing = SpendCSV.read(csv, state: state)
        // Only a record missing after a roll-up that `state.json` proves is
        // rebuilt. A state that will not decode proves nothing, so the run
        // refuses and leaves it as it was.
        if let reason = existing.reason {
            guard !FileManager.default.fileExists(atPath: csv.path), SpendCSV.rolledUp(state) else {
                throw SpendRecordUnreadable(reason: reason)
            }
        }
        // Missing after a roll-up, the old watermark would pass by every
        // sealed file the lost record held, so the walk starts from none.
        let rebuild = existing.reason != nil
        let store = StateStore(file: state)
        let rolledUpAt = rebuild ? nil : store.load().rolledUpAt
        let claude = ClaudeCollector(primer: primer, calendar: calendar)
        let codex = codex
        let calendar = calendar
        async let fromClaude = claude.collect(profiles, rolledUpAt: rolledUpAt, now: now)
        async let fromCodex = codex?.collect(rolledUpAt: rolledUpAt, now: now, calendar: calendar)
        let collected = try await fromClaude + (fromCodex ?? SpendCollection())

        let fresh = Self.priced(collected.cells, rates: rates)
        let rows = SpendCSV.merge(existing.rows, with: fresh, now: now, calendar: calendar)
        try SpendCSV.write(rows, to: csv)
        try store.update {
            $0.timeZone = calendar.timeZone.identifier
            $0.rolledUpAt = now
            $0.spendRebuiltAt = rebuild ? now : nil
            $0.sessionCosts.merge(collected.sessionCosts) { _, fresh in fresh }
        }
        // A backup that fails costs a day's copy, never the roll-up.
        do {
            try HistoryBackup(support: csv.deletingLastPathComponent(), calendar: calendar).run(now: now)
        } catch {
            log("spend: no backup this run, \(error.localizedDescription)")
        }

        let took = ContinuousClock.now - started
        log("spend: \(collected.responses) response(s) from \(collected.files) file(s) into \(rows.count) row(s)"
            + (collected.skipped > 0 ? ", \(collected.skipped) line(s) skipped" : "")
            + " in \(took.formattedSeconds) s")
        return SpendRun(rows: rows, responses: collected.responses, files: collected.files,
                        skipped: collected.skipped, sessionCosts: collected.sessionCosts, took: took)
    }
}

extension Duration {
    /// One decimal place, for a log line a person reads.
    public var formattedSeconds: String { String(format: "%.1f", seconds) }
}
