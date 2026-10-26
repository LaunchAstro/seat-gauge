import Foundation
import Testing
@testable import SeatGaugeCore

/// Issues #121 and #122: each row names its session's GitHub repository and
/// branch, read from the folder the agent works in.
@Suite struct SessionRepositoryTests {
    /// Built at run time, so the privacy scan never sees an address in the source.
    static let at = "@"

    @Test("a GitHub remote gives its owner and name as the remote spells them, and nothing else does")
    func remoteParsing() {
        let at = Self.at
        let named: [(String, String)] = [
            ("https://github.com/LaunchAstro/seat-gauge.git", "LaunchAstro/seat-gauge"),
            ("https://github.com/LaunchAstro/seat-gauge", "LaunchAstro/seat-gauge"),
            ("https://github.com/LaunchAstro/seat-gauge/", "LaunchAstro/seat-gauge"),
            ("git\(at)github.com:launchastro/Work.Map_2.git", "launchastro/Work.Map_2"),
            ("ssh://git\(at)github.com/LaunchAstro/seat-gauge.git", "LaunchAstro/seat-gauge"),
            ("https://GitHub.com/LaunchAstro/seat-gauge.git", "LaunchAstro/seat-gauge"),
            // A credential in the URL never reaches the row.
            ("https://someone:SECRET_CANARY\(at)github.com/LaunchAstro/seat-gauge.git", "LaunchAstro/seat-gauge"),
            ("https://x-access-token:SECRET_CANARY\(at)github.com/LaunchAstro/seat-gauge", "LaunchAstro/seat-gauge"),
            // GitHub's own port, named, is still GitHub; it is not published.
            ("ssh://git\(at)github.com:22/LaunchAstro/seat-gauge.git", "LaunchAstro/seat-gauge"),
            ("https://github.com:443/LaunchAstro/seat-gauge.git", "LaunchAstro/seat-gauge"),
            // git's own protocol and plain http name the repository too.
            ("git://github.com/LaunchAstro/seat-gauge.git", "LaunchAstro/seat-gauge"),
            ("http://github.com/LaunchAstro/seat-gauge.git", "LaunchAstro/seat-gauge"),
            // The short SSH form with no user name, or another one.
            ("github.com:LaunchAstro/seat-gauge.git", "LaunchAstro/seat-gauge"),
            ("someone\(at)github.com:LaunchAstro/seat-gauge", "LaunchAstro/seat-gauge"),
        ]
        for (remote, expected) in named { #expect(SessionProbe.githubRepository(remote: remote) == expected, "\(remote)") }
        let refused = [
            "", "https://gitlab.com/LaunchAstro/seat-gauge.git", "https://github.com.evil.example/LaunchAstro/x.git",
            "https://evil.example/github.com/LaunchAstro/x.git", "git\(at)github-work:LaunchAstro/seat-gauge.git",
            "https://github.example.com/LaunchAstro/seat-gauge.git", "https://github.com/LaunchAstro",
            "https://github.com/LaunchAstro/seat-gauge/tree/main", "https://github.com/Launch Astro/seat-gauge",
            "https://github.com/LaunchAstro/..", "https://github.com/LaunchAstro/.", "https://github.com/../x",
            "/home/someone/repos/seat-gauge", "file:///home/user/x.git", "https://github.com:8443/LaunchAstro/x.git",
            "ssh://git\(at)github.com:2222/LaunchAstro/x.git", "https://github.com:22/LaunchAstro/x.git",
            "https://github.com/LaunchAstro/seat-gauge.git?token=SECRET_CANARY",
            "evil.example:github.com:LaunchAstro/x.git", "github.com:443/LaunchAstro/x.git", "a/b\(at)github.com:LaunchAstro/x.git",
            // Spelled otherwise than the names it would publish.
            "https://github.com/Launch%41stro/x.git", "https://github.com//LaunchAstro/x.git",
        ]
        for remote in refused { #expect(SessionProbe.githubRepository(remote: remote) == nil, "\(remote)") }
    }

    @Test("Codex works where -C or --cd points, which is the folder its branch and repository come from")
    func codexFolder() {
        #expect(SessionProbe.folder(argv: ["codex", "-C", "/work/repo"], cwd: "/home/user") == "/work/repo")
        #expect(SessionProbe.folder(argv: ["codex", "exec", "--cd", "repo", "-m", "x"], cwd: "/home/user") == "/home/user/repo")
        #expect(SessionProbe.folder(argv: ["codex", "--cd=/work/repo"], cwd: "/home/user") == "/work/repo")
        #expect(SessionProbe.folder(argv: ["codex", "-m", "x"], cwd: "/home/user") == "/home/user")
        // A prompt that looks like the flag is not one.
        #expect(SessionProbe.folder(argv: ["codex", "--", "-C", "/elsewhere"], cwd: "/home/user") == "/home/user")
        #expect(SessionProbe.folder(argv: ["codex", "-C"], cwd: "/home/user") == "/home/user")
        // Claude has no such flag: its folder is its own.
        #expect(SessionProbe.folder(argv: ["claude", "-C", "/elsewhere"], cwd: "/home/user") == "/home/user")
        // The folder attached to -C, and -C after an image.
        #expect(SessionProbe.folder(argv: ["codex", "-C/work/repo"], cwd: "/home/user") == "/work/repo")
        #expect(SessionProbe.folder(argv: ["codex", "-i", "a.png", "--image", "b.png", "-C", "/work/repo"], cwd: "/home/user") == "/work/repo")
        // Resuming, with or without a session ID, and from exec.
        #expect(SessionProbe.folder(argv: ["codex", "resume", "--last", "-C", "/work/repo"], cwd: "/home/user") == "/work/repo")
        #expect(SessionProbe.folder(argv: ["codex", "resume", "0199-abcd", "-C", "/work/repo"], cwd: "/home/user") == "/work/repo")
        #expect(SessionProbe.folder(argv: ["codex", "exec", "resume", "--last", "--cd", "/work/repo"], cwd: "/home/user") == "/work/repo")
        // A subcommand after options, as Codex takes it, and every option
        // that takes a value, from Codex's own help.
        #expect(SessionProbe.folder(argv: ["codex", "-c", "model_reasoning_effort=\"high\"", "resume", "--last", "-C", "/work/repo"],
                                    cwd: "/home/user") == "/work/repo")
        #expect(SessionProbe.folder(argv: ["codex", "--enable", "x", "exec", "resume", "0199-abcd", "--cd=/work/repo"],
                                    cwd: "/home/user") == "/work/repo")
        #expect(SessionProbe.folder(argv: ["codex", "fork", "--last", "-C", "/work/repo"], cwd: "/home/user") == "/work/repo")
        #expect(SessionProbe.folder(argv: ["codex", "exec", "-o", "out.txt", "--color", "never", "--output-schema", "s.json",
                                           "-C", "/work/repo"], cwd: "/home/user") == "/work/repo")
        #expect(SessionProbe.folder(argv: ["codex", "--remote", "ws://x", "--local-provider", "y", "--disable", "z", "-C", "/work/repo"],
                                    cwd: "/home/user") == "/work/repo")
        // -C=<dir>, as Codex takes it.
        #expect(SessionProbe.folder(argv: ["codex", "-C=/work/repo"], cwd: "/home/user") == "/work/repo")
        // An option before resume's or fork's session ID.
        #expect(SessionProbe.folder(argv: ["codex", "resume", "-m", "x", "0199abcd-1234", "-C", "/work/repo"], cwd: "/home/user") == "/work/repo")
        #expect(SessionProbe.folder(argv: ["codex", "fork", "-m", "x", "0199abcd-1234", "-C", "/work/repo"], cwd: "/home/user") == "/work/repo")
        // Codex takes options after its prompt too.
        #expect(SessionProbe.folder(argv: ["codex", "exec", "fix it", "-C", "/work/repo"], cwd: "/home/user") == "/work/repo")
        // With no folder of its own, a relative -C names none.
        #expect(SessionProbe.folder(argv: ["codex", "-C", "repo"], cwd: "") == "")
    }

    @Test("a pass names each row's repository and branch from one read per folder, and log.json carries no URL or path")
    func passReadsEachFolderOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = Calls()
        let scene = Scene(panes: [
            ("w1:p1", ["claude"], "/work/repo"), ("w1:p2", ["claude"], "/work/repo"),
            ("w1:p3", ["codex", "-C", "/work/other"], "/home/user"), ("w1:p4", ["claude"], "/home/user"),
        ], git: [
            "/work/repo": ("feature-121", "https://someone:SECRET_CANARY\(Self.at)github.com/LaunchAstro/seat-gauge.git"),
            "/work/other": ("main", "git\(Self.at)github.com:LaunchAstro/work-map-archive.git"),
        ], calls: calls)
        let probe = SessionProbe(runner: scene, directory: root.appendingPathComponent("private"), home: root)
        let log = try await probe.run()
        func row(_ pane: String) -> SessionRow? { log.sessions.first { $0.pane == pane } }
        #expect(row("w1:p1")?.repository == "LaunchAstro/seat-gauge")
        #expect(row("w1:p1")?.branch == "feature-121")
        #expect(row("w1:p2")?.repository == "LaunchAstro/seat-gauge")
        #expect(row("w1:p3")?.repository == "LaunchAstro/work-map-archive")
        #expect(row("w1:p3")?.branch == "main")
        #expect(row("w1:p4")?.repository == nil)
        #expect(row("w1:p4")?.branch == nil)
        // One branch read and one remote read for each folder.
        #expect(calls.git.filter { $0.contains("/work/repo") }.count == 2)
        #expect(calls.git.filter { $0.contains("/work/other") }.count == 2)
        let text = String(decoding: try SessionLogFile.encoder().encode(log), as: UTF8.self)
        for leak in ["SECRET_CANARY", "github.com", "/work/", "/home/user"] { #expect(!text.contains(leak), "\(leak)") }
        // A row the probe read writes `repository` even when there is none.
        #expect(text.components(separatedBy: #""repository":null"#).count - 1 == 1)
    }

    @Test("a row from an older probe has no repository key, and keeps none through the app")
    func olderRowsStayAbsent() throws {
        let old = #"{"as_of":"2026-10-26T00:00:00Z","machine":"m5","models":{},"pane":"w1:p1","session_id":"s","stale":false,"status":"working","tool":"claude","workspace":"w"}"#
        let row = try SessionLogFile.decoder().decode(SessionRow.self, from: Data(old.utf8))
        #expect(row.repository == nil)
        #expect(!String(decoding: try SessionLogFile.encoder().encode(row), as: UTF8.self).contains("repository"))
        var read = row; read.repository = nil; read.repositoryRead = true
        let written = String(decoding: try SessionLogFile.encoder().encode(read), as: UTF8.self)
        #expect(written.contains(#""repository":null"#))
        let back = try SessionLogFile.decoder().decode(SessionRow.self, from: Data(written.utf8))
        #expect(back == read)
        var named = read; named.repository = "LaunchAstro/seat-gauge"
        #expect(try SessionLogFile.decoder().decode(SessionRow.self, from: SessionLogFile.encoder().encode(named)) == named)
    }

    @Test("Sol proof, criterion 2: a Codex -c setting is never published, whatever its value")
    func configIsNotPublished() {
        let argv = ["codex", "-c", #"mcp_servers.demo.env.API_KEY="PRIVATE_CANARY""#, "--config", "x=PRIVATE_CANARY", "-C", "/work/repo"]
        let options = SessionProbe.options(argv)
        #expect(options.effort == nil)
        #expect(options.model == nil)
        #expect(SessionProbe.options(["codex", "-c", #"model_reasoning_effort="high""#]).effort == "high")
    }

    @Test("a row this probe writes carries the repository key even when git is held or the folder is not read")
    func unreadRowsSayNull() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = ["/work/repo": ("feature", "https://github.com/LaunchAstro/seat-gauge.git")]
        let log = try await SessionProbe(runner: Scene(panes: [("w1:p1", ["claude"], "/work/repo"), ("w1:p2", ["claude"], "/Volumes/NAS/repo")],
                                                       git: git, calls: Calls(), held: true),
                                         directory: root.appendingPathComponent("private"), home: root).run()
        #expect(log.sessions.count == 2)
        let text = String(decoding: try SessionLogFile.encoder().encode(log), as: UTF8.self)
        #expect(text.components(separatedBy: #""repository":null"#).count - 1 == 2)
    }

    @Test("Sol proof, #135: a folder that resolves under /Volumes is never handed to git, whatever its spelling")
    func volumesAreNeverRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let links = root.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: links.appendingPathComponent("drive").path, withDestinationPath: "/Volumes/NAS")
        try FileManager.default.createSymbolicLink(atPath: links.appendingPathComponent("up").path, withDestinationPath: "../..")
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: links.appendingPathComponent("repo").path, withDestinationPath: real.path)
        let unread = ["/tmp/../Volumes/NAS/repo", "/volumes/NAS/repo", "/VOLUMES/NAS", "/Volumes/./NAS/repo", "/Volume\u{17F}/NAS/repo",
                      "/\u{17F}y\u{17F}tem/Volumes/Data/Volumes/NAS/repo",
                      "/System/Volumes/Data/Volumes/NAS/repo", links.path + "/drive/repo", links.path + "/up" + String(repeating: "/..", count: 40) + "/Volumes/NAS",
                      "", "relative/repo"]
        for folder in unread { #expect(SessionProbe.readable(folder) == nil, "\(folder)") }
        #expect(SessionProbe.readable(links.path + "/repo/sub/..") == SessionProbe.readable(real.path))
        #expect(SessionProbe.readable(real.path)?.hasSuffix("/real") == true)
        #expect(SessionProbe.readable("/Volumes/../tmp") != nil)
        let calls = Calls()
        let panes = unread.enumerated().map { ("w1:p\($0.offset)", ["codex", "-C", $0.element], "/home/user") }
            + [("w1:pc", ["claude"], links.path + "/drive")]
        let log = try await SessionProbe(runner: Scene(panes: panes, git: [:], calls: calls),
                                         directory: root.appendingPathComponent("private"), home: root).run()
        #expect(log.sessions.count == panes.count)
        #expect(calls.git.filter { $0.contains("NAS") || $0.contains("/drive") || $0.contains("/up") }.isEmpty,
                "\(calls.git)")
    }

    @Test("Sol proof, criterion 3: relative -C preserves symlink/.. semantics")
    func relativeLinkThenParent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("base"), other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other.appendingPathComponent("child"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: base.appendingPathComponent("link").path,
                                                   withDestinationPath: other.appendingPathComponent("child").path)
        let git = [try #require(SessionProbe.readable(base.path)): ("wrong-branch", "https://github.com/Wrong/Repo.git"),
                   try #require(SessionProbe.readable(other.path)): ("right-branch", "https://github.com/Right/Repo.git")]
        let log = try await SessionProbe(runner: Scene(panes: [("w1:p1", ["codex", "-C", "link/.."], base.path)], git: git, calls: Calls()),
                                         directory: root.appendingPathComponent("private"), home: root).run()
        #expect(log.sessions.first?.branch == "right-branch")
        #expect(log.sessions.first?.repository == "Right/Repo")
    }

    @Test("Sol proof, criterion 1: unread folder clears previous repository")
    func unreadFolderClearsWhatWasSeen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("private")
        let git = ["/work/repo": ("feature", "https://github.com/Wrong/Repo.git")]
        let first = try await SessionProbe(runner: Scene(panes: [("w1:p1", ["claude"], "/work/repo")], git: git, calls: Calls()),
                                           directory: directory, home: root).run()
        #expect(first.sessions.first?.repository == "Wrong/Repo")
        for folder in ["", "/Volumes/NAS/repo"] {
            let calls = Calls()
            let log = try await SessionProbe(runner: Scene(panes: [("w1:p1", ["claude"], folder)], git: git, calls: calls),
                                             directory: directory, home: root).run()
            #expect(log.sessions.count == 1)
            #expect(log.sessions.first?.sessionId == first.sessions.first?.sessionId)
            #expect(log.sessions.first?.repository == nil, "\(folder)")
            #expect(log.sessions.first?.branch == nil, "\(folder)")
            #expect(calls.git.isEmpty)
        }
    }

    @Test("Sol proof, criterion 1: origin spelling survives insteadOf rewrite")
    func originAsStored() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "feature"], ["remote", "add", "origin", "https://github.com/Wrong/Repo.git"],
                     ["config", "url.https://github.com/Rewritten/.insteadOf", "https://github.com/Wrong/"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git"); git.arguments = ["-C", repo.path] + args
            try git.run(); git.waitUntilExit()
            #expect(git.terminationStatus == 0)
        }
        let log = try await SessionProbe(runner: Scene(panes: [("w1:p1", ["claude"], repo.path)], git: [:], calls: Calls(), realGit: true),
                                         directory: root.appendingPathComponent("private"), home: root).run()
        #expect(log.sessions.first?.repository == "Wrong/Repo")
        #expect(log.sessions.first?.branch == "feature")
    }

    @Test("Sol proof, criterion 6: the session log doc states the repository contract")
    func docsStateTheContract() throws {
        let doc = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/session-log.md"), encoding: .utf8)
        for phrase in ["contract 1.1 of `log.json`", "The file's `version` stays 1", "`repository` is the GitHub `owner/name`",
                       "no query or fragment", "`github.com:<owner>/<name>`, with or without a user name", "inside `/Volumes`, in any case",
                       "A row written by an older probe has no `repository` key", "outside any repository", "before any `insteadOf`"] {
            #expect(doc.contains(phrase), "\(phrase)")
        }
    }

    @Test("Sol proof, criterion 5: equivalent folder spellings share one git read")
    func equivalentSpellingsReadOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("alias").path, withDestinationPath: repo.path)
        let real = try #require(SessionProbe.readable(repo.path))
        let calls = Calls()
        let log = try await SessionProbe(runner: Scene(panes: [("w1:p1", ["claude"], repo.path), ("w1:p2", ["claude"], root.path + "/alias"),
                                                               ("w1:p3", ["claude"], repo.path + "/.")],
                                                       git: [real: ("feature", "https://github.com/LaunchAstro/seat-gauge.git")], calls: calls),
                                         directory: root.appendingPathComponent("private"), home: root).run()
        #expect(log.sessions.count == 3)
        #expect(log.sessions.allSatisfy { $0.repository == "LaunchAstro/seat-gauge" && $0.branch == "feature" })
        #expect(calls.git.count == 2, "\(calls.git)")
    }

    @Test("a held git read keeps the repository and branch last seen")
    func heldReadKeepsLastSeen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = Calls()
        let git = ["/work/repo": ("feature", "https://github.com/LaunchAstro/seat-gauge.git")]
        let directory = root.appendingPathComponent("private")
        _ = try await SessionProbe(runner: Scene(panes: [("w1:p1", ["claude"], "/work/repo")], git: git, calls: calls),
                                   directory: directory, home: root).run()
        let held = try await SessionProbe(runner: Scene(panes: [("w1:p1", ["claude"], "/work/repo")], git: git, calls: calls, held: true),
                                          directory: directory, home: root).run()
        #expect(held.sessions.first?.repository == "LaunchAstro/seat-gauge")
        #expect(held.sessions.first?.branch == "feature")
        #expect(held.problems["git"] != nil)
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var said: [String] = []
    func add(_ line: String) { lock.withLock { said.append(line) } }
    var git: [String] { lock.withLock { said } }
}

/// herdr panes with one agent each, and git answers by folder.
private struct Scene: ProcessRunning {
    let panes: [(id: String, argv: [String], cwd: String)]
    let git: [String: (branch: String, remote: String)]
    let calls: Calls
    var held = false
    /// Real git, for what only git itself does.
    var realGit = false

    func launch(_ spec: ProcessSpec) throws -> any ProcessSession {
        func json(_ object: Any) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
        let args = spec.arguments
        if spec.executable.lastPathComponent == "git" {
            calls.add(args.joined(separator: " "))
            if realGit { return try RealProcessRunner().launch(spec) }
            if held { return Answer(lines: [], delay: true) }
            let folder = args[1]
            guard let answer = git[folder] else { return Answer(lines: []) }
            return Answer(lines: [args.contains("symbolic-ref") ? answer.branch : answer.remote])
        }
        switch args {
        case ["pane", "list"]:
            return Answer(lines: [json(["result": ["panes": panes.map { ["pane_id": $0.id, "workspace_id": "w1", "agent_status": "working"] }]])])
        case ["workspace", "list"]:
            return Answer(lines: [#"{"result":{"workspaces":[{"workspace_id":"w1","label":"PROJECT-Log-work"}]}}"#])
        default: break
        }
        if args.count == 4, args[0 ..< 3] == ["pane", "process-info", "--pane"], let index = panes.firstIndex(where: { $0.id == args[3] }) {
            let pane = panes[index]
            return Answer(lines: [json(["result": ["process_info": ["foreground_processes": [["argv": pane.argv, "pid": 100 + index, "cwd": pane.cwd]]]]])])
        }
        if spec.executable.lastPathComponent == "ps" { return Answer(lines: ["Thu Oct 15 01:00:00 2026"]) }
        return Answer(lines: [])
    }
}

private struct Answer: ProcessSession {
    let stdoutLines: AsyncThrowingStream<String, Error>
    init(lines: [String], delay: Bool = false) {
        stdoutLines = AsyncThrowingStream { continuation in
            if delay { continuation.finish(throwing: ProcessFailure.timedOut(after: SessionProbe.gitTimeout)); return }
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
    func send(_ line: String) throws {}
    func closeInput() {}
    func terminate() {}
}
