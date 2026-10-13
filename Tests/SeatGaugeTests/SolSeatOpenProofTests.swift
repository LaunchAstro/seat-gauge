import Foundation
import Testing

import SeatGaugeCore
@testable import SeatGauge

@Suite @MainActor struct SolSeatOpenProofTests {
    @Test("Sol proof, criterion correctness: an older expiry cannot erase a repeated failure")
    func repeatedFailureKeepsItsOwnMinute() async throws {
        let folder = try SeatOpenPanelTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = SeatID(rawValue: "work")
        let mirror = SeatOpenPanelTests.mirror([
            SeatOpenPanelTests.seat("work", open: ["/usr/bin/false"]),
        ], in: folder)
        await mirror.open(id)?.value
        let first = try #require(mirror.openProblem)
        try await Task.sleep(for: .seconds(5))
        await mirror.open(id)?.value
        #expect(mirror.openProblem == first)
        let secondShown = ContinuousClock.now
        try await Task.sleep(for: .seconds(56))
        try #require(ContinuousClock.now - secondShown < .seconds(60))
        #expect(mirror.openProblem == first,
                "The first click's timer cleared the second click's failure before its own minute expired")
    }

    @Test("Sol proof, criterion 4: a permitted multiline label still produces a one-line failure")
    func multilineLabelProducesOneLine() async throws {
        let folder = try SeatOpenPanelTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = try JSONSerialization.data(withJSONObject: ["seats": [[
            "id": "work", "label": "Work\nsecondary", "kind": "codex", "open": ["/usr/bin/false"],
        ]]])
        let seats = try ConfigLoader.decode(data, tokenDirectory: folder, home: folder).seats
        let mirror = SeatOpenPanelTests.mirror(seats, in: folder)
        await mirror.open(SeatID(rawValue: "work"))?.value
        let failure = try #require(mirror.problems.first)
        #expect(!failure.contains(where: { $0.isNewline }),
                "An accepted label inserts a line break before the command's failure reason")
    }

    @Test("Sol proof, criterion 2: NUL argv never launches a different seat")
    func nulArgumentFailsClosed() async throws {
        let folder = try SeatOpenPanelTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("open-seat")
        let saw = folder.appendingPathComponent("selected-seat")
        try "#!/bin/sh\nprintf '%s' \"$1\" > \"$2\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let data = try JSONSerialization.data(withJSONObject: ["seats": [[
            "id": "work", "label": "Work", "kind": "codex",
            "open": [script.path, "work\0codex", saw.path],
        ]]])
        let config = try? ConfigLoader.decode(data, tokenDirectory: folder, home: folder)
        guard let seat = config?.seats.first else { return }
        var failed = false
        do { try await SeatOpener(settle: .seconds(2)).open(seat) } catch { failed = true }
        #expect(failed, "An argv that cannot be represented must fail instead of silently truncating")
        #expect(!FileManager.default.fileExists(atPath: saw.path),
                "The launcher ran with a different seat argument from the one configured")
    }
}
