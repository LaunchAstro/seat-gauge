import AppKit
import Foundation
import SwiftUI
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// An ordinary window: a Dock icon, close and reopen, focus and a saved frame.
/// Every case that needs a window builds a real `WindowController` under an
/// autosave name of its own and reads the answer off the `NSWindow` it built.
/// The width rules go through `CardMetrics` and `PanelLayout`, so no case
/// opens anything on a screen and none of them needs a second display.
@Suite(.sharedMirror) @MainActor struct WindowTests {

    /// The key AppKit writes a window's autosaved frame under.
    static func frameKey(_ name: String) -> String { "NSWindow Frame \(name)" }

    static func freshName() -> String { "SeatGaugeWindowTest-\(UUID().uuidString)" }

    static func forget(_ name: String) {
        UserDefaults.standard.removeObject(forKey: frameKey(name))
    }

    /// An autosaved frame is eight numbers: the frame, then the screen it was
    /// saved against.
    static func seed(_ frame: CGRect, under name: String, screen: CGRect) {
        let text = "\(Int(frame.minX)) \(Int(frame.minY)) \(Int(frame.width)) \(Int(frame.height)) "
            + "\(Int(screen.minX)) \(Int(screen.minY)) \(Int(screen.width)) \(Int(screen.height))"
        UserDefaults.standard.set(text, forKey: frameKey(name))
    }

    static func controller(_ name: String) -> WindowController {
        _ = NSApplication.shared
        return WindowController(autosaveName: name, rootView: Root())
    }

    // MARK: - A Dock icon and a place in Cmd-Tab

    @Test func theAppIsRegularAndCarriesNoLSUIElement() {
        let application = NSApplication.shared
        let was = application.activationPolicy()
        defer { application.setActivationPolicy(was) }

        SeatGaugeApp.start(application)
        #expect(SeatGaugeApp.activationPolicy == .regular)
        #expect(application.activationPolicy() == .regular)
        #expect(application.mainMenu != nil)
    }

    // MARK: - Closing the window leaves the app polling

    @Test func closingTheWindowLeavesTheAppRunning() async {
        let name = Self.freshName()
        defer { Self.forget(name) }
        let controller = Self.controller(name)
        let delegate = SeatGaugeDelegate(controller: controller)
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared) == false)

        controller.show()
        controller.window.close()
        #expect(controller.window.isVisible == false)
        #expect(controller.window.isReleasedWhenClosed == false)

        // The loop has no window in it, so a poll landing with nothing on
        // screen still reaches `readings.json`.
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent("readings.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let seat = SeatID(rawValue: "work")
        let reading = Reading(seat: seat, windows: [], takenAt: Date(), plan: "max")
        let store = GaugeStore(file: file, order: [seat])
        _ = await store.apply(states: [seat: .live(reading)], order: [seat])
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - The Dock icon brings the same window back

    @Test func reopenBringsTheSameWindowBack() {
        let name = Self.freshName()
        defer { Self.forget(name) }
        let controller = Self.controller(name)
        let delegate = SeatGaugeDelegate(controller: controller)

        controller.show()
        let before = controller.window.frame
        let identity = ObjectIdentifier(controller.window)
        controller.window.close()

        #expect(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        #expect(ObjectIdentifier(controller.window) == identity)
        #expect(controller.window.isVisible)
        #expect(controller.window.frame == before)
    }

    // MARK: - It takes focus like any other window

    @Test func theWindowTakesFocusLikeAnyOther() {
        let name = Self.freshName()
        defer { Self.forget(name) }
        let window = Self.controller(name).window

        #expect((window is NSPanel) == false)
        #expect(window.hidesOnDeactivate == false)
        #expect(window.canBecomeKey)
        #expect(window.canBecomeMain)
        #expect(window.styleMask.contains(.nonactivatingPanel) == false)
    }

    // MARK: - Fails closed: a frame nobody can use is not restored

    @Test func aSavedFrameThatNoLongerFitsIsDiscarded() {
        let screens = NSScreen.screens.map(\.visibleFrame)
        let gone = CGRect(x: -9000, y: -9000, width: 620, height: 300)
        let lost = Self.freshName()
        defer { Self.forget(lost) }
        Self.seed(gone, under: lost, screen: CGRect(x: -9000, y: -9000, width: 2560, height: 1410))
        let parked = Self.controller(lost)
        #expect(parked.restoredSavedFrame == false)
        #expect(PanelPlacement.isOnScreen(parked.window.frame, visibleFrames: screens))

        // Narrower than the content can be drawn in, so the width is not taken
        // either: a window nobody can read is not a window that was restored.
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let narrow = Self.freshName()
        defer { Self.forget(narrow) }
        let reference = Self.controller(Self.freshName())
        let tooNarrow = CGRect(x: screen.minX + 40, y: screen.minY + 40,
                               width: max(1, reference.window.contentMinSize.width - 60),
                               height: reference.contentHeight)
        Self.seed(tooNarrow, under: narrow, screen: screen)
        let widened = Self.controller(narrow)
        #expect(widened.restoredSavedFrame == false)
        #expect(widened.window.frame.width >= widened.window.contentMinSize.width)
        #expect(PanelPlacement.isOnScreen(widened.window.frame, visibleFrames: screens))
    }
}
