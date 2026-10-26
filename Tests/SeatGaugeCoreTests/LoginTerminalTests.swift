import Foundation
import Testing

import SeatGaugeCore

/// `seatgauge-cli login` as a person runs it: the built binary on a terminal
/// of its own, against the fake `claude` `SeatLoginTests` makes. The pasted
/// code is a secret, so the terminal must not echo it, and the terminal must
/// be left echoing however the command ends.
@Suite struct LoginTerminalTests {

    static let binary = AttributionSeedTests.repository.appendingPathComponent(".build/debug/seatgauge-cli")
    static let code = "pasted-code-marker-7731"

    /// A pseudo-terminal echoing as a fresh Terminal window does.
    final class Terminal {
        let master: Int32
        let slave: Int32
        var said = ""

        init() throws {
            var master: Int32 = -1, slave: Int32 = -1
            guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw POSIXError(.EIO) }
            self.master = master
            self.slave = slave
            var settings = termios()
            tcgetattr(slave, &settings)
            settings.c_lflag |= tcflag_t(ECHO | ICANON)
            tcsetattr(slave, TCSANOW, &settings)
        }

        deinit { close(master); close(slave) }

        /// Every setting, compared field by field.
        var settings: [UInt64] {
            var now = termios()
            tcgetattr(slave, &now)
            let cc = withUnsafeBytes(of: now.c_cc) { $0.map { UInt64($0) } }
            return [UInt64(now.c_iflag), UInt64(now.c_oflag), UInt64(now.c_cflag), UInt64(now.c_lflag),
                    UInt64(now.c_ispeed), UInt64(now.c_ospeed)] + cc
        }

        var echoes: Bool {
            var settings = termios()
            tcgetattr(slave, &settings)
            return settings.c_lflag & tcflag_t(ECHO) != 0
        }

        /// Reads what the command printed until `done` holds or 30 s pass.
        @discardableResult
        func read(until done: () -> Bool) -> Bool {
            let deadline = Date(timeIntervalSinceNow: 30)
            var buffer = [UInt8](repeating: 0, count: 4096)
            while Date() < deadline {
                if done() { return true }
                var entry = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
                guard poll(&entry, 1, 50) > 0 else { continue }
                let count = Darwin.read(master, &buffer, buffer.count)
                if count > 0 { said += String(decoding: buffer[..<count], as: UTF8.self) }
            }
            return done()
        }

        func type(_ text: String) {
            _ = text.withCString { Darwin.write(master, $0, strlen($0)) }
        }
    }

    /// The CLI started on `terminal` against one seat signed in through the fake.
    static func start(_ scratch: SeatLoginTests.Scratch, on terminal: Terminal) throws -> Process {
        let seats = scratch.root.appendingPathComponent("seats.json")
        let entry: [String: Any] = ["id": "work", "label": "Work", "kind": "claude",
                                    "profile": scratch.profile("work").path, "login": "own"]
        try JSONSerialization.data(withJSONObject: ["seats": [entry]]).write(to: seats)
        let task = Process()
        task.executableURL = binary
        task.arguments = ["login", "work", seats.path]
        task.environment = scratch.parent.merging(["SHELL": "/bin/sh", "CFFIXED_USER_HOME": scratch.home.path,
                                                   "TERM": "dumb"]) { $1 }
        let handle = FileHandle(fileDescriptor: terminal.slave, closeOnDealloc: false)
        task.standardInput = handle
        task.standardOutput = handle
        task.standardError = handle
        try task.run()
        return task
    }

    static func finish(_ task: Process, _ terminal: Terminal) {
        if !terminal.read(until: { !task.isRunning }) { task.terminate() }
        task.waitUntilExit()
    }

    @Test("the pasted code is not echoed, and the terminal echoes again once signed in")
    func theCodeIsNotEchoed() throws {
        let scratch = try SeatLoginTests.scratch(.accepts(Self.code))
        defer { scratch.remove() }
        let terminal = try Terminal()
        #expect(terminal.echoes)
        let task = try Self.start(scratch, on: terminal)
        #expect(terminal.read { terminal.said.contains("code> ") })
        #expect(!terminal.echoes)
        terminal.type(Self.code + "\n")
        Self.finish(task, terminal)

        #expect(task.terminationStatus == 0)
        #expect(terminal.said.contains("work is signed in"))
        // Compared through a Bool, so a failure never prints the code.
        let echoed = terminal.said.contains(Self.code)
        #expect(!echoed)
        #expect(terminal.echoes)
    }

    @Test("a sign-in that fails after the code leaves the terminal echoing")
    func echoIsBackAfterAFailure() throws {
        let scratch = try SeatLoginTests.scratch(.refuses)
        defer { scratch.remove() }
        let terminal = try Terminal()
        let task = try Self.start(scratch, on: terminal)
        #expect(terminal.read { terminal.said.contains("code> ") })
        terminal.type(Self.code + "\n")
        Self.finish(task, terminal)

        #expect(task.terminationStatus == 1)
        #expect(terminal.echoes)
    }

    @Test("Ctrl-C at the code prompt leaves the terminal echoing and still ends the command by the signal")
    func echoIsBackAfterControlC() throws {
        let scratch = try SeatLoginTests.scratch(.accepts(Self.code))
        defer { scratch.remove() }
        let terminal = try Terminal()
        let task = try Self.start(scratch, on: terminal)
        #expect(terminal.read { terminal.said.contains("code> ") })
        #expect(!terminal.echoes)
        kill(task.processIdentifier, SIGINT)
        Self.finish(task, terminal)

        #expect(task.terminationReason == .uncaughtSignal)
        #expect(task.terminationStatus == SIGINT)
        #expect(terminal.echoes)
    }

    @Test("Sol proof, criterion 1: echo is off before anything invites the paste")
    func echoIsOffBeforeTheInvitation() throws {
        let scratch = try SeatLoginTests.scratch(.accepts(Self.code))
        defer { scratch.remove() }
        let terminal = try Terminal()
        let task = try Self.start(scratch, on: terminal)
        #expect(terminal.read { terminal.said.contains("Open this link") })
        #expect(!terminal.echoes)
        terminal.type(Self.code + "\n")
        Self.finish(task, terminal)
        let echoed = terminal.said.contains(Self.code)
        #expect(!echoed)
        #expect(task.terminationStatus == 0)
    }

    @Test("Sol proof, criterion 2: a sign-in leaves every terminal setting as it found it")
    func everySettingIsPutBack() throws {
        let scratch = try SeatLoginTests.scratch(.accepts(Self.code))
        defer { scratch.remove() }
        let terminal = try Terminal()
        let before = terminal.settings
        let task = try Self.start(scratch, on: terminal)
        #expect(terminal.read { terminal.said.contains("code> ") })
        terminal.type(Self.code + "\n")
        Self.finish(task, terminal)

        #expect(task.terminationStatus == 0)
        #expect(terminal.settings == before)
    }

    /// The deterministic proof of Sol's hide-after-end finding is
    /// `aHideAfterTheEndDoesNothing`; this runs the CLI end to end and
    /// guards the outcome, without forcing the interleaving.
    @Test("a sign-in that fails as the code prompt shows leaves the terminal echoing")
    func aFailureAtThePromptLeavesEcho() throws {
        let scratch = try SeatLoginTests.scratch(.refuses)
        defer { scratch.remove() }
        // A claude that asks for the code and dies at once, so the login ends
        // while the code is still being asked for.
        let claude = scratch.bin.appendingPathComponent("claude")
        try #"""
            #!/bin/sh
            printf 'visit: https://example.test/oauth/authorize?code=true\nPaste code here if prompted > '
            exit 2
            """#.write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        for _ in 0 ..< 10 {
            let terminal = try Terminal()
            let task = try Self.start(scratch, on: terminal)
            Self.finish(task, terminal)
            #expect(task.terminationStatus == 1)
            #expect(terminal.echoes)
        }
    }

    @Test("Sol proof, criterion 2: hiding after the end leaves the terminal as it was found")
    func aHideAfterTheEndDoesNothing() throws {
        let terminal = try Terminal()
        let before = terminal.settings
        let entry = try #require(HiddenEntry(terminal: terminal.slave))
        entry.hide()
        #expect(!terminal.echoes)
        entry.end()
        entry.hide()
        entry.restore()
        #expect(terminal.echoes)
        #expect(terminal.settings == before)
        #expect(HiddenEntry(terminal: -1) == nil)
    }

    @Test("claude auth login and status run in the seat's own profile, not the caller's folder")
    func signInChildrenRunInTheProfile() throws {
        let scratch = try SeatLoginTests.scratch(.accepts("c"))
        defer { scratch.remove() }
        let profile = scratch.profile("work")
        _ = try SeatLoginTests.signIn("work", seats: [SeatLoginTests.seat("work", profile: profile)],
                                      scratch: scratch, code: "c", said: SeatLoginTests.Said())
        let expected = profile.resolvingSymlinksInPath().path
        for call in ["login", "status"] {
            let folder = scratch.read("env-\(call)").split(separator: "\n")
                .first { $0.hasPrefix("PWD=") }.map { String($0.dropFirst(4)) }
            #expect(folder.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == expected, "\(call)")
        }
    }
}
