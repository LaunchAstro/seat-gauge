import AppKit
import SeatGaugeCore
import SwiftUI
import Testing
@testable import SeatGauge

@Suite(.serialized, .sharedMirror) @MainActor struct SessionLogViewTests {
    @Test func logCannotRaiseTheSharedPanelHeight() {
        _ = NSApplication.shared
        let mirror = GaugeMirror.shared
        let previous = (mirror.textScale, mirror.sessionLog, mirror.tab)
        defer { mirror.textScale = previous.0; mirror.sessionLog = previous.1; mirror.tab = previous.2 }
        mirror.tab = .log
        for scale in [TextScale.smallest, .default, .largest] {
            mirror.textScale = scale
            for width: CGFloat in [360, 760] {
                let measuring = HostingProbe(host: nil) { factor, rows in
                    AnyView(Root().environment(\.pinnedVerticalFactor, factor).environment(\.pinnedCardRows, rows))
                }
                for factor: CGFloat in [1, 3] {
                    mirror.sessionLog = Self.log
                    let before = measuring.contentHeight(at: factor, width: width)
                    mirror.sessionLog.problems = Dictionary(uniqueKeysWithValues: (0..<5).map {
                        ("machine-\($0)", "The Log probe did not answer; install this version's CLI helper on the machine")
                    })
                    let after = measuring.contentHeight(at: factor, width: width)
                    #expect(abs(after - before) < 1)
                }
            }
        }
    }

    private static var log: SessionLogFile {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return SessionLogFile(updated: now, sessions: [SessionRow(machine: "local", sessionId: "session",
            workspace: "PROJECT-Log-work", pane: "w1:p1", tool: "codex", status: "working", asOf: now)])
    }

    @Test func logWheelRemainsVertical() throws {
        let mirror = GaugeMirror.shared
        let previous = mirror.tab
        defer { mirror.tab = previous }
        mirror.tab = .log
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                     wheel1: -5, wheel2: 0, wheel3: 0))
        cg.location = CGPoint(x: 20, y: (NSScreen.screens.first?.frame.height ?? 0) - 20)
        let event = try #require(NSEvent(cgEvent: cg))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 1_000))
        VerticalLists.all.add(scroll)
        #expect(VerticalLists.contain(event))
        #expect(WindowController.overVerticalList(event, in: nil))
    }
}
