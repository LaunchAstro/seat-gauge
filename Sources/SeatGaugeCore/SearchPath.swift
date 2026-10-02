import Foundation

/// The user's login shell, asked for its `PATH` and nothing else.
///
/// An app launched at login starts with a bare `PATH`, but the user installed
/// `claude` and `codex` wherever their shell finds them: Intel Homebrew, an npm
/// prefix, volta, nvm. The shell is started as a terminal would start it,
/// login and interactive, since nvm and volta set `PATH` in the interactive
/// profile. It runs in a session of its own, so an interactive shell never
/// takes over the terminal `seatgauge-cli` runs in, and a profile that hangs is
/// killed with everything it started.
public struct LoginShell: Sendable, CustomStringConvertible {
    public let executable: URL
    /// What the shell starts with. Never a seat's token or profile.
    public let environment: [String: String]
    public let timeout: Duration

    public init(executable: URL, environment: [String: String], timeout: Duration = .seconds(3)) {
        self.executable = executable
        self.environment = environment
        self.timeout = timeout
    }

    /// The environment stays out of the description, so a failing test or a
    /// log line never prints it.
    public var description: String { "login shell \(executable.path)" }

    /// The shell the user logs in with: `SHELL`, then the account's own entry.
    /// It starts from the same allowlist as a CLI child, so whatever the
    /// launching shell exported, a seat's token included, never reaches a
    /// profile. `TERM=dumb` keeps prompt themes from drawing.
    public static func user(parent: [String: String] = ProcessInfo.processInfo.environment) -> LoginShell? {
        let account = getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) }
        guard let path = [parent["SHELL"], account].compactMap({ $0 })
            .first(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }
        return LoginShell(executable: URL(fileURLWithPath: path),
                          environment: ChildEnvironment.make(from: parent, setting: ["TERM": "dumb"]))
    }

    /// Fences the answer, since a profile may print anything before or after
    /// it. `printenv` reads the same in every shell, fish included.
    static let marker = "__SEATGAUGE_PATH__"
    static let command = "echo \(marker); /usr/bin/printenv PATH; echo \(marker)"
    /// A profile that prints more than this before answering is not waited on.
    static let most = 1 << 20

    /// The absolute directories on the shell's `PATH`, or nil when the shell
    /// would not start, failed, flooded its output or ran past the timeout.
    public func path() -> [String]? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        let (readEnd, writeEnd) = (fds[0], fds[1])
        defer { close(readEnd) }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A new session has no controlling terminal and is its own process
        // group; only stdin, stdout and stderr reach the shell.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        let file: String = executable.path
        let arguments = [file, "-l", "-i", "-c", Self.command]
        let variables = environment.map { "\($0.key)=\($0.value)" }
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = variables.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, file, &actions, &attributes, argv, envp)
        close(writeEnd)
        guard spawned == 0 else { return nil }

        let answer = read(from: readEnd)
        // The group goes while the shell is unreaped, so its id cannot have
        // been reused, and whether or not the shell already exited, nothing
        // its profile started is left running.
        var status: Int32 = 0
        kill(-pid, SIGKILL)
        waitpid(pid, &status, 0)
        return answer
    }

    /// Reads until the fenced answer arrives, the output ends, it grows past
    /// `most`, or the timeout runs out.
    private func read(from fd: Int32) -> [String]? {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while output.count <= Self.most {
            if let answer = Self.answer(in: output) { return answer }
            let left = clock.now.duration(to: deadline)
            guard left > .zero else { return nil }
            var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let polled = poll(&ready, 1, Int32((left.seconds * 1000).rounded(.up)))
            if polled < 0, errno == EINTR { continue }
            guard polled > 0 else { return nil }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return Self.answer(in: output) }
            output.append(buffer, count: count)
        }
        return nil
    }

    /// The line between the fences, split into its absolute directories. A
    /// relative or empty entry would resolve inside the child's working
    /// directory, so it is dropped.
    static func answer(in output: Data) -> [String]? {
        let text = String(decoding: output, as: UTF8.self)
        guard let open = text.range(of: marker + "\n"),
              let shut = text.range(of: "\n" + marker, range: open.upperBound ..< text.endIndex)
        else { return nil }
        let line = text[open.upperBound ..< shut.lowerBound]
        guard !line.contains("\n") else { return nil }
        return SearchPath.unique(line.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") })
    }
}

/// Where a CLI child looks for `claude` and `codex`: the child's own `PATH`,
/// then the login shell's, then a fixed list of the usual installs, which is
/// all there is when the shell gives no answer. Only `PATH` comes from the
/// shell; the rest of the child's environment is `ChildEnvironment`'s.
public final class SearchPath: @unchecked Sendable {
    /// The fixed list alone: what a runner uses unless it is handed
    /// `loginShell`, so no test runs a real profile by default.
    public static let installs = SearchPath(shell: nil, home: NSHomeDirectory())
    /// The user's login shell, then the fixed list. Only the app and
    /// `seatgauge-cli` ask for it.
    public static let loginShell = SearchPath(shell: LoginShell.user(), home: NSHomeDirectory())

    let shell: LoginShell?
    let home: String
    /// Asked once, on first use, and kept for the life of the process, so a
    /// slow profile costs at most one timeout.
    private let lock = NSLock()
    private var found: [String]?

    public init(shell: LoginShell?, home: String) {
        self.shell = shell
        self.home = home
    }

    public func directories() -> [String] {
        lock.withLock {
            if let found { return found }
            let directories = Self.unique((shell?.path() ?? []) + fixed())
            found = directories
            return directories
        }
    }

    /// `path` first, so a caller that sets one keeps its order.
    public func joined(after path: String?) -> String {
        let own = path.map { $0.split(separator: ":").map(String.init) } ?? []
        return Self.unique(own + directories()).joined(separator: ":")
    }

    /// Homebrew on Apple silicon and on Intel (where npm's global prefix also
    /// lands), the native installer, Claude's local install, a user npm
    /// prefix, volta, bun, and each nvm Node, newest first.
    func fixed() -> [String] {
        let node = home + "/.nvm/versions/node"
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: node)) ?? [])
            .filter { version in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: node + "/" + version, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        return ["/opt/homebrew/bin", "/usr/local/bin"]
            + ["/.local/bin", "/.claude/local", "/.npm-global/bin", "/.volta/bin", "/.bun/bin"].map { home + $0 }
            + versions.map { node + "/" + $0 + "/bin" }
    }

    static func unique(_ entries: [String]) -> [String] {
        var seen = Set<String>()
        return entries.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
