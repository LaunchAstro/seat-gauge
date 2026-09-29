import AppKit
import SeatGaugeCore

/// The right-click menu on the panel's content view. It is rebuilt each time it
/// opens, because the reasons under it are the seats that are not drawn and
/// those change with every poll.
final class PanelMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu(title: "Seat Gauge")
    var loginItemOn = false
    var notes: [String] = []
    /// The card the right click landed on, which the menu offers to hide.
    var card: CardModel?
    /// Set by `main.swift` once the app knows where it is running from. The
    /// tick is the service's own status when it is there, so the menu never
    /// claims a login item the system does not hold.
    var loginItem: LoginItem?

    override init() {
        super.init()
        menu.delegate = self
        rebuild()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let model = GaugeMirror.shared.model(at: Date())
        notes = model.notes
        card = model.cards.first { $0.id == GaugeMirror.shared.hovered }
        if let loginItem {
            loginItemOn = loginItem.isOn
            if let hint = loginItem.hint { notes.insert(hint, at: 0) }
        }
        rebuild()
    }

    func rebuild() {
        menu.removeAllItems()
        // A problem's whole sentence comes first, since the title bar has
        // room for only the start of one.
        let problems = GaugeMirror.shared.problems
        for problem in problems { addNote(problem) }
        if !problems.isEmpty { menu.addItem(.separator()) }
        if let card {
            add("Hide \(card.label)", #selector(hideCard))
            menu.addItem(.separator())
        }
        add("Sync all", #selector(syncAll))
        add("Launch at login", #selector(toggleLoginItem)).state = loginItemOn ? .on : .off
        add(RevealConfigCommand.title, #selector(revealConfig))
        add("Quit", #selector(quit))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: SettingsCommand.title, action: SettingsCommand.action,
                                keyEquivalent: ""))
        for command in TextSizeCommand.all { addCommand(command) }
        // The toggle travels the responder chain to the delegate that owns
        // the window it recolours, as the text size commands do.
        let light = NSMenuItem(title: AppearanceCommand.title, action: AppearanceCommand.action,
                               keyEquivalent: "")
        light.state = GaugeMirror.shared.lightAppearance ? .on : .off
        menu.addItem(light)
        guard !notes.isEmpty else { return }
        menu.addItem(.separator())
        for note in notes { addNote(note) }
    }

    /// A line that says a fact rather than offering a command.
    private func addNote(_ note: String) {
        let item = NSMenuItem(title: note, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    /// The three text size commands, with no target, so they travel the
    /// responder chain to the delegate that owns the window they resize. The
    /// right click menu and the menu bar then run the same three, which is
    /// what makes the sizes discoverable.
    private func addCommand(_ command: TextSizeCommand) {
        menu.addItem(NSMenuItem(title: command.title, action: command.action, keyEquivalent: ""))
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func hideCard() { card.map { GaugeMirror.shared.hide($0.id) } }

    @objc private func syncAll() { GaugeMirror.shared.syncAll() }

    /// `SMAppService` is behind this. With no login item wired up,
    /// which is every case that builds a bare menu, the tick is this object's
    /// own state.
    @objc private func toggleLoginItem() {
        guard let loginItem else { loginItemOn.toggle(); return }
        loginItem.toggle()
        loginItemOn = loginItem.isOn
        rebuild()
    }

    @objc private func revealConfig() { RevealConfigCommand.run() }

    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
