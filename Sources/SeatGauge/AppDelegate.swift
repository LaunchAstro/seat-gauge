import AppKit
import SeatGaugeCore

/// The three text size commands, written once, so the menu bar and the right
/// click menu carry the same titles and send the same actions. They have no
/// target: each one travels the responder chain to the delegate that owns the
/// window it resizes.
struct TextSizeCommand {
    let title: String
    let action: Selector
    let key: String

    static let bigger = TextSizeCommand(title: "Bigger text",
                                        action: #selector(SeatGaugeDelegate.increaseTextSize(_:)), key: "+")
    static let smaller = TextSizeCommand(title: "Smaller text",
                                         action: #selector(SeatGaugeDelegate.decreaseTextSize(_:)), key: "-")
    static let ordinary = TextSizeCommand(title: "Ordinary text",
                                          action: #selector(SeatGaugeDelegate.resetTextSize(_:)), key: "0")

    static let all = [bigger, smaller, ordinary]
}

/// The light appearance toggle, named once for the right click menu and
/// the title bar's button, which send the same action.
enum AppearanceCommand {
    static let title = "Light appearance"
    static let action = #selector(SeatGaugeDelegate.toggleLightAppearance(_:))
}

/// The Settings window, named once for the app menu and the right click menu.
enum SettingsCommand {
    static let title = "Settings\u{2026}"
    static let action = #selector(SeatGaugeDelegate.showSettings(_:))
}

/// Reveal config, from the right click menu and the Settings window.
enum RevealConfigCommand {
    static let title = "Reveal config"

    static func run() {
        NSWorkspace.shared.activateFileViewerSelecting([ConfigLoader.defaultFile])
    }
}

/// What makes Seat Gauge an ordinary Mac application rather than an accessory.
enum SeatGaugeApp {
    /// A Dock icon and a place in Cmd-Tab, in one value, so a case can read
    /// the decision as well as the application it was set on.
    static let activationPolicy: NSApplication.ActivationPolicy = .regular

    /// A regular application owns the menu bar, and without one Cmd-Q, Cmd-W
    /// and Cmd-M do nothing at all. Sync all and the rest live in the
    /// right-click menu on the cards.
    @discardableResult
    static func start(_ application: NSApplication) -> Bool {
        let set = application.setActivationPolicy(activationPolicy)
        application.mainMenu = menuBar()
        return set
    }

    static func menuBar() -> NSMenu {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: SettingsCommand.title, action: SettingsCommand.action, keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Seat Gauge", action: #selector(NSApplication.hide(_:)),
                    keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Seat Gauge", action: #selector(NSApplication.terminate(_:)),
                    keyEquivalent: "q")
        appItem.submenu = app
        bar.addItem(appItem)

        let windowItem = NSMenuItem()
        let windows = NSMenu(title: "Window")
        windows.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)),
                        keyEquivalent: "w")
        windows.addItem(withTitle: "Minimise", action: #selector(NSWindow.performMiniaturize(_:)),
                        keyEquivalent: "m")
        windowItem.submenu = windows
        bar.addItem(windowItem)

        // Cmd +, Cmd - and Cmd 0. A regular application owns the menu bar, so
        // this is where the three key equivalents live; the same three are a
        // right click away on the cards.
        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        for command in TextSizeCommand.all {
            let item = NSMenuItem(title: command.title, action: command.action,
                                  keyEquivalent: command.key)
            item.keyEquivalentModifierMask = .command
            view.addItem(item)
        }
        viewItem.submenu = view
        bar.addItem(viewItem)
        return bar
    }
}

/// Closing the window puts it away and leaves the poll loop running, and the
/// Dock icon brings the same one back.
final class SeatGaugeDelegate: NSObject, NSApplicationDelegate {
    private let controller: WindowController
    /// Where the chosen text size and appearance are written: the app's own
    /// `state.json`, or a temporary one when a case drives the commands.
    private let store: StateStore
    /// Built once, so a second Settings brings the same window forward.
    let settings = SettingsWindow()

    init(controller: WindowController, store: StateStore = StateStore()) {
        self.controller = controller
        self.store = store
        super.init()
        settings.target = self
    }

    /// The loop has no window in it. Closing the last one puts the numbers
    /// away, not quitting: Quit is in the menu and stays there.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// The Dock icon and Cmd-Tab both land here. The controller owns one
    /// window and hands that one back, so its frame and its contents are the
    /// ones that were there when it was closed.
    /// Refitted on the way back, and here rather than in `refit` itself,
    /// because a closed window is not a window the content can be measured in:
    /// SwiftUI does not lay the hosting view out off screen, and the height
    /// correction in `ContentSizedHostingView.layout()` is visible-only. So a
    /// text size the user changed while the numbers were away, or a poll that
    /// landed taller cards, is fitted at the first moment it can be, which is
    /// once the window is back on screen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        controller.show()
        controller.refit()
        return true
    }

    /// The text size, from either menu. One step, or back to the default
    /// size, drawn at once and written to `state.json` so the next launch
    /// opens at it.
    @objc func increaseTextSize(_ sender: Any?) { apply(TextScale.current.stepped(by: 1)) }

    @objc func decreaseTextSize(_ sender: Any?) { apply(TextScale.current.stepped(by: -1)) }

    @objc func resetTextSize(_ sender: Any?) { apply(.default) }

    /// Light or dark, drawn at once and written to `state.json` beside the
    /// text size. A toggle that cannot be written is still drawn.
    @objc func toggleLightAppearance(_ sender: Any?) {
        GaugeMirror.shared.lightAppearance.toggle()
        try? AppearanceStore.save(GaugeMirror.shared.lightAppearance, to: store)
        controller.applyAppearance()
        settings.applyAppearance()
    }

    @objc func showSettings(_ sender: Any?) { settings.show() }

    /// A size that cannot be written is still drawn: the panel the user is
    /// looking at outranks the file it is remembered in.
    private func apply(_ scale: TextScale) {
        GaugeMirror.shared.textScale = scale
        try? TextSizeStore.save(scale, to: store)
        controller.refit(.textSize)
    }
}
