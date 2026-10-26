import AppKit
import SeatGaugeCore
import SwiftUI
import Testing
@testable import SeatGauge

/// `log.json` is reloaded at launch, so a row whose counts sum past `Int.max`
/// used to trap every time the Log tab drew it.
@Suite @MainActor struct LogTokenTotalTests {
    @Test("Sol proof, criterion 6: the Log tab draws a saved row whose token sum passes Int.max")
    func drawsAnOverflowingRow() {
        _ = NSApplication.shared
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var row = SessionRow(machine: "local", sessionId: "session", workspace: "PROJECT-Log-work",
                             pane: "w1:p1", tool: "claude", status: "working", asOf: now)
        row.tokens = TokenCounts(responses: 1, input: .max, output: .max, cacheRead: .max)
        let view = NSHostingView(rootView: LogTab(log: SessionLogFile(updated: now, sessions: [row])))
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 400)
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.height > 0)
    }
}
