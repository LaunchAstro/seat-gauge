import AppKit
import Foundation
import SwiftUI
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// The ALL card and the row that scrolls sideways when its boxes do not fit.
/// Drawn at the ordinary text step, in one appearance, at one width each side
/// of the row's minimum.
@Suite(.serialized, .sharedMirror) @MainActor struct SeatsRowTests {

    typealias Glance = GlanceFaceTests
    typealias Widths = CardWidthTests
    typealias Hug = HugAndHoverTests

    // MARK: - The ALL card

    @Test func allAveragesTheLiveSeatsThatReportEachWindow() {
        let seats = ["personal", "work", "codex"].map(Glance.codex)
        let model = Glance.panel(seats, [
            [Glance.window(.fiveHour, used: 20, in: 3600), Glance.window(.weekly, used: 10, in: 5 * 86_400)],
            [Glance.window(.fiveHour, used: 60, in: 3600), Glance.window(.weekly, used: 30, in: 5 * 86_400)],
            [Glance.window(.weekly, used: 50, in: 5 * 86_400)],
        ])
        let lines = model.summary?.lines ?? []
        #expect(lines.map(\.name) == ["5H", "WK"])
        // 5H over the two seats that report it; WK over all three.
        #expect(lines.map(\.usedPercent) == [40, 30])
        #expect(model.columns == 4)
    }

    @Test func oneLiveSeatDrawsNoAllCard() {
        let seats = ["personal", "work"].map(Glance.codex)
        let states: [SeatID: SeatState] = [
            seats[0].id: .live(Reading(seat: seats[0].id, windows: [Glance.window(.weekly, used: 30)],
                                       takenAt: Glance.now, plan: nil)),
            seats[1].id: .unreadable(reason: "no login", last: Reading(seat: seats[1].id,
                                                               windows: [Glance.window(.weekly, used: 90)],
                                                               takenAt: Glance.now, plan: nil)),
        ]
        let model = PanelModel.make(snapshot: Snapshot(states: states, order: seats.map(\.id)),
                                    seats: seats, now: Glance.now)
        #expect(model.cards.count == 2)
        #expect(model.summary == nil)
        #expect(model.columns == 2)
    }

    @Test func aCombinedWindowThatRunsDryCountsDownToItsRunOut() throws {
        // Two days into the week and 60% gone on average: dry a little after
        // day three, well before the reset in five days.
        let seats = ["personal", "work"].map(Glance.codex)
        let model = Glance.panel(seats, [
            [Glance.window(.weekly, used: 50, in: 5 * 86_400)],
            [Glance.window(.weekly, used: 70, in: 5 * 86_400)],
        ])
        let summary = try #require(model.summary)
        let weekly = try #require(summary.lines.first)
        #expect(weekly.runsOut)
        #expect(weekly.countdown == "1d 8h")
        #expect(summary.pace?.tone == .amber)

        let calm = Glance.panel(seats, [
            [Glance.window(.weekly, used: 10, in: 5 * 86_400)],
            [Glance.window(.weekly, used: 20, in: 5 * 86_400)],
        ])
        #expect(calm.summary?.lines.first?.runsOut == false)
        #expect(calm.summary?.lines.first?.countdown == "5d 0h")
    }

    @Test func theAllCardDrawsItsVerdictOnlyWhileHovered() throws {
        let was = GaugeMirror.shared.textScale
        defer { GaugeMirror.shared.textScale = was }
        GaugeMirror.shared.textScale = .normal
        let seats = ["personal", "work"].map(Glance.codex)
        func summary(_ used: [Int]) throws -> SummaryModel {
            try #require(Glance.panel(seats, used.map { [Glance.window(.weekly, used: $0, in: 5 * 86_400)] }).summary)
        }
        let fast = try summary([50, 70])
        let slow = SummaryModel(lines: fast.lines, pace: try summary([10, 10]).pace)
        #expect(fast.pace != nil && slow.pace != nil && fast.pace != slow.pace)
        func drawn(_ model: SummaryModel, hovered: Bool) -> Data? {
            // One width for both, so only what is drawn can differ.
            let face = SummaryCard.face(model, showsPace: hovered).frame(width: 320)
                .environment(\.pinnedVerticalFactor, 1)
            return ImageRenderer(content: face).nsImage?.tiffRepresentation
        }
        // No hover, no verdict: two different verdicts draw the same card.
        // Over the card, each draws its own.
        let quiet = try #require(drawn(fast, hovered: false))
        #expect(quiet == drawn(slow, hovered: false))
        let shown = try #require(drawn(fast, hovered: true))
        #expect(shown != drawn(slow, hovered: true))
    }

    @Test func theAllCardsMarkIsOurOwnSparklesInsideTheMarksSquare() {
        let was = GaugeMirror.shared.textScale
        defer { GaugeMirror.shared.textScale = was }
        GaugeMirror.shared.textScale = .normal
        let side = SeatMark.side(TextScale.current)
        let square = CGRect(x: 0, y: 0, width: side, height: side)
        let sparkles = Sparkles().path(in: square).boundingRect
        #expect(!sparkles.isEmpty && square.contains(sparkles))
    }

    // MARK: - The row scrolls sideways

    @Test func allCardTestsDoNotAssertFittingSize() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
        let start = try #require(source.range(of: "// MARK: - The ALL card"))
        let end = try #require(source.range(of: "// MARK: - The row scrolls sideways"))
        let section = source[start.upperBound..<end.lowerBound]
        #expect(!section.contains(".fitting" + "Size"))
    }

    @Test func aRowTooWideScrollsAtTheSameHeight() {
        Widths.atOrdinaryStep { _ in
            let cards = Widths.cards(3)
            let floor = PanelLayout.minimumContentWidth(cards: 3)
            let row = ComboLayout(cards: cards)
            let fits = Self.hosted(row, width: floor)
            let scrolls = Self.hosted(row, width: floor - 120)
            #expect(fits > 0)
            #expect(abs(fits - scrolls) < 1, "\(fits) fitted, \(scrolls) scrolling")
            // When they fit, the row is the row it always was.
            #expect(abs(Hug.height(row, width: floor) - fits) < 1)
        }
    }

    @Test func theWindowCanBeNarrowerThanItsCards() async {
        await TitleBarTests.keepingMirror {
            GaugeMirror.shared.textScale = .normal
            let seats = ["personal", "work", "codex"].map(Glance.codex)
            let states = Dictionary(uniqueKeysWithValues: seats.map {
                ($0.id, SeatState.live(Reading(seat: $0.id, windows: [Glance.window(.weekly, used: 30)],
                                               takenAt: Date(), plan: nil)))
            })
            GaugeMirror.shared.apply(Snapshot(states: states, order: seats.map(\.id)), seats: seats)
            let name = TitleBarTests.freshName()
            defer { TitleBarTests.forget(name) }
            let built = TitleBarTests.controller(name)
            defer { built.window.close() }
            built.show()
            built.refit(.drawn)
            await TitleBarTests.settle()
            // Three seats and the ALL card open side by side, and the window
            // may still be pulled in past them.
            #expect(built.window.contentLayoutRect.width >= PanelLayout.minimumContentWidth(cards: 4) - 0.5)
            #expect(built.window.contentMinSize.width < PanelLayout.minimumContentWidth(cards: 2))
        }
    }

    @Test func firstLaunchScrollsWhenTheRowExceedsTheDisplay() async throws {
        try await TitleBarTests.keepingMirror {
            GaugeMirror.shared.textScale = .normal
            let widest = try #require(NSScreen.screens.map { $0.visibleFrame.width }.max())
            let count = Int(widest / CardMetrics.minimumWidth) + 3
            let now = Date()
            let weekly = SeatGaugeCore.Window(
                kind: .weekly, usedPercent: 30,
                resetsAt: now.addingTimeInterval(5 * 86_400),
                length: .seconds(7 * 86_400))
            let seats = (0..<count).map { Glance.codex("seat-\($0)") }
            let states = Dictionary(uniqueKeysWithValues: seats.map {
                ($0.id, SeatState.live(Reading(
                    seat: $0.id, windows: [weekly], takenAt: now, plan: nil)))
            })
            GaugeMirror.shared.apply(
                Snapshot(states: states, order: seats.map(\.id)), seats: seats)

            let name = TitleBarTests.freshName()
            defer { TitleBarTests.forget(name) }
            let built = TitleBarTests.controller(name)
            defer { built.window.close() }
            built.show()
            built.refit(.drawn)
            await TitleBarTests.settle()
            built.refit()

            let screen = try #require(built.window.screen ?? NSScreen.main)
            #expect(PanelLayout.minimumContentWidth(cards: count + 1) > screen.visibleFrame.width)
            #expect(built.window.frame.width <= screen.visibleFrame.width + 1)
        }
    }

    @Test func aUserNarrowedWindowStaysNarrowAfterRefit() async {
        await TitleBarTests.keepingMirror {
            GaugeMirror.shared.textScale = .normal
            let seats = ["personal", "work", "codex"].map(Glance.codex)
            let now = Date()
            let weekly = SeatGaugeCore.Window(
                kind: .weekly, usedPercent: 30,
                resetsAt: now.addingTimeInterval(5 * 86_400),
                length: .seconds(7 * 86_400))
            let states = Dictionary(uniqueKeysWithValues: seats.map {
                ($0.id, SeatState.live(Reading(
                    seat: $0.id, windows: [weekly], takenAt: now, plan: nil)))
            })
            GaugeMirror.shared.apply(
                Snapshot(states: states, order: seats.map(\.id)), seats: seats)

            let name = TitleBarTests.freshName()
            defer { TitleBarTests.forget(name) }
            let built = TitleBarTests.controller(name)
            defer { built.window.close() }
            built.show()
            built.refit(.drawn)
            await TitleBarTests.settle()

            #expect(!built.restoredSavedFrame)
            let chosenWidth = PanelLayout.minimumContentWidth(cards: 4) - 80
            var frame = built.window.frame
            frame.size.width = chosenWidth
            built.window.setFrame(frame, display: true)
            #expect(abs(built.window.frame.width - chosenWidth) < 1)
            built.refit()
            #expect(abs(built.window.frame.width - chosenWidth) < 1)
        }
    }

    @Test func aWheelTurnScrollsTheRowSideways() throws {
        try Widths.atOrdinaryStep { _ in
            let floor = PanelLayout.minimumContentWidth(cards: 3)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: floor - 120, height: 200),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let host = NSHostingView(rootView: ComboLayout(cards: Widths.cards(3)).environment(\.pinnedVerticalFactor, 1))
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let scroller = try #require(Self.scrollView(in: host))
            let turn = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                            wheel1: -5, wheel2: 0, wheel3: 0))
            let event = try #require(NSEvent(cgEvent: turn))
            let sideways = try #require(WindowController.sideways(event))
            #expect(sideways.scrollingDeltaY == 0 && sideways.scrollingDeltaX != 0)
            #expect(WindowController.sideways(sideways) == nil)
            // A turn as it comes does not move the row; the same turn
            // sideways does, once its smooth scroll has run.
            scroller.scrollWheel(with: event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            #expect(scroller.contentView.bounds.minX == 0)
            scroller.scrollWheel(with: sideways)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            #expect(scroller.contentView.bounds.minX > 0, "\(scroller.contentView.bounds)")
        }
    }

    static func scrollView(in view: NSView) -> NSScrollView? {
        if let found = view as? NSScrollView { return found }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    /// The content's height in a hosting view of this width, as the window
    /// measures it.
    static func hosted<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: view.environment(\.pinnedVerticalFactor, 1)
            .fixedSize(horizontal: false, vertical: true))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 100)
        host.layoutSubtreeIfNeeded()
        return host.intrinsicContentSize.height
    }
}
