import AppKit
import Foundation
import SwiftUI
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// One envelope for both tabs. Every case builds a real window over `Root`
/// under an autosave name of its own, with the four seats
/// `PanelHeightTests.populate` makes, and puts the mirror back after.
@Suite(.serialized, .sharedMirror) @MainActor struct EnvelopeTests {

    typealias Height = PanelHeightTests
    typealias Ordinary = WindowTests
    typealias Widths = CardWidthTests

    static let now = Date(timeIntervalSince1970: 1_758_500_100)

    /// The mirror as a case found it, put back by `restore`.
    static func populated(cards: Int = 4) -> () -> Void {
        let mirror = GaugeMirror.shared
        let was = (mirror.textScale, mirror.snapshot, mirror.seats, mirror.verticalFactor, mirror.tab)
        let (seats, snapshot) = Height.populate(now: now)
        let kept = Array(snapshot.order.prefix(cards))
        mirror.apply(Snapshot(states: snapshot.states.filter { kept.contains($0.key) }, order: kept), seats: seats)
        mirror.textScale = .smallest
        mirror.tab = .seats
        return {
            mirror.textScale = was.0
            mirror.apply(was.1, seats: was.2)
            mirror.verticalFactor = was.3
            mirror.tab = was.4
            mirror.hover(nil)
        }
    }

    /// The Seats and the Spend content at a width, at factor 1, in points.
    static func contents(width: CGFloat) -> (seats: CGFloat, spend: CGFloat) {
        let mirror = GaugeMirror.shared
        let model = mirror.model(at: now)
        let seats = Widths.render(ComboLayout(cards: model.cards, details: model.details)
            .environment(\.pinnedVerticalFactor, 1), width: width)?.height ?? 0
        let spend = Widths.render(SpendTab(chart: mirror.chart).fixedSize(horizontal: false, vertical: true),
                                  width: width)?.height ?? 0
        return (CGFloat(seats) / Widths.scale, CGFloat(spend) / Widths.scale)
    }

    // MARK: - One envelope

    @Test func theWindowIsTheTallerTabOnEitherTab() async throws {
        for cards in [1, 4] {
            let restore = Self.populated(cards: cards)
            defer { restore() }
            do {
                let name = Height.freshName()
                defer { Height.forget(name) }
                let built = Height.controller(name)
                defer { built.window.close() }
                built.show()
                await Height.settle()
                var heights: [CGFloat] = []
                for tab in [Tab.seats, .spend, .seats] {
                    GaugeMirror.shared.tab = tab
                    await Height.settle()
                    heights.append(built.window.contentLayoutRect.height)
                }
                let (seats, spend) = Self.contents(width: built.window.contentLayoutRect.width)
                #expect(heights.allSatisfy { abs($0 - heights[0]) < 0.5 }, "\(cards) cards: \(heights)")
                #expect(abs(heights[0] - max(seats, spend)) <= 1,
                        "\(cards) cards: \(heights[0]) against seats \(seats), spend \(spend)")
            }
        }
    }

    // MARK: - Fails closed: a tab switch never moves the frame

    @Test func aTabSwitchNeverMovesTheFrameAndAMissingFileSaysSo() async throws {
        let restore = Self.populated()
        defer { restore() }
        let name = Height.freshName()
        defer { Height.forget(name) }
        let built = Height.controller(name)
        defer { built.window.close() }
        built.show()
        await Height.settle()
        let frame = built.window.frame
        let locked = (built.window.contentMinSize.height, built.window.contentMaxSize.height)
        for tab in [Tab.spend, .seats, .spend] {
            GaugeMirror.shared.tab = tab
            await Height.settle()
            #expect(built.window.frame == frame, "\(tab)")
            #expect(built.window.contentMinSize.height == locked.0 && built.window.contentMaxSize.height == locked.1)
            #expect(built.window.contentMaxSize.width > built.window.contentMinSize.width)
        }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-envelope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = SpendChart.read(csv: directory.appendingPathComponent("spend.csv"),
                                      rates: .bundled, now: Self.now, calendar: SeatHistoryTests.utc)
        #expect(missing.series.isEmpty)
        #expect(missing.isEmpty)
        #expect(missing.emptyMessage != nil)
    }

    // MARK: - Opens at the envelope, and a saved frame fits or is refused

    @Test func theWindowOpensAtTheEnvelope() {
        let restore = Self.populated()
        defer { restore() }
        let name = Ordinary.freshName()
        defer { Ordinary.forget(name) }
        let fresh = Ordinary.controller(name)
        defer { fresh.window.close() }
        #expect(fresh.contentHeight > 0)
        #expect(abs(fresh.window.contentLayoutRect.height - fresh.contentHeight) < 1)
        let (seats, spend) = Self.contents(width: fresh.window.contentLayoutRect.width)
        #expect(abs(fresh.window.contentLayoutRect.height - max(seats, spend)) <= 1)

        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let saved = CGRect(x: screen.minX + 60, y: screen.minY + 60,
                           width: 640, height: fresh.contentHeight + 220)
        let again = Ordinary.freshName()
        defer { Ordinary.forget(again) }
        Ordinary.seed(saved, under: again, screen: screen)
        let restored = Ordinary.controller(again)
        defer { restored.window.close() }
        #expect(restored.restoredSavedFrame)
        #expect(restored.window.frame.width == saved.width)
        #expect(restored.window.frame.minX == saved.minX)
        #expect(restored.window.frame.maxY == saved.maxY)
        #expect(abs(restored.window.contentLayoutRect.height - restored.contentHeight) < 1)
    }

    // MARK: - The chosen height against the envelope

    @Test func theChosenHeightIsReadAgainstTheEnvelope() async {
        let restore = Self.populated()
        defer { restore() }
        let reference = Height.controller(Height.freshName())
        reference.show()
        await Height.settle()
        let envelope = reference.window.contentLayoutRect.height
        let chrome = reference.window.frame.height - envelope
        let bounds = reference.heightBounds()
        reference.window.close()
        #expect(bounds.upperBound - envelope > 60)

        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        for (content, kept) in [(envelope - 30, false), (envelope + 40, true)] {
            let name = Height.freshName()
            defer { Height.forget(name) }
            Ordinary.seed(CGRect(x: screen.minX + 60, y: screen.minY + 60, width: 640, height: content + chrome),
                          under: name, screen: screen)
            let built = Height.controller(name)
            defer { built.window.close() }
            #expect(built.restoredSavedFrame)
            #expect((built.panelHeight.chosen != nil) == kept, "saved \(content) against \(envelope)")
            built.show()
            built.refit()
            await Height.settle()
            #expect(abs(built.window.contentLayoutRect.height - (kept ? content : envelope)) < 2,
                    "saved \(content) against \(envelope)")
        }

        let name = Height.freshName()
        defer { Height.forget(name) }
        let built = Height.controller(name)
        defer { built.window.close() }
        built.show()
        built.panelHeight.chosen = 100_000
        built.refit()
        await Height.settle()
        #expect(abs(built.window.contentLayoutRect.height - built.heightBounds().upperBound) < 2)
        #expect(built.window.frame.height <= (built.window.screen?.visibleFrame.height ?? screen.height) + 1)
    }

    // MARK: - The live window keeps the chosen height

    @Test func theLiveWindowKeepsTheChosenHeightOnEitherTab() async {
        _ = NSApplication.shared
        for window in NSApplication.shared.windows { window.close() }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-envelope-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StateStore(file: directory.appendingPathComponent("state.json"))
        let restore = Self.populated()
        defer { restore() }
        let mirror = GaugeMirror.shared
        let seats = mirror.seats

        let name = Height.freshName()
        defer { Height.forget(name) }
        let built = Height.controller(name)
        let delegate = SeatGaugeDelegate(controller: built, store: store)
        defer { built.window.close() }
        built.show()
        await Height.settle()
        #expect(mirror.model(at: Self.now).cards.count == 4)

        let bounds = built.heightBounds()
        #expect(bounds.upperBound - bounds.lowerBound > 20)
        let chosen = (bounds.lowerBound + bounds.upperBound) / 2
        built.panelHeight.chosen = chosen
        built.refit()
        await Height.settle()
        #expect(abs(built.window.contentLayoutRect.height - chosen) < 2)
        #expect(abs(built.window.contentLayoutRect.height - built.contentHeight) < 1)
        #expect(GaugeMirror.shared.verticalFactor > VerticalFit.range.lowerBound)

        let frame = built.window.frame, content = built.contentHeight, range = built.heightBounds()
        for hovered in [seats[3].id, seats[0].id, nil] {
            mirror.hover(hovered)
            await Height.settle()
            #expect(built.window.frame == frame, "hovering \(hovered?.rawValue ?? "nothing")")
            #expect(abs(built.contentHeight - content) < 0.5)
        }
        for tab in [Tab.spend, .seats] {
            mirror.tab = tab
            await Height.settle()
            #expect(built.window.frame == frame, "\(tab)")
            #expect(abs(built.contentHeight - content) < 0.5)
            #expect(built.heightBounds() == range)
            #expect(Height.rangeMatchesTheTab(built))
        }

        built.window.close()
        _ = delegate.applicationShouldHandleReopen(.shared, hasVisibleWindows: false)
        await Height.settle()
        #expect(abs(built.window.contentLayoutRect.height - chosen) < 2)

        for _ in TextScale.steps where built.heightBounds().lowerBound <= chosen + 1 {
            delegate.increaseTextSize(nil)
            await Height.settle()
        }
        let raised = built.heightBounds().lowerBound
        #expect(raised > chosen + 1)
        #expect(abs(built.window.contentLayoutRect.height - raised) < 1)
        #expect(abs(built.window.contentLayoutRect.height - built.contentHeight) < 1)
        #expect(GaugeMirror.shared.verticalFactor == VerticalFit.range.lowerBound)
    }
}
