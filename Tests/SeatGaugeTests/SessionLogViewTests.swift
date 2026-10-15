import AppKit
import SeatGaugeCore
import SwiftUI
import Testing
@testable import SeatGauge

@Suite(.serialized, .sharedMirror) @MainActor struct SessionLogViewTests {
    @Test func logHeightHasRoomForABottomEdgeDrag() {
        _ = NSApplication.shared
        let mirror = GaugeMirror.shared
        let previous = mirror.textScale
        defer { mirror.textScale = previous }
        for scale in [TextScale.smallest, .default, .largest] {
            mirror.textScale = scale
            for width: CGFloat in [360, 760] {
                let measuring = HostingProbe(host: nil) { factor in
                    AnyView(LogTab(log: Self.log).environment(\.pinnedVerticalFactor, factor))
                }
                let height = PanelHeight(measuring: measuring)
                let fit = height.contentChanged(width: width, room: 2_000)
                let range = fit.range
                #expect(range != nil)
                #expect((range?.upperBound ?? 0) - (range?.lowerBound ?? 0) > 100)
                height.chosen = range.map { ($0.lowerBound + $0.upperBound) / 2 }
                let expanded = height.contentChanged(width: width, room: 2_000)
                #expect(expanded.factor > 1)
                #expect((expanded.lock ?? 0) > (fit.lock ?? 0) + 50)
            }
        }
    }

    @Test func logListFillsItsOfferedHeight() throws {
        _ = NSApplication.shared
        let mirror = GaugeMirror.shared
        let previous = (mirror.textScale, mirror.verticalFactor)
        defer { mirror.textScale = previous.0; mirror.verticalFactor = previous.1 }
        mirror.textScale = .normal
        mirror.verticalFactor = 1
        let host = NSHostingView(rootView: LogTab(log: Self.log))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 540)
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(Self.scroll(in: host))
        #expect(abs(scroll.frame.height - (host.bounds.height - 24)) < 2)
        #expect(abs(scroll.frame.width - (host.bounds.width - 24)) < 2)
    }

    private static var log: SessionLogFile {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return SessionLogFile(updated: now, sessions: [SessionRow(machine: "local", sessionId: "session",
            workspace: "PROJECT-Log-work", pane: "w1:p1", tool: "codex", status: "working", asOf: now)])
    }

    private static func scroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.compactMap { scroll(in: $0) }.first
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
