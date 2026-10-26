import Foundation

public struct SessionRow: Codable, Equatable, Sendable, Identifiable {
    public var machine: String
    public var sessionId: String
    public var workspace: String
    public var pane: String
    public var tool: String
    public var model: String?
    public var effort: String?
    public var repo: String?
    public var section: String?
    public var seat: String?
    public var branch: String?
    public var startedAt: Date?
    public var closedAt: Date?
    public var status: String
    public var asOf: Date
    public var stale: Bool
    public var tokens: TokenCounts?
    public var models: [String: TokenCounts]
    public var usd: Decimal?
    public var id: String { machine + ":" + sessionId }

    enum CodingKeys: String, CodingKey {
        case machine, sessionId = "session_id", workspace, pane, tool, model, effort, repo, section, seat, branch
        case startedAt = "started_at", closedAt = "closed_at", status, asOf = "as_of", stale, tokens, models, usd
    }

    public init(machine: String = "", sessionId: String, workspace: String, pane: String,
                tool: String, status: String, asOf: Date) {
        self.machine = machine; self.sessionId = sessionId; self.workspace = workspace
        self.pane = pane; self.tool = tool; self.status = status; self.asOf = asOf
        stale = false; models = [:]
        observe(workspace: workspace)
    }

    mutating func observe(workspace: String) {
        self.workspace = workspace
        repo = nil; section = nil; seat = nil
        let parts = workspace.split(separator: "-").map(String.init)
        if parts.count >= 3 {
            repo = parts.dropLast(2).joined(separator: "-")
            section = parts[parts.count - 2]; seat = parts.last
        }
    }
}

public struct SessionLogFile: Codable, Sendable {
    public var version = 1
    public var updated: Date
    public var sessions: [SessionRow]
    public var problems: [String: String] = [:]
    public static var file: URL { AppPaths.support.appendingPathComponent("log.json") }

    public init(updated: Date, sessions: [SessionRow], problems: [String: String] = [:]) {
        self.updated = updated; self.sessions = sessions; self.problems = problems
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// What was seen of a pane cannot be read back from its transcripts once the
/// pane goes, and the token checkpoint can be replaced, so the ledger commits
/// first. The last line for a session is the one that counts, so a pass
/// appends only what changed, and a ledger grown past a few lines per session
/// is rewritten as one line each.
struct SessionLedger {
    let directory: URL
    /// A ledger this big was written before compaction, when every pass
    /// appended every session again. The first compaction keeps it beside the
    /// new one, under a name the probe never reads, for the owner to delete.
    var keepAbove = 64 << 20
    /// How much is read at a time.
    var chunk = 1 << 20
    var file: URL { directory.appendingPathComponent("observations.jsonl") }

    func rows() throws -> [String: SessionObservation] { try read().rows }

    /// Line by line, so a long ledger is never held whole. `lines` counts
    /// every line, blank and skipped ones included, since all of them are
    /// what compaction would save. A last line with no newline is a torn
    /// append and is left out of `rows`; `tail` is that line when it is a
    /// whole observation, which the next append's newline makes readable.
    func read() throws -> (rows: [String: SessionObservation], lines: Int, tail: SessionObservation?) {
        guard FileManager.default.fileExists(atPath: file.path) else { return ([:], 0, nil) }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var rows: [String: SessionObservation] = [:]
        var lines = 0
        var pending = Data()
        let decoder = JSONDecoder()
        // Each chunk's bridged buffers go with it, or a long ledger is held
        // whole after all.
        while try autoreleasepool(invoking: {
            guard let chunk = try handle.read(upToCount: self.chunk), !chunk.isEmpty else { return false }
            pending.append(chunk)
            var start = pending.startIndex
            while let end = pending[start...].firstIndex(of: 0x0A) {
                lines += 1
                if end > start {
                    if let observation = try? decoder.decode(SessionObservation.self, from: pending[start..<end]) {
                        rows[observation.row.sessionId] = observation
                    } else {
                        PollLog.system("log: incomplete pane observation skipped")
                    }
                }
                start = pending.index(after: end)
            }
            pending = Data(pending[start...])
            return true
        }) {}
        return (rows, lines, pending.isEmpty ? nil : try? decoder.decode(SessionObservation.self, from: pending))
    }

    func append(_ observations: [SessionObservation]) throws {
        guard !observations.isEmpty else { return }
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x0A]))
        for observation in observations {
            try handle.write(contentsOf: JSONEncoder().encode(observation) + Data([0x0A]))
        }
        try handle.synchronize()
    }

    /// Rewrites the ledger as `rows`, one line per session, once it holds
    /// more than four lines for each (and more than 256), so it stays a few
    /// times the size of what it records, or at once when `dropping`, for a
    /// session that has left. `rows` must be what a read of the ledger gives
    /// now, less any session that has left.
    func compactIfLong(_ rows: [String: SessionObservation], lines: Int, dropping: Bool = false) throws {
        guard dropping || lines > 4 * max(rows.count, 64) else { return }
        let fresh = directory.appendingPathComponent("observations.jsonl.new")
        try? FileManager.default.removeItem(at: fresh)
        guard FileManager.default.createFile(atPath: fresh.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw ProcessFailure("log: the compacted ledger could not be created")
        }
        let handle = try FileHandle(forWritingTo: fresh)
        do {
            for key in rows.keys.sorted() {
                try handle.write(contentsOf: JSONEncoder().encode(rows[key]) + Data([0x0A]))
            }
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: fresh)
            throw error
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if size > keepAbove {
            // A second name for the same bytes, so nothing is copied and the
            // rename below cannot lose them.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            try FileManager.default.linkItem(
                at: file, to: directory.appendingPathComponent("observations-before-compaction-\(stamp).jsonl"))
        }
        guard rename(fresh.path, file.path) == 0 else {
            try? FileManager.default.removeItem(at: fresh)
            throw ProcessFailure("log: the compacted ledger could not replace the old one")
        }
    }
}

struct SessionObservation: Codable, Equatable {
    var row: SessionRow
    var pid: Int
    var processStart: String
    var paths: [String]

    /// The same in all but when it was last seen, which a pass sets on every
    /// session it reads and the ledger need not record again.
    func matches(_ other: SessionObservation) -> Bool {
        var seen = self
        seen.row.asOf = other.row.asOf
        return seen == other
    }
}

struct SessionCheckpoint: Codable {
    var files: [String: SessionTokens] = [:]
    var owners: [String: String] = [:]
    var messageOwners: [String: String] = [:]
}

public actor SessionLogMonitor {
    let prober: MachineProber
    let file: URL
    let config: @Sendable () async -> Config
    let notify: @Sendable (SessionLogFile) -> Void
    private var rows: [String: [SessionRow]] = [:]

    public init(prober: MachineProber, file: URL = SessionLogFile.file,
                config: @escaping @Sendable () async -> Config,
                notify: @escaping @Sendable (SessionLogFile) -> Void = { _ in }) {
        self.prober = prober; self.file = file; self.config = config; self.notify = notify
        if let data = try? Data(contentsOf: file),
           let saved = try? SessionLogFile.decoder().decode(SessionLogFile.self, from: data) {
            rows = Dictionary(grouping: saved.sessions, by: \.machine)
        }
    }

    public func run() async {
        while !Task.isCancelled {
            await read()
            try? await Task.sleep(for: .seconds(30))
        }
    }

    @discardableResult public func read() async -> SessionLogFile {
        let machines = await config().machines
        let prober = self.prober
        let results = await Machine.each(machines) { await prober.readLog($0) }
        var problems: [String: String] = [:]
        let now = Date()
        for machine in machines {
            switch results[machine.id] {
            case let .success(log):
                // A pass that answered can still say what it could not read,
                // such as a folder macOS held; it shows under the machine.
                let said = log.problems.keys.sorted().compactMap { log.problems[$0] }
                if !said.isEmpty { problems[machine.id] = said.joined(separator: "; ") }
                rows[machine.id] = SessionRetention.kept(log.sessions, row: { $0 }, now: now).map { row in
                    var row = row; row.machine = machine.id
                    row.stale = row.stale || now.timeIntervalSince(row.asOf) > 90
                    return row
                }
            case let .failure(error):
                problems[machine.id] = error.reason
                rows[machine.id] = SessionRetention.kept(rows[machine.id] ?? [], row: { $0 }, now: now)
                    .map { var row = $0; row.stale = true; return row }
            case .none: break
            }
        }
        let log = SessionRetention.bounded(SessionLogFile(updated: now, sessions: machines.flatMap { rows[$0.id] ?? [] }
            .sorted { ($0.startedAt ?? .distantPast, $0.id) > ($1.startedAt ?? .distantPast, $1.id) }, problems: problems))
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SessionLogFile.encoder().encode(log).write(to: file, options: .atomic)
        } catch { PollLog.system("log: snapshot could not be written") }
        notify(log)
        return log
    }
}

/// How long a closed session stays, read from its `closed_at`, so a reader of
/// `log.json` can tell when a row will go. The probe drops a session from its
/// ledger, checkpoint and pass on the same rule that drops it from `log.json`,
/// so nothing is kept or re-read that nobody is shown (issue #70).
public enum SessionRetention {
    /// A working week. At the rate seen on the owner's Mac, about 64 sessions
    /// a day, that is some 450 closed rows per machine.
    public static let closedFor: TimeInterval = 7 * 86_400
    /// A burst of short sessions cannot outgrow the file within the week.
    public static let closedPerMachine = 1_000
    /// The whole file, under the 5,000 rows and 4,000,000 bytes a reader of
    /// `log.json` may cap it at (issue #38), with room to spare.
    public static let fileRows = 4_000
    public static let fileBytes = 3_000_000

    /// Every open session, and the newest `closedPerMachine` that closed
    /// within `closedFor` of `now`. `items` are one machine's.
    static func kept<T>(_ items: [T], row: (T) -> SessionRow, now: Date) -> [T] {
        let recent = items.filter { item in row(item).closedAt.map { now.timeIntervalSince($0) < closedFor } ?? true }
        let closed = recent.compactMap { item in row(item).closedAt.map { ($0, row(item).sessionId) } }
        guard closed.count > closedPerMachine else { return recent }
        let dropped = Set(closed.sorted { $0 > $1 }.dropFirst(closedPerMachine).map(\.1))
        return recent.filter { !dropped.contains(row($0).sessionId) }
    }

    /// `log` with its oldest closed rows dropped until it is within
    /// `fileRows` and `fileBytes`. Open rows are never dropped.
    static func bounded(_ log: SessionLogFile) -> SessionLogFile {
        let encoder = SessionLogFile.encoder()
        var empty = log; empty.sessions = []
        let base = (try? encoder.encode(empty).count) ?? 0
        let sizes = log.sessions.map { (try? encoder.encode($0).count) ?? 0 }
        // Each row after the first adds a comma inside the array.
        var bytes = base + sizes.reduce(0, +) + max(0, sizes.count - 1)
        var count = log.sessions.count
        let oldestFirst = log.sessions.indices.filter { log.sessions[$0].closedAt != nil }
            .sorted { (log.sessions[$0].closedAt!, log.sessions[$0].id) < (log.sessions[$1].closedAt!, log.sessions[$1].id) }
        var dropped = Set<Int>()
        for index in oldestFirst where count > fileRows || bytes > fileBytes {
            dropped.insert(index); count -= 1; bytes -= sizes[index] + 1
        }
        var bounded = log
        bounded.sessions = log.sessions.indices.filter { !dropped.contains($0) }.map { log.sessions[$0] }
        return bounded
    }
}
