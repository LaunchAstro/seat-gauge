import Foundation
import Testing

/// How `seatgauge-cli` answers a command it does not know, run as the built
/// binary as `VersionTests` runs it. A script that mistypes a command must see
/// a failure, and the words must go where a script does not read them as output.
@Suite struct CLIUsageTests {

    struct Ran { let status: Int32; let out: String; let err: String }

    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func run(_ arguments: [String]) throws -> Ran {
        let task = Process()
        task.executableURL = repository.appendingPathComponent(".build/debug/seatgauge-cli")
        task.arguments = arguments
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        try task.run()
        // `waitUntilExit` can miss an exit when called from a task, so poll against a deadline.
        let deadline = Date(timeIntervalSinceNow: 30)
        while task.isRunning, Date() < deadline { usleep(20_000) }
        if task.isRunning { task.terminate() }
        return Ran(status: task.terminationStatus,
                   out: String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                   err: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    @Test("an unknown command prints the usage to stderr and exits 2", arguments: ["frobnicate", "--bogus", "-x"])
    func unknownCommandFails(_ word: String) throws {
        let ran = try Self.run([word])
        #expect(ran.status == 2)
        #expect(ran.out.isEmpty)
        #expect(ran.err.contains("usage: seatgauge-cli"))
        #expect(ran.err.contains(word))
    }

    @Test("no arguments and --help still print the usage to stdout and exit 0", arguments: [[], ["--help"]])
    func helpStaysAsItWas(_ arguments: [String]) throws {
        let ran = try Self.run(arguments)
        #expect(ran.status == 0)
        #expect(ran.out.hasPrefix("usage: seatgauge-cli"))
        #expect(ran.err.isEmpty)
    }
}
