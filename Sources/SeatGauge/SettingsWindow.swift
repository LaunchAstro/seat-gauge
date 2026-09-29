import AppKit
import SeatGaugeCore
import SwiftUI

/// What the Settings window changes. Every change is sent as the command the
/// menus and the title bar send, so there is one path to each setting, and
/// every value is read from the mirror or the login item, both observed, so a
/// change made from the menu while the window is open is drawn in it at once.
@MainActor struct SettingsControls {
    var mirror = GaugeMirror.shared
    let loginItem: LoginItem?
    /// The delegate, or nil for the responder chain. Weak, since the delegate
    /// owns the window this is drawn in.
    weak var target: AnyObject?

    var light: Bool {
        get { mirror.lightAppearance }
        nonmutating set { if newValue != light { send(AppearanceCommand.action) } }
    }

    var scale: TextScale { mirror.textScale }

    func bigger() { send(TextSizeCommand.bigger.action) }
    func smaller() { send(TextSizeCommand.smaller.action) }
    func ordinary() { send(TextSizeCommand.ordinary.action) }

    var launchAtLogin: Bool {
        get { loginItem?.isOn ?? false }
        nonmutating set { if newValue != launchAtLogin { loginItem?.toggle() } }
    }

    var loginHint: String? { loginItem?.hint }

    func revealConfig() { RevealConfigCommand.run() }

    private func send(_ action: Selector) { NSApp.sendAction(action, to: target, from: nil) }
}

/// Small and plain, in the panel's own tones and type.
struct SettingsView: View {
    let controls: SettingsControls

    var body: some View {
        let light = Binding(get: { controls.light }, set: { controls.light = $0 })
        let login = Binding(get: { controls.launchAtLogin }, set: { controls.launchAtLogin = $0 })
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 14) {
            GridRow {
                label("Appearance")
                Picker("Appearance", selection: light) {
                    Text("Light").tag(true)
                    Text("Dark").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().tint(Tone.accent)
            }
            GridRow {
                label("Text size")
                HStack(spacing: 8) {
                    Stepper {
                        Text("\(controls.scale.percent)%")
                            .font(Type.mono(11)).monospacedDigit()
                    } onIncrement: {
                        controls.bigger()
                    } onDecrement: {
                        controls.smaller()
                    }
                    Button("Ordinary", action: controls.ordinary)
                        .disabled(controls.scale == .default)
                }
            }
            GridRow {
                label("Launch at login")
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Launch at login", isOn: login)
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                        .disabled(controls.loginItem == nil)
                    if let hint = controls.loginHint {
                        Text(hint).font(Type.ui(10)).foregroundStyle(Tone.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            GridRow {
                label("Config")
                Button(RevealConfigCommand.title, action: controls.revealConfig)
            }
        }
        .font(Type.ui(12))
        .foregroundStyle(Tone.ink)
        .frame(width: 320 * controls.scale.factor, alignment: .leading)
        .padding(20)
        .background(Tone.bg.ignoresSafeArea())
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Type.mono(10)).foregroundStyle(Tone.inkMuted).gridColumnAlignment(.trailing)
    }
}

/// The one Settings window. It is built on the first open and kept, so the
/// next open brings the same one forward, and closing it only puts it away.
@MainActor final class SettingsWindow: NSObject, NSWindowDelegate {
    /// Set by the delegate that owns it, which every command is sent to.
    weak var target: AnyObject?
    /// Set by `main.swift`. With none the switch is off and does nothing.
    var loginItem: LoginItem?
    private(set) var window: NSWindow?

    var controls: SettingsControls { SettingsControls(loginItem: loginItem, target: target) }

    func show() {
        let window = self.window ?? build()
        loginItem?.refresh()
        applyAppearance()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: false)
    }

    /// The panel's appearance, so the system's controls draw in it too.
    func applyAppearance() {
        window?.appearance = NSAppearance(named: GaugeMirror.shared.lightAppearance ? .aqua : .darkAqua)
        window?.backgroundColor = NSColor(Tone.bg)
    }

    /// Back from System Settings, where the login item is approved.
    func windowDidBecomeKey(_ notification: Notification) { loginItem?.refresh() }

    private func build() -> NSWindow {
        let host = NSHostingController(rootView: SettingsView(controls: controls))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        return window
    }
}
