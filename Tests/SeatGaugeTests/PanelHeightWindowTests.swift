import AppKit
import Foundation
import SwiftUI
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// `PanelHeight` in a built window, beside the module's cases in
/// `PanelHeightTests.swift`.
extension PanelHeightTests {

    // MARK: - A chosen height is a factor inside the range

    @Test func theChosenHeightIsAFactorInsideTheRange() {
        let range = VerticalFit.range
        let height = PanelHeight(measuring: ScriptedMeasure(minimum: 200, slope: 100))

        let resting = height.contentChanged(width: Self.width, room: Self.noCap)
        #expect(resting.factor == 1)
        #expect(resting.lock == 200)

        height.chosen = 300
        let chosen = height.contentChanged(width: Self.width, room: Self.noCap)
        #expect(range.contains(chosen.factor))
        #expect(chosen.factor > 1)
        #expect(abs((chosen.lock ?? 0) - 300) < 1)

        var last: CGFloat = 0
        for value in stride(from: CGFloat(0), through: 3000, by: 7) {
            height.chosen = value
            let fit = height.contentChanged(width: Self.width, room: Self.noCap)
            #expect(range.contains(fit.factor))
            #expect(fit.factor >= last)
            last = fit.factor
        }
        #expect(last == range.upperBound)

        // Walked across and past the range, nothing is under its factor-1 value
        // or over its factor-top one.
        CardWidthTests.atOrdinaryStep { _ in
            let floor = (VerticalFit.meterHeight(1), VerticalFit.rowGap(1), VerticalFit.boxPadding(1))
            let top = (VerticalFit.meterHeight(range.upperBound), VerticalFit.rowGap(range.upperBound),
                       VerticalFit.boxPadding(range.upperBound))
            #expect(floor.0 >= VerticalFit.Base.meter)
            #expect(floor.1 >= 0)
            #expect(floor.2 > 0)
            for factor in stride(from: CGFloat(0), through: 4, by: 0.05) {
                #expect(VerticalFit.meterHeight(factor) >= floor.0)
                #expect(VerticalFit.rowGap(factor) >= floor.1)
                #expect(VerticalFit.boxPadding(factor) >= floor.2)
                #expect(VerticalFit.meterHeight(factor) <= top.0)
                #expect(VerticalFit.rowGap(factor) <= top.1)
                #expect(VerticalFit.boxPadding(factor) <= top.2)
            }
            #expect(top.0 > floor.0)
            #expect(top.1 > floor.1)
        }

        // A built window's height runs from its content minimum up to, and
        // never past, its screen.
        let name = Self.freshName()
        defer { Self.forget(name) }
        let built = Self.controller(name)
        let bounds = built.heightBounds()
        #expect(bounds.lowerBound > 0)
        let screen = built.window.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height ?? .greatestFiniteMagnitude
        #expect(bounds.upperBound <= screen)
    }

    // MARK: - A saved height over the opening one is kept

    @Test func aRestoredHeightOverTheOpeningOneIsChosen() async {
        let over = PanelHeight(measuring: ScriptedMeasure())
        over.restored(savedContent: 201.5, opensAt: 200)
        #expect(over.chosen == 201.5)

        let level = PanelHeight(measuring: ScriptedMeasure())
        level.restored(savedContent: 201, opensAt: 200)
        #expect(level.chosen == nil)

        let under = PanelHeight(measuring: ScriptedMeasure())
        under.restored(savedContent: 150, opensAt: 200)
        #expect(under.chosen == nil)

        // A new window on a saved frame taller than it opens at comes up at
        // the saved height: the controller hands the frame to `PanelHeight`.
        _ = NSApplication.shared
        let mirror = GaugeMirror.shared
        let was = (mirror.textScale, mirror.snapshot, mirror.seats, mirror.verticalFactor, mirror.tab)
        defer {
            mirror.textScale = was.0
            mirror.apply(was.1, seats: was.2)
            mirror.verticalFactor = was.3
            mirror.tab = was.4
        }
        let (seats, snapshot) = Self.populate(now: Date(timeIntervalSince1970: 1_758_500_100))
        mirror.apply(snapshot, seats: seats)
        mirror.textScale = .smallest
        mirror.tab = .seats

        let name = Self.freshName()
        defer { Self.forget(name) }
        let first = Self.controller(name)
        first.show()
        await Self.settle()
        let bounds = first.heightBounds()
        let opens = first.window.contentLayoutRect.height
        #expect(bounds.upperBound - opens > 20)
        let saved = (opens + bounds.upperBound) / 2
        var frame = first.window.frame
        frame.origin.y -= saved - opens
        frame.size.height += saved - opens
        first.window.close()
        let screen = first.window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        UserDefaults.standard.set("\(Int(frame.minX)) \(Int(frame.minY)) \(Int(frame.width)) \(Int(frame.height)) "
            + "\(Int(screen.minX)) \(Int(screen.minY)) \(Int(screen.width)) \(Int(screen.height))",
            forKey: "NSWindow Frame \(name)")

        let restored = Self.controller(name)
        defer { restored.window.close() }
        #expect(restored.restoredSavedFrame)
        #expect(abs((restored.panelHeight.chosen ?? 0) - saved) < 2)
        restored.show()
        restored.refit()
        await Self.settle()
        #expect(abs(restored.window.contentLayoutRect.height - saved) < 2)
    }

    // MARK: - Shared builders

    /// Four seats, each live with a five hour, a weekly and a Fable window, an
    /// account and a plan, and a weekly window part spent so the pace line is
    /// drawn, as `ReopenRefitTests` builds it.
    static func populate(now: Date) -> ([Seat], Snapshot) {
        let kinds: [SeatKind] = [.claude(profileDir: URL(fileURLWithPath: "/tmp/seat-gauge-profile")), .claude(profileDir: URL(fileURLWithPath: "/tmp/seat-gauge-profile")),
                                 .claude(profileDir: URL(fileURLWithPath: "/tmp/seat-gauge-profile")), .codex]
        let names = ["work", "team", "personal", "codex"]
        let plans = ["Max 20x", "Max 5x", "Max 20x", "Pro"]
        var seats: [Seat] = []
        var states: [SeatID: SeatState] = [:]
        for (index, name) in names.enumerated() {
            let seat = Seat(id: SeatID(rawValue: name), label: name.capitalized,
                            kind: kinds[index], account: "seat-\(name)", plan: plans[index])
            seats.append(seat)
            let windows = [
                SeatGaugeCore.Window(kind: .fiveHour, usedPercent: 20 + index * 15,
                                     resetsAt: now.addingTimeInterval(3 * 3600),
                                     length: .seconds(5 * 3600)),
                SeatGaugeCore.Window(kind: .weekly, usedPercent: 30 + index * 10,
                                     resetsAt: now.addingTimeInterval(4 * 86_400),
                                     length: .seconds(7 * 86_400)),
                SeatGaugeCore.Window(kind: .fable, usedPercent: 10 + index * 5,
                                     resetsAt: now.addingTimeInterval(2 * 86_400),
                                     length: .seconds(7 * 86_400)),
            ]
            states[seat.id] = .live(Reading(seat: seat.id, windows: windows,
                                            takenAt: now, plan: plans[index]))
        }
        return (seats, Snapshot(states: states, order: seats.map(\.id)))
    }

    /// Awaited rather than pumped, as `ReopenRefitTests.settle` explains.
    static func settle() async {
        try? await Task.sleep(for: .milliseconds(120))
    }

    /// The range the window's getters give a drag, read back as content
    /// heights, beside the range the shown tab measures at.
    static func rangeMatchesTheTab(_ built: WindowController) -> Bool {
        let chrome = built.window.frame.height - built.window.contentLayoutRect.height
        let shown = built.heightBounds()
        return abs(built.window.minSize.height - chrome - shown.lowerBound) < 1
            && abs(built.window.maxSize.height - chrome - shown.upperBound) < 1
    }
}
