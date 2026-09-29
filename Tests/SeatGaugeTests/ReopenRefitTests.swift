import AppKit
import Foundation
import SwiftUI
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// The size changes while the window is closed, and the window that comes
/// back fits its cards, with no strip of dead space under them.
///
/// The case drives the real `SeatGaugeDelegate` commands and the real
/// `applicationShouldHandleReopen` against a populated `Root`: four cards,
/// three windows each, an account, a plan and a pace line.
@Suite(.sharedMirror) @MainActor struct ReopenRefitTests {

    /// The delegate writes the chosen size to the `state.json` it is given,
    /// so the case hands it one in a temporary folder of its own and the
    /// installed app's file is never opened.
    static func temporaryStore() -> (StateStore, URL) {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        return (StateStore(file: folder.appendingPathComponent("state.json")), folder)
    }

    static func freshName() -> String { "SeatGaugeRefitTest-\(UUID().uuidString)" }

    static func forget(_ name: String) {
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)")
    }

    /// SwiftUI notices the new text size on a turn of the run loop, and the
    /// window has to be measured where the user sees it, which is after the
    /// redraw. Awaited rather than pumped: running the main run loop from
    /// inside a case re-enters the test runner and takes the whole run down at
    /// random rather than failing a case.
    static func settle() async {
        try? await Task.sleep(for: .milliseconds(120))
    }

    /// Four seats, each live with a five hour, a weekly and a Fable window, an
    /// account and a plan on the card, and a weekly window part spent so the
    /// pace line is drawn under it.
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

    /// The reopen, then the wait the redraw needs, then the measurement.
    static func reopened(_ delegate: SeatGaugeDelegate,
                         _ controller: WindowController) async -> CGFloat {
        _ = delegate.applicationShouldHandleReopen(.shared, hasVisibleWindows: false)
        await settle()
        return abs(deadSpace(controller))
    }

    /// The excess the user sees: the vertical points the window has allocated
    /// over the height its content asks for at the width it is.
    static func deadSpace(_ controller: WindowController) -> CGFloat {
        controller.window.contentLayoutRect.height - controller.contentHeight
    }

    // MARK: - Closed, changed, reopened

    @Test func aSizeChangedWhileTheWindowIsClosedLeavesNoDeadSpaceOnReopen() async {
        _ = NSApplication.shared
        // The windows the cases before this one built and let go of. This is
        // the only case that turns the main run loop, so it is the only one
        // whose wait reaches AppKit's display cycle, and the cycle walks every
        // window the application still has. Closed here rather than waited on.
        for window in NSApplication.shared.windows { window.close() }
        let (store, folder) = Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: folder) }

        let mirror = GaugeMirror.shared
        let wasScale = mirror.textScale
        let wasSnapshot = mirror.snapshot
        let wasSeats = mirror.seats
        defer {
            mirror.textScale = wasScale
            mirror.apply(wasSnapshot, seats: wasSeats)
        }

        let now = Date(timeIntervalSince1970: 1_758_500_100)
        let (seats, snapshot) = Self.populate(now: now)
        mirror.apply(snapshot, seats: seats)
        mirror.textScale = .smallest

        let name = Self.freshName()
        defer { Self.forget(name) }
        let controller = WindowController(autosaveName: name, rootView: Root())
        let delegate = SeatGaugeDelegate(controller: controller, store: store)
        defer { controller.window.close() }

        controller.show()
        await Self.settle()
        // Four cards are drawn, so the height under test is the real one.
        #expect(mirror.model(at: now).cards.count == 4)
        #expect(controller.contentHeight > 0)
        #expect(abs(Self.deadSpace(controller)) < 1)

        // Closed, then the ladder is climbed with the window away, one real
        // menu command at a time, exactly as Cmd + climbs it.
        controller.window.close()
        #expect(controller.window.isVisible == false)
        for _ in 0..<6 {
            delegate.increaseTextSize(nil)
            await Self.settle()
        }
        #expect(TextScale.current == TextScale.largest)
        #expect(store.load().textSizeStep == TextScale.largest.step)

        // The Dock icon: the real handler, not `show()` under another name.
        let atLargest = await Self.reopened(delegate, controller)
        #expect(controller.window.isVisible)
        #expect(atLargest < 1)

        // And back down the ladder, because a window that shrinks while it is
        // away is the same defect from the other end.
        controller.window.close()
        for _ in 0..<6 {
            delegate.decreaseTextSize(nil)
            await Self.settle()
        }
        #expect(TextScale.current == TextScale.smallest)
        #expect(await Self.reopened(delegate, controller) < 1)

        // Every step of the ladder, not only its ends: closed, one step,
        // reopened, measured, each time.
        for _ in 0..<6 {
            controller.window.close()
            delegate.increaseTextSize(nil)
            await Self.settle()
            #expect(await Self.reopened(delegate, controller) < 1)
        }
        // The cards are still there: fitting the window is not emptying it.
        #expect(mirror.model(at: now).cards.count == 4)
        #expect(controller.window.frame.width >= controller.window.contentMinSize.width)
    }
}
