import Foundation

/// Runs beside the logs on each machine. Only SessionRow leaves the machine;
/// paths, process identities and parser checkpoints stay in its private store.
public struct SessionProbe: Sendable {
    let runner: any ProcessRunning
    let directory: URL
    let home: URL
    let profiles: [SpendProfile]
    let byteBudget: Int
    /// This machine's share of `log.json`, as the app passes it.
    let keep: SessionRetention.Budget

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
        + " so branches and repositories show as last seen;"
        + " macOS may be waiting for you to let Seat Gauge open Desktop, Documents or Downloads."
        + " Answer the prompt, or allow it in System Settings > Privacy & Security > Files and Folders"

    public init(runner: any ProcessRunning = RealProcessRunner(),
                directory: URL = AppPaths.support.appendingPathComponent("log-private"),
                home: URL = URL(fileURLWithPath: NSHomeDirectory()), profiles: [SpendProfile] = [], byteBudget: Int = 32 << 20,
                keep: SessionRetention.Budget = .share(machines: 1)) {
        self.runner = runner; self.directory = directory; self.home = home; self.profiles = profiles; self.byteBudget = byteBudget
        self.keep = keep
    }

    /// `log-probe`'s arguments: the private folder, and this machine's share
    /// of `log.json` as two whole numbers the budget accepts. A value it
    /// refuses leaves the default, and a flag it does not know is passed
    /// over, so a newer app can talk to an older probe and the other way round.
    public static func arguments(_ arguments: [String]) -> (directory: URL?, keep: SessionRetention.Budget) {
        var directory: URL?
        var rows: Int?
        var bytes: Int?
        var index = 0
        while index < arguments.count {
            let value = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch arguments[index] {
            case "--directory" where value != nil: directory = URL(fileURLWithPath: value!); index += 2
            case "--keep-rows" where value != nil: rows = Int(value!); index += 2
            case "--keep-bytes" where value != nil: bytes = Int(value!); index += 2
            default: index += 1
            }
        }
        let standard = SessionRetention.Budget.share(machines: 1)
        let keep = rows.flatMap { rows in bytes.flatMap { SessionRetention.Budget(rows: rows, bytes: $0) } } ?? standard
        return (directory, keep)
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

    /// One pass, in the order it runs. Paths, process identities and the
    /// checkpoint stay in `ProbePass`; only the rows leave it.
    func collect(now: Date, rates: RateCard) async throws -> SessionLogFile {
        let ledger = SessionLedger(directory: directory)
        var pass = try begin(ledger.read(), now: now)
        let (panes, labels) = try await listing()
        pass.present = Set(panes.compactMap { $0["pane_id"] as? String })
        for pane in panes { await observe(pane, labels: labels, in: &pass, rates: rates) }
        await settleUnseen(in: &pass, rates: rates)
        summarizeShown(in: &pass, rates: rates)
        try commit(&pass, to: ledger)
        let shown = SessionRetention.kept(pass.observations.values.map(\.row), row: { $0 }, now: now, budget: keep)
        return SessionLogFile(updated: now, sessions: shown.filter { $0.status != "superseded" },
                              problems: pass.gitHeld ? ["git": Self.folderAccessProblem] : [:])
    }

    var checkpointFile: URL { directory.appendingPathComponent("offsets.json") }

    /// The ledger and checkpoint as the last pass left them. A session
    /// `log.json` no longer shows leaves the pass.
    func begin(_ stored: SessionLedger.Stored, now: Date) -> ProbePass {
        var pass = ProbePass(now: now, stored: stored, observations: [:], checkpoint: SessionCheckpoint())
        let observations = pass.staying(stored.rows)
        var checkpoint = (try? Data(contentsOf: checkpointFile))
            .flatMap { try? JSONDecoder().decode(SessionCheckpoint.self, from: $0) } ?? SessionCheckpoint()
        checkpoint.release(stored.rows.values.filter { observations[$0.row.sessionId] == nil }, keeping: observations.values)
        for observation in observations.values where observation.row.status != "superseded" {
            for path in observation.paths where checkpoint.owners[path] == nil {
                checkpoint.owners[path] = observation.row.sessionId
            }
        }
        pass.observations = observations; pass.checkpoint = checkpoint
        return pass
    }

    /// herdr's panes, and each workspace's label by id.
    func listing() async throws -> (panes: [[String: Any]], labels: [String: String]) {
        let listing = try await reply(["pane", "list"])
        let workspaces = try await reply(["workspace", "list"])
        guard let panes = listing["panes"] as? [[String: Any]],
              let spaces = workspaces["workspaces"] as? [[String: Any]] else { throw ProcessFailure("herdr listing was incomplete") }
        let labels = Dictionary(spaces.compactMap { item -> (String, String)? in
            guard let id = item["workspace_id"] as? String, let label = item["label"] as? String else { return nil }
            return (id, label)
        }, uniquingKeysWith: { first, _ in first })
        return (panes, labels)
    }

    /// Every agent process in one pane. A pane herdr cannot describe is
    /// uncertain, so its sessions go stale rather than closed.
    func observe(_ pane: [String: Any], labels: [String: String], in pass: inout ProbePass, rates: RateCard) async {
        guard let paneID = pane["pane_id"] as? String else { return }
        guard let info = try? await reply(["pane", "process-info", "--pane", paneID]),
              let value = info["process_info"] as? [String: Any],
              let processes = value["foreground_processes"] as? [[String: Any]] else { pass.uncertain.insert(paneID); return }
        for item in processes {
            await observe(process: item, in: pane, id: paneID, labels: labels, pass: &pass, rates: rates)
        }
    }

    func observe(process item: [String: Any], in pane: [String: Any], id paneID: String, labels: [String: String],
                 pass: inout ProbePass, rates: RateCard) async {
        guard let argv = item["argv"] as? [String], let first = argv.first,
              let pid = JSON.int(item["pid"]) else { return }
        let tool = URL(fileURLWithPath: first).lastPathComponent
        guard tool == "claude" || tool == "codex" else { return }
        let birth = (try? await command("/bin/ps", ["-p", String(pid), "-o", "lstart="]))?.first ?? ""
        guard !birth.isEmpty else { pass.uncertain.insert(paneID); return }
        let cwd = item["cwd"] as? String ?? pane["foreground_cwd"] as? String ?? pane["cwd"] as? String ?? ""
        let reported = pane["agent_session"] as? [String: Any]
        let reportedID = reported?["kind"] as? String == "id" ? reported?["value"] as? String : nil
        let paths = await transcripts(tool: tool, pid: pid, cwd: cwd, birth: birth, reported: reported, reportedID: reportedID)
        // A process may hold child rollouts as well, so the id it
        // reports wins; without one, the oldest file is the root.
        let primary = reportedID ?? paths.min { creation($0) < creation($1) }.flatMap { path in
            tool == "codex" ? CodexCollector.firstSession(of: URL(fileURLWithPath: path))
                : URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
        let (id, inherited) = adopt(primary, pid: pid, birth: birth, pane: paneID, in: &pass)
        let label = labels[pane["workspace_id"] as? String ?? ""]
        var row = pass.observations[id]?.row ?? inherited?.row ?? SessionRow(sessionId: id,
            workspace: label ?? "", pane: paneID, tool: tool, status: "unknown", asOf: pass.now)
        row.sessionId = id
        row.observe(workspace: label ?? row.workspace)
        row.pane = paneID
        row.status = pane["agent_status"] as? String ?? "unknown"
        if row.status == "working", row.startedAt == nil { row.startedAt = pass.now }
        row.closedAt = nil; row.asOf = pass.now; row.stale = false
        let options = Self.options(argv)
        row.model = options.model ?? row.model; row.effort = options.effort ?? row.effort
        await readFolder(Self.folder(argv: argv, cwd: cwd), into: &row, in: &pass)
        let keptPaths = Array(Set((pass.observations[id]?.paths ?? inherited?.paths ?? []) + paths)).sorted()
        let owned = keptPaths.filter { path in
            if pass.checkpoint.owners[path] == nil { pass.checkpoint.owners[path] = id }
            return pass.checkpoint.owners[path] == id
        }
        row = refreshed(row, paths: owned, checkpoint: &pass.checkpoint, rates: rates)
        pass.observations[id] = SessionObservation(row: row, pid: pid, processStart: birth, paths: owned)
        pass.alive.insert(id)
    }

    /// The transcripts one agent process writes: the files it holds open,
    /// else the session herdr reports, else a match on folder and start time.
    func transcripts(tool: String, pid: Int, cwd: String, birth: String,
                     reported: [String: Any]?, reportedID: String?) async -> [String] {
        // -b prevents lsof from statting mounted network volumes.
        let opened = (try? await command("/usr/sbin/lsof", ["-b", "-w", "-a", "-p", String(pid), "-Fn"])) ?? []
        var paths = opened.compactMap { line -> String? in
            guard line.hasPrefix("n"), line.hasSuffix(".jsonl") else { return nil }
            let path = String(line.dropFirst())
            guard path.hasPrefix(home.path + "/"), !path.contains("/../") else { return nil }
            if tool == "codex" { return URL(fileURLWithPath: path).lastPathComponent.hasPrefix("rollout-") ? path : nil }
            return path.contains("/projects/") ? path : nil
        }
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
        return Array(Set(paths)).sorted()
    }

    /// Which session a process is: `primary`, else the one the same process
    /// in the same pane was last seen as, else a `process:` placeholder. A
    /// placeholder the process has outgrown is superseded, and the files it
    /// owned pass to the session it became.
    func adopt(_ primary: String?, pid: Int, birth: String, pane paneID: String,
               in pass: inout ProbePass) -> (id: String, inherited: SessionObservation?) {
        let matches = pass.observations.values.filter {
            $0.pid == pid && Self.start($0.processStart) == Self.start(birth)
                && $0.row.pane == paneID && $0.row.status != "superseded"
        }.sorted { ($0.row.asOf, $0.row.sessionId) > ($1.row.asOf, $1.row.sessionId) }
        let previous = matches.first { $0.row.sessionId == primary } ?? matches.first
        let id = primary ?? previous?.row.sessionId ?? "process:\(paneID):\(pid):\(birth)"
        let inherited = previous.flatMap { $0.row.sessionId.hasPrefix("process:") ? $0 : nil }
        for old in matches where old.row.sessionId.hasPrefix("process:") && old.row.sessionId != id {
            pass.observations.removeValue(forKey: old.row.sessionId)
            var retired = old; retired.row.status = "superseded"; retired.row.closedAt = pass.now
            pass.changes.append(retired)
            for path in old.paths where pass.checkpoint.owners[path] == old.row.sessionId { pass.checkpoint.owners[path] = id }
        }
        return (id, inherited)
    }

    /// The branch and GitHub repository of the folder the session works in,
    /// read once per folder per pass. Once one git call is held, the rest of
    /// the pass skips git, so a folder prompt nobody has answered costs one
    /// short wait per pass, not one per pane. A held read keeps what was last
    /// seen. A folder outside any repository, or on a detached head, has no
    /// branch (issue #122), and one git may not read has neither. A row this
    /// probe writes always carries `repository`, null when it was never read,
    /// so only an older probe's row lacks the key. The remote is read as
    /// `origin` stores it, before any `insteadOf` rewrites it.
    func readFolder(_ folder: String, into row: inout SessionRow, in pass: inout ProbePass) async {
        row.repositoryRead = true
        if let known = pass.folders[folder] {
            row.branch = known.branch; row.repository = known.repository
            return
        }
        guard !pass.gitHeld else { return }
        guard let real = Self.readable(folder), !Self.gitReachesVolumes(real) else {
            pass.folders[folder] = (nil, nil)
            row.branch = nil; row.repository = nil
            return
        }
        // Kept under both spellings: a link, `.` or `..` to a folder already
        // read this pass reads nothing again. A followed folder has no links,
        // so it never names another folder's spelling.
        if let known = pass.folders[real] {
            pass.folders[folder] = known
            row.branch = known.branch; row.repository = known.repository
            return
        }
        do {
            let branch = try await git(["-C", real, "symbolic-ref", "--short", "HEAD"])
            let remote = try await git(["-C", real, "config", "--local", "--includes", "--get-all", "remote.origin.url"])
            let read = (branch: branch, repository: remote.flatMap(Self.githubRepository))
            pass.folders[folder] = read; pass.folders[real] = read
            row.branch = read.branch; row.repository = read.repository
        } catch {
            pass.gitHeld = true
        }
    }

    /// The folder git may read, with its `..` and links followed, or nil
    /// when it is empty, relative, or under `/Volumes` by its name or through
    /// a link, in any case (issue #135). A mounted volume may be a network
    /// share or a drive macOS asks about, so the probe never reads one, and
    /// nothing under `/Volumes` is looked at to find out: each name is
    /// checked before its link is read. Links that go round give nil too.
    static func readable(_ folder: String) -> String? {
        guard folder.hasPrefix("/"), walk(folder, follow: false) != nil, let real = walk(folder, follow: true) else { return nil }
        return "/" + real.joined(separator: "/")
    }

    /// Whether git, run in `folder`, could open something under `/Volumes`
    /// through the repository's own pointers (issue #141): a `.git` file or
    /// link, `commondir`, an alternates chain, or a config include or
    /// `core.worktree`. Every git folder from `folder` up to `/` is looked
    /// at, more than git would use, and a pointer the probe cannot follow
    /// counts as a volume, so a doubt costs the branch, never a read of a drive.
    static func gitReachesVolumes(_ folder: String) -> Bool {
        var names = folder.split(separator: "/").map(String.init)
        while true {
            let here = "/" + names.joined(separator: "/")
            switch peek((names.isEmpty ? "" : here) + "/.git") {
            case .volume: return true
            case .text(let text):
                guard text.hasPrefix("gitdir:") else { break }
                if gitDirectoryReachesVolumes(resolve(text.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines), against: here)) { return true }
            case .folder(let place): if gitDirectoryReachesVolumes(place) { return true }
            case .missing: break
            }
            if gitDirectoryReachesVolumes(here) { return true }
            if names.isEmpty { return false }
            names.removeLast()
        }
    }

    /// Whether the git folder at `path`, when it is one, points anywhere
    /// under `/Volumes`.
    static func gitDirectoryReachesVolumes(_ path: String) -> Bool {
        let found = peek(path)
        guard case .folder(let gitDir) = found else { return found == .volume }
        switch peek(gitDir + "/HEAD") {
        case .volume: return true
        case .missing: return false
        default: break
        }
        var common = gitDir
        switch peek(gitDir + "/commondir") {
        case .volume: return true
        case .text(let text):
            guard case .folder(let place) = peek(resolve(text.trimmingCharacters(in: .whitespacesAndNewlines), against: gitDir)) else { return true }
            common = place
        default: break
        }
        return configReachesVolumes(common + "/config", depth: 0) || configReachesVolumes(gitDir + "/config.worktree", depth: 0)
            || alternatesReachVolumes(common + "/objects", depth: 0)
    }

    /// Whether a config file, or one it includes, names a path under
    /// `/Volumes` as an include or `core.worktree`. Includes are checked
    /// whatever their condition. A value git would read otherwise than as
    /// written (an escape, a line carried on, quotes inside) is taken as a
    /// volume.
    static func configReachesVolumes(_ file: String, depth: Int) -> Bool {
        switch peek(file) {
        case .volume: return true
        case .text(let text):
            guard depth < 10 else { return true }
            var section = ""
            for raw in text.split(whereSeparator: \.isNewline) {
                var line = Substring(raw.trimmingCharacters(in: .whitespaces))
                if line.hasPrefix("[") {
                    line = line.dropFirst()
                    section = line.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }.lowercased()
                    // git reads a key on the header's own line too.
                    if section.hasPrefix("include"), line.contains("\\") { return true }
                    if let quote = line.firstIndex(of: "\""), quote < (line.firstIndex(of: "]") ?? line.endIndex) {
                        guard let close = line[line.index(after: quote)...].firstIndex(of: "\"") else { continue }
                        line = line[line.index(after: close)...]
                    }
                    guard let close = line.firstIndex(of: "]") else { continue }
                    line = Substring(line[line.index(after: close)...].trimmingCharacters(in: .whitespaces))
                }
                guard let equals = line.firstIndex(of: "=") else { continue }
                let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                guard (section.hasPrefix("include") && key == "path") || (section == "core" && key == "worktree") else { continue }
                var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                if value.contains("\\") { return true }
                if value.hasPrefix("\"") {
                    guard let close = value.dropFirst().firstIndex(of: "\"") else { return true }
                    value = String(value[value.index(after: value.startIndex)..<close])
                } else {
                    value = value.prefix { $0 != "#" && $0 != ";" }.trimmingCharacters(in: .whitespaces)
                }
                if value.contains("\"") { return true }
                if value.hasPrefix("~/") { value = NSHomeDirectory() + value.dropFirst(1) }
                let target = resolve(value, against: (file as NSString).deletingLastPathComponent)
                if peek(target) == .volume || (key == "path" && configReachesVolumes(target, depth: depth + 1)) { return true }
            }
            return false
        default: return false
        }
    }

    /// Whether the objects folder `objects` borrows from one under
    /// `/Volumes`, directly or down a chain as deep as git follows.
    static func alternatesReachVolumes(_ objects: String, depth: Int) -> Bool {
        switch peek(objects + "/info/alternates") {
        case .volume: return true
        case .text(let text):
            guard depth < 5 else { return true }
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                if line.hasPrefix("\"") { return true }
                switch peek(resolve(line, against: objects)) {
                case .volume: return true
                case .folder(let place): if alternatesReachVolumes(place, depth: depth + 1) { return true }
                default: break
                }
            }
            return false
        default: return false
        }
    }

    /// What is at `path`, looked at only once `readable` has cleared every
    /// name and link on the way to it.
    enum Peek: Equatable { case volume, missing, folder(String), text(String) }

    static func peek(_ path: String) -> Peek {
        guard let place = readable(path) else { return .volume }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: place, isDirectory: &isFolder) else { return .missing }
        if isFolder.boolValue { return .folder(place) }
        guard let data = FileManager.default.contents(atPath: place) else { return .missing }
        // git reads bytes; a file that is not UTF-8 could name anything.
        guard let text = String(data: data, encoding: .utf8) else { return .volume }
        return .text(text)
    }

    /// `path` read against `folder` when it is relative.
    static func resolve(_ path: String, against folder: String) -> String {
        path.hasPrefix("/") ? path : folder + "/" + path
    }

    /// The names of `folder` once `.`, `..` and, when `follow` is set, its
    /// links are undone; nil as soon as it would enter a volume.
    static func walk(_ folder: String, follow: Bool) -> [String]? {
        var left = folder.split(separator: "/").map(String.init)
        var names: [String] = []
        var links = 0
        while !left.isEmpty {
            let name = left.removeFirst()
            if name == "." { continue }
            if name == ".." { _ = names.popLast(); continue }
            if isVolumes(names, onDisk: follow) { return nil }
            let next = names + [name]
            if follow, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/" + next.joined(separator: "/")) {
                links += 1
                guard links <= 32 else { return nil }
                left = target.split(separator: "/").map(String.init) + left
                if target.hasPrefix("/") { names = [] }
                continue
            }
            names = next
        }
        return names
    }

    /// Whether `names` is `/Volumes` itself: by its name or the data
    /// volume's path to it, folded for case as the disk folds it, or, once
    /// links are followed, by being the same folder on disk.
    static func isVolumes(_ names: [String], onDisk: Bool) -> Bool {
        func spelled(_ path: [String]) -> Bool {
            names.count == path.count && zip(names, path).allSatisfy { $0.compare($1, options: .caseInsensitive) == .orderedSame }
        }
        if spelled(["Volumes"]) || spelled(["System", "Volumes", "Data", "Volumes"]) { return true }
        guard onDisk, !names.isEmpty, let volumes = Place(URL(fileURLWithPath: "/Volumes")) else { return false }
        return Place(URL(fileURLWithPath: "/" + names.joined(separator: "/"))) == volumes
    }

    /// git's first line, or nil when it says nothing, as it does outside a
    /// repository; throws only when it does not answer in time.
    func git(_ arguments: [String]) async throws -> String? {
        do {
            return try await command("/usr/bin/git", arguments, timeout: Self.gitTimeout).first
        } catch let failure as ProcessFailure where failure == .timedOut(after: Self.gitTimeout) {
            throw failure
        } catch { return nil }
    }

    /// `owner/name` from a github.com remote, as the remote spells it, and
    /// nil for any other host or shape. Only the two names leave the probe,
    /// never the URL, a user name or a token in it, or a path.
    static func githubRepository(remote: String) -> String? {
        var path: Substring
        if let range = remote.range(of: "^([^@/:]+@)?github\\.com:", options: [.regularExpression, .caseInsensitive]) {
            path = remote[range.upperBound...]
        } else if let url = URLComponents(string: remote), let port = ["https": 443, "http": 80, "ssh": 22, "git": 9418][url.scheme?.lowercased() ?? ""],
                  url.host?.lowercased() == "github.com", url.query == nil, url.fragment == nil, url.port == nil || url.port == port {
            path = url.percentEncodedPath.dropFirst()
        } else { return nil }
        if path.hasSuffix("/") { path = path.dropLast() }
        if path.hasSuffix(".git") { path = path.dropLast(4) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil,
              parts[1].range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
              parts[1] != ".", parts[1] != ".." else { return nil }
        return parts.joined(separator: "/")
    }

    /// Codex's `-C` or `--cd`, the last one before `--`, in any of its
    /// spellings and wherever it comes, as Codex takes it. Only git reads
    /// it; nothing from it is published but what git says of the folder.
    static func codexFolder(_ argv: [String]) -> String? {
        var folder: String?
        var index = 1
        while index < argv.count, argv[index] != "--" {
            let arg = argv[index]; index += 1
            if arg == "-C" || arg == "--cd" {
                guard index < argv.count else { break }
                folder = argv[index]; index += 1
            } else if arg.hasPrefix("--cd=") {
                folder = String(arg.dropFirst(5))
            } else if arg.hasPrefix("-C=") {
                folder = String(arg.dropFirst(3))
            } else if arg.hasPrefix("-C"), !arg.hasPrefix("--") {
                folder = String(arg.dropFirst(2))
            }
        }
        return folder
    }

    /// The folder an agent works in: Codex's `-C` or `--cd`, read against its
    /// own folder, else the folder the process runs in. A relative one with
    /// no folder to read it against names none.
    static func folder(argv: [String], cwd: String) -> String {
        guard URL(fileURLWithPath: argv.first ?? "").lastPathComponent == "codex",
              let named = codexFolder(argv), !named.isEmpty else { return cwd }
        if named.hasPrefix("/") { return named }
        // Joined, not standardised: `link/..` is where the link's target's
        // parent is, which only `readable` can tell.
        return cwd.isEmpty ? "" : cwd + "/" + named
    }

    /// Each session this pass did not see: still running beside a session
    /// that was seen (idle), unsure (stale), or gone (closed). A closed one
    /// is read again for anything written as it ended.
    func settleUnseen(in pass: inout ProbePass, rates: RateCard) async {
        for (id, observation) in pass.observations where !pass.alive.contains(id) && observation.row.status != "superseded" {
            var closed = observation
            if closed.row.closedAt == nil {
                let birth = pass.present.contains(closed.row.pane)
                    ? (try? await command("/bin/ps", ["-p", String(closed.pid), "-o", "lstart="]))?.first : nil
                if pass.uncertain.contains(closed.row.pane) {
                    closed.row.stale = true
                } else if birth.map({ Self.start($0) == Self.start(closed.processStart) }) == true {
                    let known = pass.observations.values.contains { pass.alive.contains($0.row.sessionId)
                        && $0.pid == closed.pid && $0.processStart == closed.processStart }
                    if known {
                        closed.row.status = "idle"; closed.row.asOf = pass.now
                        closed.row = refreshed(closed.row, paths: closed.paths, checkpoint: &pass.checkpoint, rates: rates)
                        pass.alive.insert(id)
                    } else { closed.row.stale = true }
                } else {
                    closed.row.status = "closed"; closed.row.closedAt = pass.now
                }
            }
            if closed.row.closedAt != nil {
                closed.row = refreshed(closed.row, paths: closed.paths.filter {
                    pass.checkpoint.owners[$0] == nil || pass.checkpoint.owners[$0] == id
                }, checkpoint: &pass.checkpoint, rates: rates)
                closed.row.asOf = pass.now
            }
            pass.observations[id] = closed
            if closed != observation && closed.row.closedAt == nil && !pass.alive.contains(id) { pass.changes.append(closed) }
        }
    }

    /// Totals for every session `log.json` shows, summed once every file has
    /// been read, so a message two files share counts once.
    func summarizeShown(in pass: inout ProbePass, rates: RateCard) {
        for (id, observation) in pass.observations where observation.row.status != "superseded"
            && (pass.alive.contains(id) || observation.row.closedAt != nil) {
            var observation = observation
            observation.row = summarized(observation.row, paths: observation.paths, checkpoint: &pass.checkpoint, rates: rates)
            pass.observations[id] = observation
            pass.changes.append(observation)
        }
    }

    /// A line is written for a session that changed in more than its seen
    /// time, and for an open one (no `closedAt`) on two more counts that
    /// keep what `asOf` is read for: its ledger time is `seenEvery` old, so
    /// a row that goes stale is dated near when it was last seen, or it was
    /// seen this pass beside a written one of the same process, so the
    /// ledger keeps their order for `adopt`. A closed session's time is set
    /// on every pass and read by nothing, so only a real change writes it.
    /// The ledger commits before the checkpoint, which can be rebuilt.
    func commit(_ pass: inout ProbePass, to ledger: SessionLedger) throws {
        let stored = pass.stored
        func process(_ observation: SessionObservation) -> [String] {
            [String(observation.pid), Self.start(observation.processStart).map { "\($0.timeIntervalSince1970)" }
                ?? observation.processStart, observation.row.pane]
        }
        let changed = Set(pass.changes.filter { change in
            guard let last = stored.rows[change.row.sessionId], last.matches(change) else { return true }
            return change.row.closedAt == nil && change.row.asOf.timeIntervalSince(last.row.asOf) >= Self.seenEvery
        }.map(\.row.sessionId))
        let moved = Set(pass.changes.filter { changed.contains($0.row.sessionId) }.map(process))
        let novel = pass.changes.filter {
            changed.contains($0.row.sessionId)
                || ($0.row.closedAt == nil && $0.row.asOf == pass.now && moved.contains(process($0)))
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
        let kept = pass.staying(recorded)
        let leaving = recorded.filter { kept[$0.key] == nil }
        pass.checkpoint.release(leaving.values, keeping: kept.values)
        for id in leaving.keys { pass.observations[id] = nil }
        do {
            try ledger.compactIfLong(kept, lines: stored.lines + (novel.isEmpty ? 0 : novel.count + 1),
                                     dropping: !leaving.isEmpty)
        }
        catch { PollLog.system("log: the pane ledger could not be compacted") }
        ledger.removeOlderCopies()
        try JSONEncoder().encode(pass.checkpoint).write(to: checkpointFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: checkpointFile.path)
    }

    func refreshed(_ original: SessionRow, paths: [String], checkpoint: inout SessionCheckpoint, rates: RateCard) -> SessionRow {
        var failed = false
        for path in paths.sorted() {
            if let owner = checkpoint.owners[path], owner != original.sessionId { continue }
            checkpoint.owners[path] = original.sessionId
            if !checkpoint.read(path, tool: original.tool, budget: byteBudget) { failed = true }
        }
        // A file read before another of the session dropped a message it
        // passed by reads again now, so the session takes it over this pass.
        for path in paths.sorted() where checkpoint.rescanned.contains(path) && checkpoint.owners[path] == original.sessionId {
            if !checkpoint.read(path, tool: original.tool, budget: byteBudget) { failed = true }
        }
        var row = summarized(original, paths: paths, checkpoint: &checkpoint, rates: rates)
        row.stale = row.stale || failed
        return row
    }

    func summarized(_ original: SessionRow, paths: [String], checkpoint: inout SessionCheckpoint, rates: RateCard) -> SessionRow {
        var row = original
        var models: [String: TokenCounts] = [:]
        var complete = !paths.isEmpty
        var rollouts: [String: [(path: String, tokens: SessionTokens)]] = [:]
        for path in paths.sorted() {
            guard checkpoint.owners[path] == row.sessionId, let tokens = checkpoint.files[path] else { complete = false; continue }
            complete = complete && tokens.complete
            if row.tool == "codex" {
                // As Spend reads them: a file no session names adds nothing.
                if let session = tokens.session { rollouts[session, default: []].append((path, tokens)) }
            } else {
                for (model, counts) in tokens.models { models[model, default: TokenCounts()] += counts }
            }
        }
        let primers = AppPaths.primers(beside: AppPaths.codexPrimer)
        for files in rollouts.values where !files.contains(where: { $0.tokens.cwd.map { AppPaths.isPrimer($0, in: primers) } ?? false }) {
            // A resume continues the file before it, so each is measured from
            // the total the one before it ended on, in the order Spend reads them.
            var entry: [String: Int]?
            for file in files.sorted(by: {
                ($0.tokens.firstToken ?? .distantFuture, URL(fileURLWithPath: $0.path).lastPathComponent, $0.path)
                    < ($1.tokens.firstToken ?? .distantFuture, URL(fileURLWithPath: $1.path).lastPathComponent, $1.path)
            }) {
                guard let step = file.tokens.added(after: entry, url: URL(fileURLWithPath: file.path)) else { complete = false; break }
                for (model, counts) in step.models { models[model, default: TokenCounts()] += counts }
                entry = step.baseline
            }
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

/// What one pass of the probe knows as it goes: the ledger as stored, the
/// sessions and token checkpoint it is updating, and what it has seen. None of
/// it leaves the machine.
struct ProbePass {
    let now: Date
    let stored: SessionLedger.Stored
    var observations: [String: SessionObservation]
    var checkpoint: SessionCheckpoint
    /// Panes herdr listed this pass.
    var present: Set<String> = []
    /// Sessions seen running this pass.
    var alive: Set<String> = []
    /// Panes whose processes could not be told this pass.
    var uncertain: Set<String> = []
    /// Every session this pass touched, for the ledger to sift.
    var changes: [SessionObservation] = []
    var gitHeld = false
    /// What git said of each folder this pass.
    var folders: [String: (branch: String?, repository: String?)] = [:]

    /// `rows` less any session `SessionRetention` retires from the whole
    /// file's budget, the most any caller's share can be. A caller's share
    /// trims only what the probe prints, so a second app with more machines,
    /// and so a smaller share, deletes nothing another caller would show
    /// (issue #131).
    func staying(_ rows: [String: SessionObservation]) -> [String: SessionObservation] {
        SessionRetention.kept(Array(rows), row: { $0.value.row }, now: now, budget: .share(machines: 1))
            .reduce(into: [String: SessionObservation]()) { $0[$1.key] = $1.value }
    }
}

extension MachineProber {
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    public func readLog(_ machine: Machine, budget: SessionRetention.Budget = .share(machines: 1))
        async -> Result<SessionLogFile, ProcessFailure> {
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
            try child.send("\(helper) log-probe\(state) --keep-rows \(budget.rows) --keep-bytes \(budget.bytes)")
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
        } catch where machine.ssh == nil && !FileManager.default.isExecutableFile(
            atPath: home.appendingPathComponent(".local/bin/herdr").path) {
            // The helper ships inside the app, so on this Mac a silent probe
            // with no herdr is herdr's absence, which most strangers have.
            return .failure(ProcessFailure("the Log tab reads agent sessions from herdr, and herdr was not found at ~/.local/bin/herdr"))
        } catch { return .failure(ProcessFailure("the Log probe did not answer; install this version's CLI helper on the machine")) }
    }
}
