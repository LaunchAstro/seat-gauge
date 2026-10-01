import Foundation
import Testing

import SeatGaugeCore

/// Where a CLI child looks for `claude` and `codex`: the login shell's PATH,
/// asked once, then a fixed list. Every case hands in an invented shell, a
/// `/bin/sh` script, so the real login shell and its profile are never run.
@Suite struct SearchPathTests {

    /// A folder of its own per case, so cases never share a shell or a count.
    static func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("seat-gauge-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// An executable script at `name` in `directory`.
    static func script(_ name: String, in directory: URL, _ body: String) throws -> URL {
        let file = directory.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    /// A stand-in login shell. `profile` runs first, as a real profile would,
    /// then the command the shell was handed (its last argument), then `after`.
    static func shell(in directory: URL, profile: String, after: String = "") throws -> URL {
        try script("fake-shell", in: directory, """
            printf '%s\\n' "$*" >> "\(directory.path)/asked"
            \(profile)
            for last; do :; done
            eval "$last"
            \(after)
            """)
    }

    static func shell(_ file: URL, home: URL, timeout: Duration = .seconds(5)) -> LoginShell {
        LoginShell(executable: file, environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"],
                   timeout: timeout)
    }

    /// How many processes `pgrep -f` finds carrying the marker.
    static func running(_ marker: String) -> Int {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", marker]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return -1 }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()
        return out.split(separator: "\n").count
    }

    // MARK: - Asking the login shell

    @Test("the login shell's PATH comes through a noisy profile, absolute entries only")
    func noisyProfile() throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.shell(in: directory, profile: """
            echo "Last login: a banner the profile prints"
            printf 'a prompt theme with no newline'
            export PATH="/invented/npm-global/bin:relative/bin::.:/invented/npm-global/bin:/usr/bin:/bin"
            """, after: "echo 'a logout hook that talks'")

        let path = Self.shell(file, home: directory).path()
        #expect(path == ["/invented/npm-global/bin", "/usr/bin", "/bin"])
        // Asked as a login shell, and an interactive one, since that is the
        // shell a terminal opens and where nvm and volta set PATH.
        let asked = try String(contentsOf: directory.appendingPathComponent("asked"), encoding: .utf8)
        #expect(asked.hasPrefix("-l -i -c "))
    }

    @Test("a profile that hangs is given up on at the timeout and leaves nothing running")
    func hangingProfile() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The directory name is in the argv of the shell and of the child it
        // starts, so pgrep finds both.
        let file = try Self.shell(in: directory, profile: """
            /bin/sh -c 'sleep 30; : \(directory.lastPathComponent)' &
            sleep 30
            """)

        let started = ContinuousClock.now
        let path = Self.shell(file, home: directory, timeout: .milliseconds(300)).path()
        #expect(path == nil)
        #expect(ContinuousClock.now - started < .seconds(3))

        var left = 1
        for _ in 0 ..< 30 {
            left = Self.running(directory.lastPathComponent)
            if left == 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(left == 0)
    }

    @Test("a shell that fails, or floods its output before answering, gives no PATH")
    func noAnswer() throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failing = try Self.shell(in: directory, profile: "exit 1")
        #expect(Self.shell(failing, home: directory).path() == nil)

        let flood = try Self.script("flood-shell", in: directory, """
            head -c 3000000 /dev/zero | tr '\\000' x
            for last; do :; done
            eval "$last"
            """)
        #expect(Self.shell(flood, home: directory).path() == nil)
    }

    @Test("the shell starts from the allowlist, so no seat's token or profile reaches it")
    func shellEnvironmentIsAllowlisted() throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.shell(in: directory, profile: """
            export PATH="/seen-token-${CLAUDE_CODE_OAUTH_TOKEN:-none}:/seen-dir-${CLAUDE_CONFIG_DIR:-none}:/seen-key-${ANTHROPIC_API_KEY:-none}:$PATH"
            """)
        let parent = ["SHELL": file.path, "HOME": directory.path, "PATH": "/usr/bin:/bin",
                      "CLAUDE_CODE_OAUTH_TOKEN": "planted-token-marker",
                      "CLAUDE_CONFIG_DIR": "/invented/another-seat",
                      "ANTHROPIC_API_KEY": "planted-key-marker"]
        let shell = try #require(LoginShell.user(parent: parent))
        #expect(shell.executable == file)
        let path = try #require(shell.path())
        #expect(path.prefix(3) == ["/seen-token-none", "/seen-dir-none", "/seen-key-none"])

        // A SHELL that is not an absolute path is never run as one.
        let relative = LoginShell.user(parent: ["SHELL": "fake-shell", "HOME": directory.path])
        #expect(relative?.executable.path.hasPrefix("/") ?? true)
    }

    // MARK: - The runner's PATH

    @Test("a CLI only the login shell knows about is found, and the shell is asked once")
    func runnerFindsTheShellsCLI() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bin = directory.appendingPathComponent("only-the-shell-knows", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        _ = try Self.script("seatgauge-probe", in: bin,
                            #"echo "found ${PLANTED_BY_PROFILE:-clean}""#)
        let file = try Self.shell(in: directory, profile: """
            export PLANTED_BY_PROFILE=leaked
            export PATH="\(bin.path):$PATH"
            """)
        let runner = RealProcessRunner(searchPath: SearchPath(shell: Self.shell(file, home: directory),
                                                              home: directory.path))

        for _ in 0 ..< 2 {
            let session = try runner.launch(ProcessSpec(
                executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["seatgauge-probe"],
                environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(10)))
            var lines: [String] = []
            for try await line in session.stdoutLines { lines.append(line) }
            // Found, and nothing but PATH came over from the profile.
            #expect(lines == ["found clean"])
        }
        let asked = try String(contentsOf: directory.appendingPathComponent("asked"), encoding: .utf8)
        #expect(asked.split(separator: "\n").count == 1)
    }

    @Test("with no answer, the fixed list covers the usual installs, nvm newest first")
    func fixedList() throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let node = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        for version in ["v9.11.2", "v22.3.0", "v20.10.0"] {
            try FileManager.default.createDirectory(
                at: node.appendingPathComponent("\(version)/bin"), withIntermediateDirectories: true)
        }
        try Data().write(to: node.appendingPathComponent("not-a-version"))

        let search = SearchPath(shell: nil, home: home.path)
        let h = home.path
        #expect(search.directories() == [
            "/opt/homebrew/bin", "/usr/local/bin",
            h + "/.local/bin", h + "/.claude/local", h + "/.npm-global/bin",
            h + "/.volta/bin", h + "/.bun/bin",
            h + "/.nvm/versions/node/v22.3.0/bin", h + "/.nvm/versions/node/v20.10.0/bin",
            h + "/.nvm/versions/node/v9.11.2/bin",
        ])
        // The child's own PATH stays first, and nothing is listed twice.
        let joined = search.joined(after: "/usr/bin:/opt/homebrew/bin").split(separator: ":")
        #expect(joined.prefix(3) == ["/usr/bin", "/opt/homebrew/bin", "/usr/local/bin"])
        #expect(Set(joined).count == joined.count)
    }
}
