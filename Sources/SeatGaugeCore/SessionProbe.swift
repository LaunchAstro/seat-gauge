import Foundation

/// Runs beside the logs on each machine. Only SessionRow leaves the machine;
/// paths, process identities and parser checkpoints stay in its private store.
public struct SessionProbe: Sendable {
    let runner: any ProcessRunning
    let directory: URL
    let home: URL
    let profiles: [SpendProfile]
    let byteBudget: Int

    /// How often an open session that changed in nothing else is written
    /// again, so a row that later goes stale says roughly when it was last
    /// seen. A closed one is not: a pass sets its time on every read.
    static let seenEvery: TimeInterval = 600

    /// A git call that has not answered in this long is waiting on macOS,
    /// which holds a read of Desktop, Documents or Downloads until the owner
    /// answers its folder prompt. A reinstall asks again (issue #74). Run in a
    /// terminal, the branch read takes a few milliseconds.
    static let gitTimeout: Duration = .seconds(2)

    /// The Log problem a held git call leaves. It names no folder, since
    /// `log.json` carries no paths.
    static let folderAccessProblem = "git could not read a session's folder within \(Int(gitTimeout.seconds)) s,"
        + " so branches show as last seen;"
        + " macOS may be waiting for you to let Seat Gauge open Desktop, Documents or Downloads."
        + " Answer the prompt, or allow it in System Settings > Privacy & Security > Files and Folders"

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

    /// What `log-probe` is told: `--directory <folder>` for its private
    /// store, and `--closed-through <seconds since 1970>`, the newest second
    /// whose closed rows `log.json` no longer shows. A flag it does not know
    /// is passed over with its value, so a newer app can drive this helper.
    public struct Arguments {
        public var directory: URL?
        public var closedThrough: Date?

        public init(_ arguments: [String]) {
            var index = 0
            while index + 1 < arguments.count {
                let value = arguments[index + 1]
                switch arguments[index] {
                case "--directory": directory = URL(fileURLWithPath: value)
                case "--closed-through": closedThrough = Int(value).map { Date(timeIntervalSince1970: Double($0)) }
                default: break
                }
                index += 2
            }
        }
    }

    /// `closedThrough` is the monitor's cut-off for rows it no longer shows
    /// (see `SessionRetention.bounded`).
    public func run(now: Date = Date(), rates: RateCard = .bundled, closedThrough: Date? = nil) async throws -> SessionLogFile {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return try await FileLock.holdingAsync(directory.appendingPathComponent("probe.lock"), timeout: .seconds(1)) {
            try await collect(now: now, rates: rates, closedThrough: closedThrough)
        }
    }

    func collect(now: Date, rates: RateCard, closedThrough: Date? = nil) async throws -> SessionLogFile {
        let ledger = SessionLedger(directory: directory)
        let stored = try ledger.read()
        func staying(_ rows: [String: SessionObservation]) -> [String: SessionObservation] {
            SessionRetention.kept(Array(rows), row: { $0.value.row }, now: now, through: closedThrough)
                .reduce(into: [String: SessionObservation]()) { $0[$1.key] = $1.value }
        }
        // A session `log.json` no longer shows leaves the pass.
        var observations = staying(stored.rows)
        let checkpointFile = directory.appendingPathComponent("offsets.json")
        var checkpoint = (try? Data(contentsOf: checkpointFile))
            .flatMap { try? JSONDecoder().decode(SessionCheckpoint.self, from: $0) } ?? SessionCheckpoint()
        checkpoint.release(stored.rows.values.filter { observations[$0.row.sessionId] == nil }, keeping: observations.values)
        for observation in observations.values where observation.row.status != "superseded" {
            for path in observation.paths where checkpoint.owners[path] == nil {
                checkpoint.owners[path] = observation.row.sessionId
            }
        }
        let listing = try await reply(["pane", "list"])
        let workspaces = try await reply(["workspace", "list"])
        guard let panes = listing["panes"] as? [[String: Any]],
              let spaces = workspaces["workspaces"] as? [[String: Any]] else { throw ProcessFailure("herdr listing was incomplete") }
        let labels = Dictionary(spaces.compactMap { item -> (String, String)? in
            guard let id = item["workspace_id"] as? String, let label = item["label"] as? String else { return nil }
            return (id, label)
        }, uniquingKeysWith: { first, _ in first })
        var alive: Set<String> = []
        // Once one git call is held, the rest of the pass skips git, so a
        // folder prompt nobody has answered costs one short wait per pass,
        // not one per pane.
        var gitHeld = false
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
                // A process may hold child rollouts as well, so the id it
                // reports wins; without one, the oldest file is the root.
                let primary = reportedID ?? paths.min { creation($0) < creation($1) }.flatMap { path in
                    tool == "codex" ? CodexCollector.firstSession(of: URL(fileURLWithPath: path))
                        : URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                }
                let matches = observations.values.filter {
                    $0.pid == pid && Self.start($0.processStart) == Self.start(birth)
                        && $0.row.pane == paneID && $0.row.status != "superseded"
                }.sorted { ($0.row.asOf, $0.row.sessionId) > ($1.row.asOf, $1.row.sessionId) }
                let previous = matches.first { $0.row.sessionId == primary } ?? matches.first
                let id = primary ?? previous?.row.sessionId ?? "process:\(paneID):\(pid):\(birth)"
                let inherited = previous.flatMap { $0.row.sessionId.hasPrefix("process:") ? $0 : nil }
                for old in matches where old.row.sessionId.hasPrefix("process:") && old.row.sessionId != id {
                    observations.removeValue(forKey: old.row.sessionId)
                    var retired = old; retired.row.status = "superseded"; retired.row.closedAt = now
                    changes.append(retired)
                    for path in old.paths where checkpoint.owners[path] == old.row.sessionId { checkpoint.owners[path] = id }
                }
                var row = observations[id]?.row ?? inherited?.row ?? SessionRow(sessionId: id,
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
                if !cwd.isEmpty, !cwd.hasPrefix("/Volumes/"), !gitHeld {
                    do {
                        row.branch = try await command("/usr/bin/git", ["-C", cwd, "symbolic-ref", "--short", "HEAD"],
                                                       timeout: Self.gitTimeout).first
                    } catch let failure as ProcessFailure where failure == .timedOut(after: Self.gitTimeout) {
                        gitHeld = true
                    } catch { row.branch = nil }
                }
                let keptPaths = Array(Set((observations[id]?.paths ?? inherited?.paths ?? []) + paths)).sorted()
                let owned = keptPaths.filter { path in
                    if checkpoint.owners[path] == nil { checkpoint.owners[path] = id }
                    return checkpoint.owners[path] == id
                }
                row = refreshed(row, paths: owned, checkpoint: &checkpoint, rates: rates)
                let observation = SessionObservation(row: row, pid: pid, processStart: birth, paths: owned)
                observations[id] = observation; alive.insert(id)
            }
        }
        for (id, observation) in observations where !alive.contains(id) && observation.row.status != "superseded" {
            var closed = observation
            if closed.row.closedAt == nil {
                let birth = present.contains(closed.row.pane)
                    ? (try? await command("/bin/ps", ["-p", String(closed.pid), "-o", "lstart="]))?.first : nil
                if uncertain.contains(closed.row.pane) {
                    closed.row.stale = true
                } else if birth.map({ Self.start($0) == Self.start(closed.processStart) }) == true {
                    let known = observations.values.contains { alive.contains($0.row.sessionId)
                        && $0.pid == closed.pid && $0.processStart == closed.processStart }
                    if known {
                        closed.row.status = "idle"; closed.row.asOf = now
                        closed.row = refreshed(closed.row, paths: closed.paths, checkpoint: &checkpoint, rates: rates)
                        alive.insert(id)
                    } else { closed.row.stale = true }
                } else {
                    closed.row.status = "closed"; closed.row.closedAt = now
                }
            }
            if closed.row.closedAt != nil {
                closed.row = refreshed(closed.row, paths: closed.paths.filter { checkpoint.owners[$0] == nil || checkpoint.owners[$0] == id }, checkpoint: &checkpoint, rates: rates)
                closed.row.asOf = now
            }
            observations[id] = closed
            if closed != observation && closed.row.closedAt == nil && !alive.contains(id) { changes.append(closed) }
        }
        for (id, observation) in observations where observation.row.status != "superseded"
            && (alive.contains(id) || observation.row.closedAt != nil) {
            var observation = observation
            observation.row = summarized(observation.row, paths: observation.paths, checkpoint: &checkpoint, rates: rates)
            observations[id] = observation
            changes.append(observation)
        }
        // A line is written for a session that changed in more than its seen
        // time, and for an open one (no `closedAt`) on two more counts that
        // keep what `asOf` is read for: its ledger time is `seenEvery` old, so
        // a row that goes stale is dated near when it was last seen, or it
        // was seen this pass beside a written one of the same process, so the
        // ledger keeps their order for `matches` above. A closed session's
        // time is set on every pass and read by nothing, so only a real
        // change writes it.
        func process(_ observation: SessionObservation) -> [String] {
            [String(observation.pid), Self.start(observation.processStart).map { "\($0.timeIntervalSince1970)" }
                ?? observation.processStart, observation.row.pane]
        }
        let changed = Set(changes.filter { change in
            guard let last = stored.rows[change.row.sessionId], last.matches(change) else { return true }
            return change.row.closedAt == nil && change.row.asOf.timeIntervalSince(last.row.asOf) >= Self.seenEvery
        }.map(\.row.sessionId))
        let moved = Set(changes.filter { changed.contains($0.row.sessionId) }.map(process))
        let novel = changes.filter {
            changed.contains($0.row.sessionId)
                || ($0.row.closedAt == nil && $0.row.asOf == now && moved.contains(process($0)))
        }
        // `recorded` is what a read of the ledger gives after the append,
        // which is what compaction writes. The append's first newline ends a
        // torn last line, so a whole one is read from then on.
        var recorded = stored.rows
        if !novel.isEmpty, let tail = stored.tail { recorded[tail.row.sessionId] = tail }
        for change in novel { recorded[change.row.sessionId] = change }
        try ledger.append(novel)
        // A session this pass closed can put the machine over its cap, so the
        // rule runs again on what the ledger now holds, and what leaves goes
        // from the ledger, the checkpoint and this pass's rows alike.
        let kept = staying(recorded)
        let leaving = recorded.filter { kept[$0.key] == nil }
        checkpoint.release(leaving.values, keeping: kept.values)
        do {
            try ledger.compactIfLong(kept, lines: stored.lines + (novel.isEmpty ? 0 : novel.count + 1),
                                     dropping: !leaving.isEmpty)
        }
        catch { PollLog.system("log: the pane ledger could not be compacted") }
        try JSONEncoder().encode(checkpoint).write(to: checkpointFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: checkpointFile.path)
        return SessionLogFile(updated: now, sessions: observations.values.map(\.row)
            .filter { $0.status != "superseded" && leaving[$0.sessionId] == nil },
                              problems: gitHeld ? ["git": Self.folderAccessProblem] : [:])
    }

    func refreshed(_ original: SessionRow, paths: [String], checkpoint: inout SessionCheckpoint, rates: RateCard) -> SessionRow {
        var failed = false
        for path in paths.sorted() {
            if let owner = checkpoint.owners[path], owner != original.sessionId { continue }
            checkpoint.owners[path] = original.sessionId
            var tokens = checkpoint.files[path] ?? SessionTokens()
            do { try tokens.read(URL(fileURLWithPath: path), tool: original.tool, budget: byteBudget) }
            catch { failed = true; tokens.complete = false }
            checkpoint.files[path] = tokens
        }
        var row = summarized(original, paths: paths, checkpoint: &checkpoint, rates: rates)
        row.stale = row.stale || failed
        return row
    }

    func summarized(_ original: SessionRow, paths: [String], checkpoint: inout SessionCheckpoint, rates: RateCard) -> SessionRow {
        var row = original
        var models: [String: TokenCounts] = [:]
        var complete = !paths.isEmpty
        var rollouts: [CodexRollout.Rollout] = []
        for path in paths.sorted() {
            guard checkpoint.owners[path] == row.sessionId, let tokens = checkpoint.files[path] else { complete = false; continue }
            complete = complete && tokens.complete
            if row.tool == "codex" {
                rollouts.append(tokens.rollout(URL(fileURLWithPath: path)))
            } else {
                for response in tokens.responses {
                    let owner = checkpoint.messageOwners[response.messageID]
                    let present = owner.flatMap { checkpoint.files[$0] }?.seen.contains(response.messageID) ?? false
                    if !present {
                        checkpoint.messageOwners[response.messageID] = path
                    }
                    guard checkpoint.messageOwners[response.messageID] == path else { continue }
                    models[response.filedModel, default: TokenCounts()] += response.counts
                }
            }
        }
        if row.tool == "codex" {
            let reading = CodexRollout.read(rollouts: rollouts, calendar: .current,
                                           excluding: AppPaths.primers(beside: AppPaths.codexPrimer))
            for (cell, counts) in reading.cells { models[cell.model, default: TokenCounts()] += counts }
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

    public func readLog(_ machine: Machine, closedThrough: Date? = nil) async -> Result<SessionLogFile, ProcessFailure> {
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
            let through = closedThrough.map { " --closed-through \(Int(SessionRetention.second($0)))" } ?? ""
            try child.send("\(helper) log-probe\(state)\(through)")
            child.closeInput()
            var lines: [String] = []
            for try await line in child.stdoutLines { lines.append(line) }
            let log = try SessionLogFile.decoder().decode(SessionLogFile.self, from: Data(lines.joined(separator: "\n").utf8))
            guard log.version == 1 else { return .failure(ProcessFailure("the Log probe version is unsupported")) }
            return .success(log)
        } catch let failure as ProcessFailure where machine.ssh == nil && failure == .timedOut(after: spec.timeout) {
            // This Mac runs the helper inside the app, so a pass that ran out
            // of time is almost never a missing helper. It is most often macOS
            // holding a folder read until its prompt is answered (issue #74).
            return .failure(ProcessFailure("the Log probe did not answer within \(Int(spec.timeout.seconds)) s;"
                + " macOS may be waiting for you to let Seat Gauge open Desktop, Documents or Downloads."
                + " Answer the prompt, or allow it in System Settings > Privacy & Security > Files and Folders"))
        } catch { return .failure(ProcessFailure("the Log probe did not answer; install this version's CLI helper on the machine")) }
    }
}
