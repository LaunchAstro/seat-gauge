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
