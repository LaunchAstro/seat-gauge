import AppKit
import Foundation
import SwiftUI
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// The content as a table: the height at factor 1, rising in a straight line
/// with the factor, and any width and factor the table names answered from
/// it, so two widths can differ at the same moment. Every question is logged,
/// so a case can read what was measured and at what width.
@MainActor final class ScriptedMeasure: ContentMeasuring {
    var minimum: CGFloat
    var slope: CGFloat
    var table: [CGFloat: [CGFloat: CGFloat]] = [:]
    var calls: [(factor: CGFloat, width: CGFloat)] = []

    init(minimum: CGFloat = 200, slope: CGFloat = 100) {
        self.minimum = minimum
        self.slope = slope
    }

    func contentHeight(at factor: CGFloat, width: CGFloat) -> CGFloat {
        calls.append((factor, width))
        return table[width]?[factor] ?? minimum + (factor - 1) * slope
    }
}

/// `PanelHeight` run against the script, with no window. The cases that need
/// the controller and a real window are in `PanelHeightWindowTests.swift`.
@Suite(.sharedMirror) @MainActor struct PanelHeightTests {

    static let width: CGFloat = 400
    static let noCap = CGFloat.greatestFiniteMagnitude

    static func freshName() -> String { "SeatGaugePanelHeightTest-\(UUID().uuidString)" }

    static func forget(_ name: String) {
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)")
    }

    static func controller(_ name: String) -> WindowController {
        _ = NSApplication.shared
        return WindowController(autosaveName: name, rootView: Root())
    }

    // MARK: - The screen's room caps the range

    @Test func theScreensRoomCapsTheRange() {
        // Factor 1 is 200 and factor 3 is 400; the room is under the top.
        let short = PanelHeight(measuring: ScriptedMeasure(minimum: 200, slope: 100))
        #expect(short.contentChanged(width: Self.width, room: 300).range == 200...300)
        short.chosen = 1000
        let capped = short.contentChanged(width: Self.width, room: 300)
        #expect(abs((capped.lock ?? 0) - 300) < 1)
        #expect(capped.range == 200...300)

        // The room is under factor 1: the range is that height alone.
        let tiny = PanelHeight(measuring: ScriptedMeasure(minimum: 200, slope: 100))
        #expect(tiny.contentChanged(width: Self.width, room: 150).range == 200...200)

        // A content change and a drag start agree on the range.
        for room in [CGFloat(150), 300, 360, Self.noCap] {
            let height = PanelHeight(measuring: ScriptedMeasure(minimum: 200, slope: 100))
            height.chosen = 280
            let changed = height.contentChanged(width: Self.width, room: room)
            let started = height.dragStarted(width: Self.width, room: room)
            #expect(changed.range != nil)
            #expect(changed.range == started.range)
        }
    }

    // MARK: - The chosen height holds until the minimum passes it

    @Test func theChosenHeightHoldsUntilTheMinimumPassesIt() {
        let script = ScriptedMeasure(minimum: 200, slope: 100)
        let height = PanelHeight(measuring: script)
        height.chosen = 330
        var passed = false
        // Each step of the climb raises both ends, as a bigger text size does.
        for step in 0..<12 {
            script.minimum = 200 + CGFloat(step) * 20
            script.slope = 100 + CGFloat(step) * 10
            let fit = height.contentChanged(width: Self.width, room: Self.noCap)
            if script.minimum <= 330 {
                #expect(abs((fit.lock ?? 0) - 330) < 1, "step \(step)")
            } else {
                passed = true
                #expect(fit.factor == 1, "step \(step)")
                #expect(fit.lock == script.minimum, "step \(step)")
            }
        }
        #expect(passed)
        #expect(height.chosen == 330)
    }

    // MARK: - The factor holds still until a drag ends

    @Test func theFactorHoldsStillUntilADragEnds() {
        let script = ScriptedMeasure(minimum: 200, slope: 100)
        let height = PanelHeight(measuring: script)
        height.chosen = 300
        let before = height.contentChanged(width: Self.width, room: Self.noCap)
        #expect(before.factor > 1)

        script.calls.removeAll()
        let started = height.dragStarted(width: Self.width, room: Self.noCap)
        #expect(!script.calls.isEmpty)
        #expect(script.calls.allSatisfy { $0.width == Self.width })
        #expect(started.factor == before.factor)

        let measured = script.calls.count
        let same = height.dragStepped(width: Self.width, room: Self.noCap)
        #expect(script.calls.count == measured)
        #expect(same.factor == before.factor)

        // A new width is measured at that width, and the factor still waits.
        script.table = [460: [1: 240, 3: 440]]
        let wider = height.dragStepped(width: 460, room: Self.noCap)
        #expect(script.calls.count > measured)
        #expect(script.calls.dropFirst(measured).allSatisfy { $0.width == 460 })
        #expect(wider.factor == before.factor)
        #expect(wider.range == 240...440)
        script.table = [:]

        let ended = height.dragEnded(shown: 350, width: 460, room: Self.noCap)
        #expect(height.chosen == 350)
        #expect(abs((ended.lock ?? 0) - 350) < 1)
        #expect(ended == height.contentChanged(width: 460, room: Self.noCap))

        // The content changes mid-drag at the same width: the range and the
        // bounds held open follow it, and the factor waits for the drag's end.
        let moving = ScriptedMeasure(minimum: 200, slope: 100)
        let held = PanelHeight(measuring: moving)
        held.chosen = 300
        #expect(held.contentChanged(width: Self.width, room: Self.noCap).factor == 2)
        #expect(held.dragStarted(width: Self.width, room: Self.noCap).factor == 2)
        moving.minimum = 250
        let changed = held.contentChanged(width: Self.width, room: Self.noCap)
        #expect(changed == HeightFit(factor: 2, lock: nil, range: 250...450))
        let stepped = held.dragStepped(width: Self.width, room: Self.noCap)
        #expect(stepped == HeightFit(factor: 2, lock: nil, range: 250...450))
        #expect(held.dragEnded(shown: 300, width: Self.width, room: Self.noCap).factor == 1.5)
    }

    // MARK: - Fails closed

    @Test func failsClosedOnAMeasureThatCannotBeRead() throws {
        // A reading of nothing, a negative or a non-finite height: factor 1,
        // no lock and no range, so the window keeps its frame.
        for bad in [CGFloat(0), -40, .nan, .infinity] {
            let script = ScriptedMeasure()
            script.table = [Self.width: [VerticalFit.range.lowerBound: bad, VerticalFit.range.upperBound: bad]]
            let height = PanelHeight(measuring: script)
            height.chosen = 300
            let fit = height.contentChanged(width: Self.width, room: Self.noCap)
            #expect(fit.factor == 1, "\(bad)")
            #expect(fit.lock == nil, "\(bad)")
            #expect(fit.range == nil, "\(bad)")
            #expect(height.dragStarted(width: Self.width, room: Self.noCap).range == nil, "\(bad)")
        }
        // A drag that starts or steps on an unreadable measure gives factor 1,
        // whatever factor it began at, and no lock and no range.
        for bad in [CGFloat(0), -40, .nan, .infinity] {
            let script = ScriptedMeasure()
            let height = PanelHeight(measuring: script)
            height.chosen = 300
            #expect(height.contentChanged(width: Self.width, room: 1000).factor == 2)
            script.table = [Self.width: [1: bad, 3: bad]]
            let fit = height.dragStarted(width: Self.width, room: 1000)
            #expect(fit.factor == 1, "invalid=\(bad)")
            #expect(fit.lock == nil)
            #expect(fit.range == nil)

            let again = PanelHeight(measuring: script)
            again.chosen = 300
            #expect(again.contentChanged(width: 460, room: 1000).factor == 2)
            #expect(again.dragStarted(width: 460, room: 1000).factor == 2)
            #expect(again.dragStepped(width: Self.width, room: 1000) == HeightFit(factor: 1, lock: nil, range: nil))
        }

        // Only the top unreadable is unreadable all the same.
        let top = ScriptedMeasure()
        top.table = [Self.width: [VerticalFit.range.upperBound: .nan]]
        let topless = PanelHeight(measuring: top)
        topless.chosen = 300
        #expect(topless.contentChanged(width: Self.width, room: Self.noCap).lock == nil)

        // Under the minimum is the minimum; nothing to scale is factor 1.
        func factor(chosen: CGFloat?, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
            let script = ScriptedMeasure()
            script.table = [Self.width: [VerticalFit.range.lowerBound: minimum, VerticalFit.range.upperBound: maximum]]
            let height = PanelHeight(measuring: script)
            height.chosen = chosen
            return height.contentChanged(width: Self.width, room: Self.noCap).factor
        }
        #expect(factor(chosen: 10, minimum: 120, maximum: 300) == 1)
        #expect(factor(chosen: nil, minimum: 120, maximum: 300) == 1)
        #expect(factor(chosen: 500, minimum: 120, maximum: 120) == 1)
        #expect(factor(chosen: 500, minimum: 120, maximum: 120.5) == 1)
        #expect(factor(chosen: 500, minimum: 120, maximum: 100) == 1)
        #expect(VerticalFit.clamped(-3) == VerticalFit.range.lowerBound)
        #expect(VerticalFit.clamped(40) == VerticalFit.range.upperBound)

        // A file with no key, or a key that is not a boolean, opens dark.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-height-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state.json")
        let store = StateStore(file: file)
        try Data(#"{"textSizeStep": 3}"#.utf8).write(to: file)
        #expect(store.load().lightAppearance == false)
        #expect(store.load().textSizeStep == 3)
        try Data(#"{"textSizeStep": 2, "lightAppearance": "yes please"}"#.utf8).write(to: file)
        #expect(store.load().lightAppearance == false)
        #expect(store.load().textSizeStep == 2)
    }
}
