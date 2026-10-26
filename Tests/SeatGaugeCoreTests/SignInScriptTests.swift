import Foundation
import Testing

import SeatGaugeCore

/// The app's Sign in opens a one-off script in Terminal that runs
/// `seatgauge-cli login`. Each case runs the script with `/bin/sh` against a
/// fake helper that writes down the arguments it got, one per line.
@Suite struct SignInScriptTests {

    struct Scratch {
        let root: URL
        var helper: URL { root.appendingPathComponent("it's a $(helper)/seatgauge-cli") }
        var args: URL { root.appendingPathComponent("args") }
        var pid: URL { root.appendingPathComponent("pid") }
        var seats: URL { root.appendingPathComponent("seat's file $(x).json") }
        var parent: URL { root.appendingPathComponent("tmp", isDirectory: true) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// `then` is what the fake helper does once it has written its arguments.
    static func scratch(then: String) throws -> Scratch {
        let scratch = Scratch(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-sign-in-\(UUID().uuidString)", isDirectory: true))
        for directory in [scratch.helper.deletingLastPathComponent(), scratch.parent] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("""
        #!/bin/sh
        printf '%s\\n' "$@" > '\(scratch.args.path)'
        echo $$ > '\(scratch.pid.path)'
        \(then)

        """.utf8).write(to: scratch.helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.helper.path)
        return scratch
    }

    /// Run where `in` says, so a `touch` the script let through lands there.
    static func run(_ script: URL, in folder: URL? = nil) throws -> (Process, Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.currentDirectoryURL = folder
        let input = Pipe()
        // A Return sent after the script has gone fails, rather than ending the run.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return (process, input)
    }

    static func appears(_ file: URL, within seconds: Double = 10) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if FileManager.default.fileExists(atPath: file.path) { return true }
            usleep(20_000)
        }
        return false
    }

    static func text(_ file: URL) -> String {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").trimmingCharacters(in: .newlines)
    }

    @Test func theHelperGetsLoginTheSeatAndTheSeatsFileEachAsOneArgument() throws {
        let scratch = try Self.scratch(then: "exit 3")
        defer { scratch.remove() }
        let seat = "it's $(touch pwned) a `b`"
        let written = try SignInScript.write(helper: scratch.helper, seat: seat, seatsFile: scratch.seats,
                                             in: scratch.parent)
        let (process, input) = try Self.run(written.script, in: scratch.root)
        // The login's end is told before the window waits for Return.
        #expect(Self.appears(written.marker))
        #expect(process.isRunning)
        #expect(Self.text(written.marker) == "3")
        try input.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
        process.waitUntilExit()
        #expect(Self.text(scratch.args).components(separatedBy: "\n") == ["login", seat, scratch.seats.path])
        #expect(!FileManager.default.fileExists(atPath: scratch.root.appendingPathComponent("pwned").path))
    }

    @Test func theScriptIsPrivateAndRemovesItselfAsItStarts() throws {
        let scratch = try Self.scratch(then: "exit 0")
        defer { scratch.remove() }
        let written = try SignInScript.write(helper: scratch.helper, seat: "personal", seatsFile: scratch.seats,
                                             in: scratch.parent)
        let mode = { (url: URL) in
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
        }
        #expect(mode(written.folder) == 0o700)
        #expect(mode(written.script) == 0o700)
        #expect(written.marker.deletingLastPathComponent() == written.folder)
        let (process, input) = try Self.run(written.script)
        #expect(Self.appears(written.marker))
        #expect(!FileManager.default.fileExists(atPath: written.script.path))
        #expect(Self.text(written.marker) == "0")
        try input.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
        process.waitUntilExit()
    }

    @Test func aWindowClosedMidLoginStillTellsTheLoginEnded() throws {
        let scratch = try Self.scratch(then: "exec sleep 30")
        defer { scratch.remove() }
        let written = try SignInScript.write(helper: scratch.helper, seat: "personal", seatsFile: scratch.seats,
                                             in: scratch.parent)
        let (process, _) = try Self.run(written.script)
        #expect(Self.appears(scratch.pid))
        let helper = try #require(Int32(Self.text(scratch.pid)))
        // Closing a Terminal window hangs up everything running in it.
        kill(helper, SIGHUP)
        kill(process.processIdentifier, SIGHUP)
        #expect(Self.appears(written.marker))
        #expect(Self.text(written.marker) == "129")
        process.waitUntilExit()
    }

    @Test func theWaitEndsWithTheLoginOrWhenTheScriptNeverRan() throws {
        let scratch = try Self.scratch(then: "exit 0")
        defer { scratch.remove() }
        let unopened = try SignInScript.write(helper: scratch.helper, seat: "personal", seatsFile: scratch.seats,
                                              in: scratch.parent)
        #expect(unopened.wait(start: 0.2, limit: 10, every: 0.02) == .neverStarted)
        let opened = try SignInScript.write(helper: scratch.helper, seat: "personal", seatsFile: scratch.seats,
                                            in: scratch.parent)
        let (process, input) = try Self.run(opened.script)
        #expect(opened.wait(start: 10, limit: 10, every: 0.02) == .ended)
        try input.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
        process.waitUntilExit()
        let refused = try SignInScript.write(helper: scratch.helper, seat: "personal", seatsFile: scratch.seats,
                                             in: scratch.parent)
        try FileManager.default.removeItem(at: refused.folder)
        #expect(refused.wait(start: 10, limit: 10, every: 0.02) == .ended)
    }

    @Test func theWaitGivesUpOnALoginThatOutlivesItsLimit() throws {
        let scratch = try Self.scratch(then: "exec sleep 30")
        defer { scratch.remove() }
        let written = try SignInScript.write(helper: scratch.helper, seat: "personal", seatsFile: scratch.seats,
                                             in: scratch.parent)
        let (process, _) = try Self.run(written.script)
        defer { process.terminate() }
        #expect(Self.appears(scratch.pid))
        #expect(written.wait(start: 10, limit: 0.3, every: 0.02) == .outOfTime)
        if let helper = Int32(Self.text(scratch.pid)) { kill(helper, SIGTERM) }
    }
}
