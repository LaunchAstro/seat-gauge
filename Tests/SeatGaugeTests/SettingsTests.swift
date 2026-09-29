import AppKit
import Foundation
import Observation
import ServiceManagement
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// The Settings window: where it opens from, that it is one window of its own,
/// and that its controls run the menus' commands and follow them. Nothing here
/// registers a login item or writes the app's own `state.json`.
@Suite(.sharedMirror) @MainActor struct SettingsTests {

    static func scratchStore() -> StateStore {
        StateStore(file: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-settings-\(UUID().uuidString)")
            .appendingPathComponent("state.json"))
    }

    /// A delegate over a real panel window, restoring the mirror's size and
    /// appearance and forgetting the window's frame when the case ends.
    static func withDelegate(_ body: (SeatGaugeDelegate, WindowController, StateStore) throws -> Void) rethrows {
        _ = NSApplication.shared
        let mirror = GaugeMirror.shared
        let was = (mirror.textScale, mirror.lightAppearance)
        let name = "SeatGaugeSettingsTest-\(UUID().uuidString)"
        let store = scratchStore()
        defer {
            mirror.textScale = was.0
            mirror.lightAppearance = was.1
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)")
            try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent())
        }
        mirror.textScale = .normal
        mirror.lightAppearance = false
        let controller = WindowController(autosaveName: name, rootView: Root())
        let delegate = SeatGaugeDelegate(controller: controller, store: store)
        defer {
            delegate.settings.window?.close()
            controller.window.close()
        }
        try body(delegate, controller, store)
    }

    /// Whether reading `read` registers a dependency that `change` fires.
    static func redraws(_ read: () -> Void, when change: () -> Void) -> Bool {
        let fired = Box()
        withObservationTracking(read) { fired.value = true }
        change()
        return fired.value
    }

    final class Box: @unchecked Sendable { var value = false }

    // MARK: - Settings opens from both menus

    @Test func settingsIsInTheAppMenuAndTheRightClickMenu() throws {
        let app = try #require(SeatGaugeApp.menuBar().items.first?.submenu)
        let item = try #require(app.items.first { $0.title == "Settings\u{2026}" })
        #expect(item.keyEquivalent == ",")
        #expect(item.keyEquivalentModifierMask == .command)
        #expect(item.action == SettingsCommand.action)

        let menu = PanelMenu().menu
        let right = try #require(menu.items.first { $0.title == "Settings\u{2026}" })
        #expect(right.action == SettingsCommand.action)
        #expect(right.target == nil)
        // The items that were there are still there.
        for title in ["Sync all", "Launch at login", "Reveal config", "Quit",
                      "Bigger text", "Smaller text", "Ordinary text", "Light appearance"] {
            #expect(menu.items.contains { $0.title == title })
        }
    }

    // MARK: - One window of its own

    @Test func openingAgainBringsTheSameWindowForwardAndClosingChangesNothing() throws {
        try Self.withDelegate { delegate, controller, _ in
            controller.show()
            #expect(delegate.settings.window == nil)
            NSApp.sendAction(SettingsCommand.action, to: delegate, from: nil)
            let window = try #require(delegate.settings.window)
            #expect(window.isVisible)
            #expect(window !== controller.window)
            #expect(window.styleMask.contains(.titled))
            #expect(window.title == "Settings")
            #expect(window.contentView?.isDescendant(of: controller.window.contentView!) == false)

            delegate.showSettings(nil)
            #expect(delegate.settings.window === window)

            let panel = controller.window.frame
            window.close()
            #expect(!window.isVisible)
            #expect(controller.window.isVisible)
            #expect(controller.window.frame == panel)
            #expect(GaugeMirror.shared.textScale == .normal)
            #expect(GaugeMirror.shared.lightAppearance == false)

            // A size changed while it is put away is drawn when it is back.
            delegate.increaseTextSize(nil)
            controller.window.layoutIfNeeded()
            window.layoutIfNeeded()
            delegate.showSettings(nil)
            #expect(delegate.settings.window === window)
            #expect(window.isVisible)
            window.layoutIfNeeded()
        }
    }

    // MARK: - Its controls run the menus' commands

    @Test func controlsChangeWhatTheMenusChange() throws {
        try Self.withDelegate { delegate, controller, store in
            delegate.showSettings(nil)
            let controls = delegate.settings.controls

            controls.light = true
            #expect(GaugeMirror.shared.lightAppearance)
            #expect(AppearanceStore.load(store))
            #expect(controller.window.appearance?.name == .aqua)
            #expect(delegate.settings.window?.appearance?.name == .aqua)
            // Choosing the appearance it has is not a toggle.
            controls.light = true
            #expect(GaugeMirror.shared.lightAppearance)
            controls.light = false
            #expect(!GaugeMirror.shared.lightAppearance)
            #expect(delegate.settings.window?.appearance?.name == .darkAqua)

            controls.bigger()
            #expect(GaugeMirror.shared.textScale == TextScale.normal.stepped(by: 1))
            #expect(TextSizeStore.load(store) == GaugeMirror.shared.textScale)
            controls.smaller()
            controls.smaller()
            #expect(GaugeMirror.shared.textScale == TextScale.normal.stepped(by: -1))
            controls.ordinary()
            #expect(GaugeMirror.shared.textScale == .default)
        }
    }

    // MARK: - And follow a change made elsewhere

    @Test func controlsFollowTheMenusAndTheTitleBar() throws {
        try Self.withDelegate { delegate, _, _ in
            let service = AlertAndLoginItemTests.StubService()
            let item = LoginItem(service: service, bundle: AlertAndLoginItemTests.installed,
                                 store: Self.scratchStore(), log: { _ in })
            delegate.settings.loginItem = item
            delegate.showSettings(nil)
            let controls = delegate.settings.controls

            #expect(Self.redraws({ _ = controls.light }) {
                NSApp.sendAction(AppearanceCommand.action, to: delegate, from: nil)
            })
            #expect(controls.light)
            #expect(Self.redraws({ _ = controls.scale }) {
                NSApp.sendAction(TextSizeCommand.bigger.action, to: delegate, from: nil)
            })
            #expect(controls.scale == TextScale.normal.stepped(by: 1))

            // The right click menu's switch, then an approval macOS is holding.
            let panelMenu = PanelMenu()
            panelMenu.loginItem = item
            panelMenu.menuNeedsUpdate(panelMenu.menu)
            let toggle = try #require(panelMenu.menu.items.first { $0.title == "Launch at login" })
            #expect(Self.redraws({ _ = controls.launchAtLogin }) {
                NSApp.sendAction(toggle.action!, to: toggle.target, from: toggle)
            })
            #expect(controls.launchAtLogin)
            #expect(controls.loginHint == nil)
            #expect(Self.redraws({ _ = controls.loginHint }) {
                service.set(.requiresApproval)
                delegate.settings.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
            })
            #expect(controls.loginHint == item.hint)
            #expect(controls.loginHint != nil)

            // And the other way: the switch here is the menu's tick.
            controls.launchAtLogin = false
            panelMenu.menuNeedsUpdate(panelMenu.menu)
            #expect(panelMenu.menu.items.first { $0.title == "Launch at login" }?.state == .off)
        }
    }

    // MARK: - Sol's proof: the approval hint fits

    @Test func approvalHintFitsInSettingsWindow() throws {
        try Self.withDelegate { delegate, _, _ in
            let service = AlertAndLoginItemTests.StubService()
            let item = LoginItem(
                service: service,
                bundle: AlertAndLoginItemTests.installed,
                store: Self.scratchStore(),
                log: { _ in }
            )
            delegate.settings.loginItem = item
            delegate.showSettings(nil)
            let window = try #require(delegate.settings.window)
            let host = try #require(window.contentViewController)
            window.layoutIfNeeded()
            let before = host.preferredContentSize.height

            service.set(.requiresApproval)
            delegate.settings.windowDidBecomeKey(
                Notification(name: NSWindow.didBecomeKeyNotification, object: window)
            )
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            window.layoutIfNeeded()

            let wanted = host.preferredContentSize.height
            #expect(wanted > before)
            #expect(window.contentLayoutRect.height + 1 >= wanted)
        }
    }
}
