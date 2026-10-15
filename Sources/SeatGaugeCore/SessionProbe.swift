import Foundation

/// Runs beside the logs on each machine. Only SessionRow leaves the machine;
/// paths, process identities and parser checkpoints stay in its private store.
public struct SessionProbe: Sendable {
    let runner: any ProcessRunning
    let directory: URL
    let home: URL
    let profiles: [SpendProfile]
    let byteBudget: Int

    public init(runner: any ProcessRunning = RealProcessRunner(),
                directory: URL = AppPaths.support.appendingPathComponent("log-private"),
                home: URL = URL(fileURLWithPath: NSHomeDirectory()), profiles: [SpendProfile] = [], byteBudget: Int = 32 << 20) {
        self.runner = runner; self.directory = directory; self.home = home; self.profiles = profiles; self.byteBudget = byteBudget
    }

    func command(_ executable: String, _ arguments: [String], timeout: Duration = .seconds(8)) async throws -> [String] {
        let child = try runner.launch(ProcessSpec(executable: URL(fileURLWithPath: executable), arguments: arguments,
            environment: ChildEnvironment.make(from: ProcessInfo.processInfo.environment, setting: ["LC_ALL": "C"]), timeout: timeout))
        child.closeInput()
        var lines: [String] = []
        for try await line in child.stdoutLines { lines.append(line) }
        return lines
    }

    func reply(_ arguments: [String]) async throws -> [String: Any] {
        let executable = home.appendingPathComponent(".local/bin/herdr").path
        let lines = try await command(executable, arguments)
        guard let object = JSON.object(lines.joined(separator: "\n")),
              let result = object["result"] as? [String: Any] else { throw ProcessFailure("herdr did not answer") }
        return result
    }

    public func run(now: Date = Date(), rates: RateCard = .bundled) async throws -> SessionLogFile {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return try await FileLock.holdingAsync(directory.appendingPathComponent("probe.lock"), timeout: .seconds(1)) {
            try await collect(now: now, rates: rates)
        }
    }

    func collect(now: Date, rates: RateCard) async throws -> SessionLogFile {
        let ledger = SessionLedger(directory: directory)
        var observations = try ledger.rows()
        let checkpointFile = directory.appendingPathComponent("offsets.json")
        var checkpoint = (try? Data(contentsOf: checkpointFile))
            .flatMap { try? JSONDecoder().decode(SessionCheckpoint.self, from: $0) } ?? SessionCheckpoint()
        let listing = try await reply(["pane", "list"])
        let workspaces = try await reply(["workspace", "list"])
        guard let panes = listing["panes"] as? [[String: Any]],
              let spaces = workspaces["workspaces"] as? [[String: Any]] else { throw ProcessFailure("herdr listing was incomplete") }
        let labels = Dictionary(spaces.compactMap { item -> (String, String)? in
            guard let id = item["workspace_id"] as? String, let label = item["label"] as? String else { return nil }
            return (id, label)
        }, uniquingKeysWith: { first, _ in first })
        var alive: Set<String> = []
        var uncertain: Set<String> = []
        var changes: [SessionObservation] = []
        let present = Set(panes.compactMap { $0["pane_id"] as? String })
        for pane in panes {
            guard let paneID = pane["pane_id"] as? String else { continue }
            let process: [String: Any]
            do {
                let info = try await reply(["pane", "process-info", "--pane", paneID])
                guard let value = info["process_info"] as? [String: Any] else { uncertain.insert(paneID); continue }
                guard value["foreground_processes"] is [[String: Any]] else { uncertain.insert(paneID); continue }
                process = value
            } catch { uncertain.insert(paneID); continue }
            let processes = process["foreground_processes"] as? [[String: Any]] ?? []
            for item in processes {
                guard let argv = item["argv"] as? [String], let first = argv.first,
                      let pid = JSON.int(item["pid"]) else { continue }
                let tool = URL(fileURLWithPath: first).lastPathComponent
                guard tool == "claude" || tool == "codex" else { continue }
                let birth = (try? await command("/bin/ps", ["-p", String(pid), "-o", "lstart="]))?.first ?? ""
                guard !birth.isEmpty else { uncertain.insert(paneID); continue }
                let cwd = item["cwd"] as? String ?? pane["foreground_cwd"] as? String ?? pane["cwd"] as? String ?? ""
                // -b prevents lsof from statting mounted network volumes.
                let opened = (try? await command("/usr/sbin/lsof", ["-b", "-w", "-a", "-p", String(pid), "-Fn"])) ?? []
                var paths = opened.compactMap { line -> String? in
                    guard line.hasPrefix("n"), line.hasSuffix(".jsonl") else { return nil }
                    let path = String(line.dropFirst())
                    guard path.hasPrefix(home.path + "/"), !path.contains("/../") else { return nil }
                    if tool == "codex" { return URL(fileURLWithPath: path).lastPathComponent.hasPrefix("rollout-") ? path : nil }
                    return path.contains("/projects/") ? path : nil
                }
                let reported = pane["agent_session"] as? [String: Any]
                let reportedID = reported?["kind"] as? String == "id" ? reported?["value"] as? String : nil
                if tool == "codex", paths.isEmpty, let reportedID {
                    paths = findCodex(reportedID)
                }
                if tool == "claude", paths.isEmpty {
                    if reported?["kind"] as? String == "path", let path = reported?["value"] as? String,
                       path.hasPrefix(home.path + "/"), path.hasSuffix(".jsonl"), !path.contains("/../") {
                        paths = [path]
                    } else {
                        paths = findClaude(cwd: cwd, birth: birth, session: reportedID)
                    }
                }
                paths = Array(Set(paths)).sorted()
                // A process may hold child rollouts as well. Its reported id
                // is authoritative; otherwise the oldest file is the root.
                let primary = reportedID ?? paths.min { creation($0) < creation($1) }.flatMap { path in
                    tool == "codex" ? CodexCollector.firstSession(of: URL(fileURLWithPath: path))
                        : URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                }
                let previous = observations.values.first { $0.pid == pid && Self.start($0.processStart) == Self.start(birth) && $0.row.pane == paneID && $0.row.status != "superseded" }
                let id = primary ?? previous?.row.sessionId ?? "process:\(paneID):\(pid):\(birth)"
                for old in observations.values.filter({ $0.row.sessionId.hasPrefix("process:") && $0.row.sessionId != id
                    && $0.pid == pid && Self.start($0.processStart) == Self.start(birth) && $0.row.pane == paneID }) {
                    observations.removeValue(forKey: old.row.sessionId)
                    var retired = old; retired.row.status = "superseded"; retired.row.closedAt = now
                    changes.append(retired)
                }
                if let previous, previous.row.sessionId != id {
                    observations.removeValue(forKey: previous.row.sessionId)
                    var retired = previous; retired.row.status = "superseded"; retired.row.closedAt = now
                    changes.append(retired)
                    for path in previous.paths where checkpoint.owners[path] == previous.row.sessionId {
                        checkpoint.owners[path] = id
                    }
                }
                var row = observations[id]?.row ?? previous?.row ?? SessionRow(sessionId: id,
                    workspace: labels[pane["workspace_id"] as? String ?? ""] ?? "", pane: paneID,
                    tool: tool, status: "unknown", asOf: now)
                row.sessionId = id
                row.observe(workspace: labels[pane["workspace_id"] as? String ?? ""] ?? row.workspace)
                row.pane = paneID
                row.status = pane["agent_status"] as? String ?? "unknown"
                if row.status == "working", row.startedAt == nil { row.startedAt = now }
                row.closedAt = nil; row.asOf = now; row.stale = false
                let options = Self.options(argv)
                row.model = options.model ?? row.model; row.effort = options.effort ?? row.effort
                if !cwd.isEmpty, !cwd.hasPrefix("/Volumes/") {
                    row.branch = (try? await command("/usr/bin/git", ["-C", cwd, "symbolic-ref", "--short", "HEAD"]))?.first
                }
                let keptPaths = Array(Set((observations[id]?.paths ?? previous?.paths ?? []) + paths)).sorted()
                let owned = keptPaths.filter { path in
                    if checkpoint.owners[path] == nil { checkpoint.owners[path] = id }
                    return checkpoint.owners[path] == id
                }
                row = refreshed(row, paths: owned, checkpoint: &checkpoint, rates: rates)
                let observation = SessionObservation(row: row, pid: pid, processStart: birth, paths: keptPaths)
                observations[id] = observation; alive.insert(id); changes.append(observation)
            }
        }
        for (id, observation) in observations where !alive.contains(id) && observation.row.status != "superseded" {
            var closed = observation
            if closed.row.closedAt == nil {
                let birth = present.contains(closed.row.pane)
                    ? (try? await command("/bin/ps", ["-p", String(closed.pid), "-o", "lstart="]))?.first : nil
                if uncertain.contains(closed.row.pane) || birth.map({ Self.start($0) == Self.start(closed.processStart) }) == true {
                    closed.row.stale = true
                } else {
                    closed.row.status = "closed"; closed.row.closedAt = now
                }
            }
            if closed.row.closedAt != nil {
                closed.row = refreshed(closed.row, paths: closed.paths.filter { checkpoint.owners[$0] == nil || checkpoint.owners[$0] == id }, checkpoint: &checkpoint, rates: rates)
                closed.row.asOf = now
            }
            observations[id] = closed
            if closed != observation { changes.append(closed) }
        }
        try ledger.append(changes)
        try JSONEncoder().encode(checkpoint).write(to: checkpointFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: checkpointFile.path)
        return SessionLogFile(updated: now, sessions: observations.values.map(\.row).filter { $0.status != "superseded" })
    }

    func refreshed(_ original: SessionRow, paths: [String], checkpoint: inout SessionCheckpoint, rates: RateCard) -> SessionRow {
        var row = original
        var models: [String: TokenCounts] = [:]
        var complete = !paths.isEmpty
        var rollouts: [CodexRollout.Rollout] = []
        for path in paths.sorted() {
            if let owner = checkpoint.owners[path], owner != row.sessionId { continue }
            checkpoint.owners[path] = row.sessionId
            var tokens = checkpoint.files[path] ?? SessionTokens()
            do { try tokens.read(URL(fileURLWithPath: path), tool: row.tool, budget: byteBudget) }
            catch { complete = false }
            checkpoint.files[path] = tokens
            complete = complete && tokens.complete
            if row.tool == "codex" {
                rollouts.append(tokens.rollout(URL(fileURLWithPath: path)))
            } else {
                for response in tokens.responses {
                    if checkpoint.messageOwners[response.messageID] == nil { checkpoint.messageOwners[response.messageID] = path }
                    guard checkpoint.messageOwners[response.messageID] == path else { continue }
                    let model = response.model.replacingOccurrences(of: "[1m]", with: "")
                    models[model, default: TokenCounts()] = models[model, default: TokenCounts()] + response.counts
                }
            }
        }
        if row.tool == "codex" {
            let reading = CodexRollout.read(rollouts: rollouts, calendar: .current,
                                           excluding: AppPaths.primers(beside: AppPaths.codexPrimer))
            for (cell, counts) in reading.cells { models[cell.model, default: TokenCounts()] = models[cell.model, default: TokenCounts()] + counts }
        }
        row.models = models
        row.tokens = paths.isEmpty ? nil : models.values.reduce(TokenCounts(), +)
        row.stale = !complete
        if row.model == nil { row.model = models.keys.sorted().first }
        let prices = models.map { rates.usd(model: $0.key, counts: $0.value) }
        row.usd = complete && !models.isEmpty && prices.allSatisfy { $0 != nil }
            ? prices.compactMap { $0 }.reduce(0, +) : nil
        return row
    }

    static func start(_ text: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE MMM d HH:mm:ss yyyy", "EEE d MMM HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text.trimmingCharacters(in: .whitespaces)) { return date }
        }
        return nil
    }

    func creation(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.creationDate] as? Date) ?? .distantFuture
    }

    func findCodex(_ id: String) -> [String] {
        let root = home.appendingPathComponent(".codex/sessions")
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles]) else { return [] }
        return walk.compactMap { $0 as? URL }.filter { $0.lastPathComponent.hasSuffix("-\(id).jsonl") }.map(\.path)
    }

    func findClaude(cwd: String, birth: String, session: String?) -> [String] {
        guard !cwd.isEmpty, !cwd.hasPrefix("/Volumes/") else { return [] }
        let folder = cwd.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let discovered = (try? FileManager.default.contentsOfDirectory(
            at: home.appendingPathComponent(".seat-gauge/profiles"), includingPropertiesForKeys: nil)) ?? []
        let roots = Set(profiles.map(\.projects) + [home.appendingPathComponent(".claude/projects")]
            + discovered.map { $0.appendingPathComponent("projects") })
        let started = Self.start(birth)
        var matches: [String] = []
        for root in roots {
            let project = root.appendingPathComponent(folder)
            let files = (try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: [.creationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                if let session {
                    if file.deletingPathExtension().lastPathComponent == session { matches.append(file.path) }
                } else if let started, abs(creation(file.path).timeIntervalSince(started)) < 120 { matches.append(file.path) }
            }
        }
        return matches.count == 1 ? matches : []
    }

    static func options(_ argv: [String]) -> (model: String?, effort: String?) {
        var model: String?; var effort: String?
        var index = 1
        let values = ["-m", "--model", "--effort", "-c", "--config", "--profile", "-p", "--cd", "-C",
                      "--add-dir", "--sandbox", "-s", "--ask-for-approval", "-a", "--session-id", "--resume"]
        while index < argv.count {
            let arg = argv[index]
            if index == 1 && ["exec", "e"].contains(arg) { index += 1; continue }
            if arg == "--" || !arg.hasPrefix("-") { break }
            if values.contains(arg) {
                guard index + 1 < argv.count else { break }
                let value = argv[index + 1]
                if arg == "-m" || arg == "--model" { model = value }
                if arg == "--effort" { effort = value }
                if ["-c", "--config"].contains(arg), value.hasPrefix("model_reasoning_effort=") {
                    effort = String(value.dropFirst("model_reasoning_effort=".count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
                index += 2
            } else {
                if arg.hasPrefix("--model=") { model = String(arg.dropFirst(8)) }
                if arg.hasPrefix("--effort=") { effort = String(arg.dropFirst(9)) }
                index += 1
            }
        }
        return (model, effort)
    }

}

extension MachineProber {
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    public func readLog(_ machine: Machine) async -> Result<SessionLogFile, ProcessFailure> {
        var spec = Self.spec(machine, environment: environment)
        spec = ProcessSpec(executable: spec.executable, arguments: spec.arguments, environment: spec.environment,
                           timeout: .seconds(90))
        do {
            let child = try runner.launch(spec)
            let localHelper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/seatgauge-cli").path
            let helper = machine.ssh == nil && FileManager.default.isExecutableFile(atPath: localHelper)
                ? Self.quote(localHelper) : machine.ssh == nil
                    ? "\"$HOME/.local/bin/seatgauge-cli\"" : "\"$HOME/.local/libexec/seatgauge-log-probe\""
            let state = machine.ssh == nil
                ? " --directory " + Self.quote(AppPaths.support.appendingPathComponent("log-private").path) : ""
            try child.send("\(helper) log-probe\(state)")
            child.closeInput()
            var lines: [String] = []
            for try await line in child.stdoutLines { lines.append(line) }
            let log = try SessionLogFile.decoder().decode(SessionLogFile.self, from: Data(lines.joined(separator: "\n").utf8))
            guard log.version == 1 else { return .failure(ProcessFailure("the Log probe version is unsupported")) }
            return .success(log)
        } catch { return .failure(ProcessFailure("the Log probe did not answer; install this version's CLI helper on the machine")) }
    }
}
