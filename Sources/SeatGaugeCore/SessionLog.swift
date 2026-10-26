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
    /// How much is read at a time.
    var chunk = 1 << 20
    var file: URL { directory.appendingPathComponent("observations.jsonl") }

    func rows() throws -> [String: SessionObservation] { try read().rows }

    /// Line by line, so a long ledger is never held whole. `lines` counts
    /// every line, blank and skipped ones included, since all of them are
    /// what compaction would save. A last line with no newline is a torn
    /// append and is left out of `rows`; `tail` is that line when it is a
    /// whole observation, which the next append's newline makes readable.
    typealias Stored = (rows: [String: SessionObservation], lines: Int, tail: SessionObservation?)

    func read() throws -> Stored {
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

/// Each transcript's read so far, and which session owns it. A Claude message
/// two files share counts in one of them, the one that read it first, and
/// passes to another that holds it once that one no longer does: a file that
/// passed a message by names the file counting it, and is read again from its
/// start when that file stops counting anything.
struct SessionCheckpoint {
    var files: [String: SessionTokens] = [:]
    var owners: [String: String] = [:]
    /// Which file counts each message, built from `files` when first asked.
    private var counter: [UInt64: String]?
    /// Files set to read again from their start since they were last read.
    private(set) var rescanned: Set<String> = []

    init() {}

    /// Forgets the files of sessions that have left, unless a session still
    /// here holds the same file.
    mutating func release(_ leaving: some Sequence<SessionObservation>, keeping: some Sequence<SessionObservation>) {
        let left = Set(leaving.flatMap(\.paths)).subtracting(keeping.flatMap(\.paths))
        guard !left.isEmpty else { return }
        for path in left { files[path] = nil; owners[path] = nil }
        counter = nil
        rescan(deferringTo: left)
    }

    /// Reads `path` on from where it stopped. False when the read failed,
    /// with what it read before the failure kept.
    mutating func read(_ path: String, tool: String, budget: Int) -> Bool {
        var counter = counter ?? Self.counter(files)
        var tokens = files[path] ?? SessionTokens()
        let before = tokens.counted
        rescanned.remove(path)
        var read = true
        do {
            try tokens.read(URL(fileURLWithPath: path), tool: tool, budget: budget) { digest in
                counter[digest].flatMap { $0 == path ? nil : $0 }
            }
        } catch { read = false; tokens.complete = false }
        let lost = before.values.subtracting(tokens.counted.values)
        for digest in lost where counter[digest] == path { counter[digest] = nil }
        for digest in tokens.counted.values.subtracting(before.values) { counter[digest] = path }
        files[path] = tokens
        self.counter = counter
        if !lost.isEmpty { rescan(deferringTo: [path]) }
        return read
    }

    /// Each file that passed a message by for one of `paths` reads again from
    /// its start, keeping what it counts, so it takes over what they dropped.
    private mutating func rescan(deferringTo paths: Set<String>) {
        for (path, tokens) in files where !tokens.deferredTo.isDisjoint(with: paths) {
            var tokens = tokens
            tokens.rescan = true; tokens.deferredTo = []; tokens.complete = false
            files[path] = tokens
            rescanned.insert(path)
        }
    }

    static func counter(_ files: [String: SessionTokens]) -> [UInt64: String] {
        var counter: [UInt64: String] = [:]
        for path in files.keys.sorted() {
            for digest in files[path]!.counted.values where counter[digest] == nil { counter[digest] = path }
        }
        return counter
    }
}

extension SessionCheckpoint: Codable {
    enum CodingKeys: String, CodingKey { case files, owners, messageOwners }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        files = try values.decodeIfPresent([String: SessionTokens].self, forKey: .files) ?? [:]
        owners = try values.decodeIfPresent([String: String].self, forKey: .owners) ?? [:]
        let messageOwners = try values.decodeIfPresent([String: String].self, forKey: .messageOwners) ?? [:]
        if files.values.contains(where: { $0.legacy != nil }) { migrate(messageOwners) }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(files, forKey: .files)
        try values.encode(owners, forKey: .owners)
    }

    /// A checkpoint from before issue #120 kept each file's responses and,
    /// apart, which file counted each message. Each file keeps the digests
    /// of the messages it counted and names the files it passed the rest by,
    /// with the totals the old checkpoint gave and nothing read again. A
    /// message no file still holding it counted goes to the first such file
    /// by path, as the old summing would have given it.
    mutating func migrate(_ messageOwners: [String: String]) {
        let held = files.mapValues { Set(($0.legacy ?? []).map(\.messageID)) }
        var claimed: [String: String] = [:]
        for path in files.keys.sorted() {
            guard var tokens = files[path], let responses = tokens.legacy else { continue }
            tokens.legacy = nil
            tokens.models = [:]
            for response in responses {
                let owner = messageOwners[response.messageID].flatMap { held[$0]?.contains(response.messageID) == true ? $0 : nil }
                    ?? claimed[response.messageID] ?? path
                let digest = MessageDigests.digest(response.messageID)
                if owner == path {
                    claimed[response.messageID] = path
                    guard tokens.counted.insert(digest) else { continue }
                    tokens.models[response.filedModel, default: TokenCounts()] += response.counts
                } else {
                    tokens.deferredTo.insert(owner)
                }
            }
            files[path] = tokens
        }
    }
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
        let results = await Machine.each(machines) {
            await prober.readLog($0, budget: .share(machines: machines.count, id: $0.id))
        }
        var problems: [String: String] = [:]
        let now = Date()
        for machine in machines {
            let budget = SessionRetention.Budget.share(machines: machines.count, id: machine.id)
            switch results[machine.id] {
            case let .success(log):
                // A pass that answered can still say what it could not read,
                // such as a folder macOS held; it shows under the machine.
                let said = log.problems.keys.sorted().compactMap { log.problems[$0] }
                if !said.isEmpty { problems[machine.id] = said.joined(separator: "; ") }
                // An older probe keeps more than this machine's share, so
                // the rule is applied here too.
                rows[machine.id] = SessionRetention.kept(log.sessions, row: { $0 }, now: now, budget: budget).map { row in
                    var row = row; row.machine = machine.id
                    row.stale = row.stale || now.timeIntervalSince(row.asOf) > 90
                    return row
                }
            case let .failure(error):
                problems[machine.id] = error.reason
                rows[machine.id] = SessionRetention.kept(rows[machine.id] ?? [], row: { $0 }, now: now, budget: budget)
                    .map { var row = $0; row.stale = true; return row }
            case .none: break
            }
        }
        let log = SessionLogFile(updated: now, sessions: machines.flatMap { rows[$0.id] ?? [] }
            .sorted { ($0.startedAt ?? .distantPast, $0.id) > ($1.startedAt ?? .distantPast, $1.id) },
            problems: SessionRetention.bounded(problems))
        do {
            try PrivateFile.write(SessionLogFile.encoder().encode(log), to: file, makingFolder: true)
        } catch { PollLog.system("log: snapshot could not be written") }
        notify(log)
        return log
    }
}

/// How long a closed session stays, read from its `closed_at`, and how many
/// a machine keeps, so `log.json` stays inside what a reader accepts for any
/// number of machines (issue #94). The probe drops a session from its
/// ledger, checkpoint and pass on the same rule that drops it from
/// `log.json`, so nothing is kept or re-read that nobody is shown (issue
/// #70). The rule reads only the rows and the configured machines, so two
/// monitors, a restart or a failed write cannot move it.
public enum SessionRetention {
    /// A day. Nothing reads a closed session after that (owner, 26 October
    /// 2026).
    public static let closedFor: TimeInterval = 86_400
    /// The whole file's budget, shared evenly by the configured machines.
    /// It is half of what a reader accepts, 5,000 rows and 4,000,000 bytes
    /// (issue #38), which leaves room for open sessions, never dropped.
    public static let fileRows = 2_000
    public static let fileBytes = 2_000_000
    /// The most `problems` takes beside the rows, and the most of each
    /// machine's text it keeps, so a remote's answer or a long machine ID
    /// cannot carry the file past a reader either.
    public static let problemBytes = 200_000
    public static let problemCharacters = 1_000

    /// One machine's share of `log.json`: its open sessions and the newest
    /// closed ones that fit beside them.
    public struct Budget: Equatable, Sendable {
        public let rows: Int
        public let bytes: Int

        /// Nil outside 0 to the whole file's budget, which is all the probe
        /// takes from the command line.
        public init?(rows: Int, bytes: Int) {
            guard (0 ... SessionRetention.fileRows).contains(rows), (0 ... SessionRetention.fileBytes).contains(bytes) else { return nil }
            self.rows = rows; self.bytes = bytes
        }

        /// An even part of the whole file, its bytes less machine `id` on
        /// each of its rows, which the app adds after the probe measures
        /// them. Past 2,000 machines, or with a long enough `id`, a share
        /// keeps no closed session.
        public static func share(machines: Int, id: String = "") -> Budget {
            let count = max(1, machines)
            let rows = fileRows / count
            let name = (try? SessionLogFile.encoder().encode(id)).map { $0.count - 2 } ?? id.utf8.count * 6
            return Budget(rows: rows, bytes: max(0, fileBytes / count - rows * name))!
        }
    }

    /// Every open session, the newest closed ones within `closedFor` of
    /// `now` that fit `budget` beside them, newest first and stopping at the
    /// first that does not, and every superseded one within `closedFor`,
    /// which `log.json` never shows. `items` are one machine's. Kept rows
    /// pass again unchanged, so the monitor can apply it to what a probe
    /// already kept.
    static func kept<T>(_ items: [T], row: (T) -> SessionRow, now: Date, budget: Budget) -> [T] {
        let recent = items.filter { item in row(item).closedAt.map { now.timeIntervalSince($0) < closedFor } ?? true }
        let open = recent.map(row).filter { $0.closedAt == nil }
        var rows = open.count
        var bytes = open.reduce(0) { $0 + size($1) }
        var closed = recent.map(row).filter { $0.closedAt != nil && $0.status != "superseded" }
        closed.sort { ($0.closedAt!, $0.sessionId) > ($1.closedAt!, $1.sessionId) }
        var dropped: Set<String> = []
        for item in closed {
            let cost = size(item)
            if dropped.isEmpty, rows + 1 <= budget.rows, bytes + cost <= budget.bytes {
                rows += 1; bytes += cost
            } else {
                dropped.insert(item.sessionId)
            }
        }
        return recent.filter { !dropped.contains(row($0).sessionId) }
    }

    /// `problems` with each text cut to `problemCharacters`, and machines in
    /// ID order while they fit `problemBytes`; one that does not is left out.
    static func bounded(_ problems: [String: String]) -> [String: String] {
        var kept: [String: String] = [:]
        var bytes = 0
        for id in problems.keys.sorted() {
            let text = String(problems[id]!.prefix(problemCharacters))
            let cost = [id, text].reduce(2) { $0 + ((try? SessionLogFile.encoder().encode($1))?.count ?? $1.utf8.count * 6 + 2) }
            guard bytes + cost <= problemBytes else { continue }
            kept[id] = text; bytes += cost
        }
        return kept
    }

    /// What a row takes in `log.json`, measured without the two fields the
    /// app sets, so the probe and the app measure it alike. `Budget.share`
    /// leaves room for the machine.
    static func size(_ row: SessionRow) -> Int {
        var row = row; row.machine = ""; row.stale = false
        return ((try? SessionLogFile.encoder().encode(row))?.count ?? 0) + 1
    }
}
