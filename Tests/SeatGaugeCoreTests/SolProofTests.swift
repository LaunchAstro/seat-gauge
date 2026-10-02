import Foundation
import Testing

@testable import SeatGaugeCore

/// Sol's proofs against PR 2 at 84e4e21. Uncommitted, for the orchestrator.
@Suite struct SolProofTests {

    @Test("Sol proof, criterion 5: the existing child-environment case asks the real login shell")
    func solExistingCaseUsesTheRealLoginShell() throws {
        // `aKeyThePanelWasLaunchedWithNeverReachesAChild` builds its fetchers
        // with the default runner, which launches the real CLI path through
        // `SearchPath.shared`, whose shell is the test runner's own SHELL or
        // account shell. Nothing here runs that shell; it only reads which one
        // the existing case would ask.
        let fetcher = ClaudeFetcher(primer: URL(fileURLWithPath: NSTemporaryDirectory()), timeout: .seconds(1),
                                    parent: ["PATH": "/usr/bin:/bin"])
        let runner = try #require(fetcher.runner as? RealProcessRunner)
        #expect(runner.searchPath.shell == nil,
                "an existing test's default runner would ask \(runner.searchPath.shell.map { "\($0)" } ?? "")")
    }

    @Test("Sol proof, criterion 3: a failing profile leaves nothing running")
    func solFailingProfileLeavesNothingRunning() async throws {
        let directory = try SearchPathTests.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.lastPathComponent
        // The profile starts something in the background, as profiles do, and
        // then fails before the command runs.
        let file = try SearchPathTests.shell(in: directory, profile: """
            /bin/sh -c 'sleep 30; : \(marker)' &
            exit 1
            """)

        let path = SearchPathTests.shell(file, home: directory, timeout: .seconds(3)).path()
        #expect(path == nil)

        var left = 1
        for _ in 0 ..< 30 {
            left = SearchPathTests.running(marker)
            if left == 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        // Clean up what this proof started before judging it.
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-9", "-f", marker]
        try? pkill.run()
        pkill.waitUntilExit()
        #expect(left == 0, "\(left) process(es) from a failing profile still running")
    }
}
