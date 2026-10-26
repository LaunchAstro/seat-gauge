import Foundation
import Testing

import SeatGaugeCore

/// A relative entry on the PATH the app or `seatgauge-cli` inherited, such as
/// `.` or `bin`, resolves inside whatever folder the child runs in. Run from a
/// downloaded project, that would start the project's own `claude`, so every
/// PATH source keeps its absolute directories only.
@Suite struct InheritedPathTests {
    /// A project folder with a planted program at its top and in its `bin`.
    static func project() throws -> URL {
        let directory = try SearchPathTests.scratch()
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for folder in [directory, bin] {
            _ = try SearchPathTests.script("seatgauge-probe", in: folder, "echo planted")
        }
        return directory
    }

    @Test("a child run from a project never starts the project's program through a relative PATH entry")
    func relativeEntriesNeverReachTheChild() async throws {
        let project = try Self.project()
        defer { try? FileManager.default.removeItem(at: project) }
        let runner = RealProcessRunner(searchPath: SearchPath(shell: nil, home: project.path))

        let session = try runner.launch(ProcessSpec(
            executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["seatgauge-probe"],
            environment: ["PATH": ".:bin::/usr/bin:./bin:/bin"], currentDirectory: project,
            timeout: .seconds(10)))
        var lines: [String] = []
        for try await line in session.stdoutLines { lines.append(line) }
        #expect(!lines.contains("planted"))
    }

    @Test("the inherited PATH keeps its absolute directories, in order, ahead of the search list")
    func joinedKeepsAbsoluteOnly() throws {
        let home = try SearchPathTests.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let joined = SearchPath(shell: nil, home: home.path)
            .joined(after: ".:/usr/bin:bin::./tools:/bin:../up")
            .split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        #expect(joined.prefix(2) == ["/usr/bin", "/bin"])
        #expect(joined.allSatisfy { $0.hasPrefix("/") })
    }

    @Test("the login shell starts with the inherited PATH's absolute directories only")
    func loginShellStartsWithAbsoluteOnly() throws {
        let shell = try #require(LoginShell.user(parent: ["SHELL": "/bin/sh", "PATH": ".:/usr/bin:bin::/bin"]))
        #expect(shell.environment["PATH"] == "/usr/bin:/bin")
    }
}
