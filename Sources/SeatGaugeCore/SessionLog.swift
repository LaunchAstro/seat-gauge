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

/// Pane observations cannot be recovered from transcripts once a pane goes.
/// The ledger therefore commits before its replaceable token checkpoint.
struct SessionLedger {
    let directory: URL
    var file: URL { directory.appendingPathComponent("observations.jsonl") }

    func rows() throws -> [String: SessionObservation] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let data = try Data(contentsOf: file)
        var rows: [String: SessionObservation] = [:]
        for line in data.split(separator: 0x0A).dropLast(data.last == 0x0A ? 0 : 1) {
            guard let observation = try? JSONDecoder().decode(SessionObservation.self, from: Data(line)) else {
                PollLog.system("log: incomplete pane observation skipped")
                continue
            }
            rows[observation.row.sessionId] = observation
        }
        return rows
    }

    func append(_ observations: [SessionObservation]) throws {
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
}

struct SessionObservation: Codable, Equatable {
    var row: SessionRow
    var pid: Int
    var processStart: String
    var paths: [String]
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
        let results = await withTaskGroup(of: (String, Result<SessionLogFile, ProcessFailure>).self) { group in
            for machine in machines { group.addTask { (machine.id, await prober.readLog(machine)) } }
            var all: [String: Result<SessionLogFile, ProcessFailure>] = [:]
            for await (machine, result) in group { all[machine] = result }
            return all
        }
        var problems: [String: String] = [:]
        let now = Date()
        for machine in machines {
            switch results[machine.id] {
            case let .success(log):
                rows[machine.id] = log.sessions.map { row in
                    var row = row; row.machine = machine.id
                    row.stale = row.stale || now.timeIntervalSince(row.asOf) > 90
                    return row
                }
            case let .failure(error):
                problems[machine.id] = error.reason
                rows[machine.id] = (rows[machine.id] ?? []).map { var row = $0; row.stale = true; return row }
            case .none: break
            }
        }
        let log = SessionLogFile(updated: now, sessions: machines.flatMap { rows[$0.id] ?? [] }
            .sorted { ($0.startedAt ?? .distantPast, $0.id) > ($1.startedAt ?? .distantPast, $1.id) }, problems: problems)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SessionLogFile.encoder().encode(log).write(to: file, options: .atomic)
        } catch { PollLog.system("log: snapshot could not be written") }
        notify(log)
        return log
    }
}
