import Foundation
import Testing

import SeatGaugeCore
@testable import SeatGauge

@Suite @MainActor struct SolSeatOpenRaceProofTests {
    @Test("Sol proof, criterion correctness: overlapping seat failures keep the newer note for its own minute")
    func overlappingFailuresKeepTheNewerMinute() async throws {
        let folder = try SeatOpenPanelTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ready = folder.appendingPathComponent("both-started")
        let work = folder.appendingPathComponent("open-work")
        let codex = folder.appendingPathComponent("open-codex")
        try "#!/bin/sh\nfor attempt in 1 2 3 4 5 6 7 8 9 10; do\n  if [ -f \"$1\" ]; then exit 1; fi\n  sleep 0.1\ndone\nexit 3\n"
            .write(to: work, atomically: true, encoding: .utf8)
        try "#!/bin/sh\ntouch \"$1\"\nsleep 2\nexit 2\n".write(to: codex, atomically: true, encoding: .utf8)
        for script in [work, codex] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        let mirror = SeatOpenPanelTests.mirror([
            SeatOpenPanelTests.seat("work", open: [work.path, ready.path]),
            SeatOpenPanelTests.seat("codex", open: [codex.path, ready.path]),
        ], in: folder)

        // The first child cannot fail until the second click has launched its child.
        let first = mirror.open(SeatID(rawValue: "work"))
        let second = mirror.open(SeatID(rawValue: "codex"))
        await (try #require(first)).value
        #expect(mirror.openProblem == "Open Work: open-work exited with status 1")
        let firstShown = ContinuousClock.now
        // Let the main actor start the queued expiry before dating its deadline.
        try await Task.sleep(for: .milliseconds(200))
        let firstTimerStartedBy = ContinuousClock.now
        await (try #require(second)).value
        let newer = try #require(mirror.openProblem)
        #expect(newer == "Open Codex: open-codex exited with status 2")
        let secondShown = ContinuousClock.now
        try #require(secondShown - firstTimerStartedBy > .seconds(1))
        try await Task.sleep(until: firstTimerStartedBy.advanced(by: .milliseconds(60_500)), clock: .continuous)
        try #require(ContinuousClock.now - firstShown > .seconds(60))
        try #require(ContinuousClock.now - secondShown < .seconds(60))
        #expect(mirror.openProblem == newer,
                "The earlier seat's uncancelled expiry cleared the later seat's note before its minute expired")
    }
}
