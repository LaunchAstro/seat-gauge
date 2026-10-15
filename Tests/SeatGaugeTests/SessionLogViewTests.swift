import AppKit
import Testing
@testable import SeatGauge

@Suite @MainActor struct SessionLogViewTests {
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
