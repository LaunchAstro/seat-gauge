import AppKit
import SeatGaugeCore

/// The app's Sign in, on a card whose seat says it is not logged in.
/// `SeatLogin.signIn` runs every step, the same as `seatgauge-cli login`;
/// this opens its link in the user's default browser, asks for the code in
/// the app and shows the same proof.
enum SignIn {
    /// One seat's sign-in, off the main thread since it waits on a person
    /// and on the CLI. `done` runs once it is proven, so the card reads again.
    static func start(_ id: SeatID, seats: [Seat], done: @escaping @Sendable () -> Void) {
        guard !GaugeMirror.shared.signingIn.contains(id) else { return }
        GaugeMirror.shared.signingIn.insert(id)
        let handoff = Handoff()
        Thread.detachNewThread {
            let result = Result {
                // The login shell's PATH, as the app's polls use.
                try SeatLogin.signIn(id.rawValue, email: nil, seats: seats, searchPath: .loginShell,
                                     code: { onMain { ask(id, link: handoff.link, opened: handoff.opened) } },
                                     link: { link in
                                         handoff.link = link
                                         handoff.opened = onMain { open(link) }
                                     })
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    GaugeMirror.shared.signingIn.remove(id)
                    // A sign-in that ended with its prompt still up, timed out
                    // or refused, closes it, so no prompt or thread outlives it.
                    if let prompt = prompts[id], NSApp.modalWindow === prompt { NSApp.abortModal() }
                }
                // Once the prompt has closed, so the proof is not drawn under it.
                DispatchQueue.main.async { MainActor.assumeIsolated { tell(id, result) } }
                if case .success = result { done() }
            }
        }
    }

    /// Each seat's code prompt while it is up.
    static var prompts: [SeatID: NSWindow] = [:]

    nonisolated static func onMain<T: Sendable>(_ work: @MainActor () -> T) -> T {
        DispatchQueue.main.sync { MainActor.assumeIsolated(work) }
    }

    /// The user's default browser, whichever it is. Only an https link is
    /// opened, and the core takes nothing else for one.
    static func open(_ link: String) -> Bool {
        guard let url = URL(string: link), url.scheme == "https" else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// The code, asked for here once the browser has the link. Copy link is
    /// there for when no browser opened; Cancel is no code, which the core
    /// refuses.
    static func ask(_ id: SeatID, link: String?, opened: Bool) -> String? {
        while true {
            let alert = NSAlert()
            alert.messageText = "Sign in \(id.rawValue)"
            alert.informativeText = (opened ? "The sign-in page is open in your browser. " : "Copy the link into a browser. ")
                + "Sign in to the account for \(id.rawValue), then paste the code the page shows."
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.placeholderString = "code"
            alert.accessoryView = field
            alert.addButton(withTitle: "Sign in")
            alert.addButton(withTitle: "Copy link")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            alert.window.level = .modalPanel
            prompts[id] = alert.window
            let answer = alert.runModal()
            prompts[id] = nil
            switch answer {
            case .alertFirstButtonReturn: return field.stringValue
            case .alertSecondButtonReturn:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link ?? "", forType: .string)
            default: return nil
            }
        }
    }

    /// The proof, in the words the command line prints, or why there is none.
    static func tell(_ id: SeatID, _ result: Result<SeatLogin.SignedIn, any Error>) {
        let alert = NSAlert()
        switch result {
        case let .success(signed):
            alert.messageText = signed.sentence(id.rawValue)
        case let .failure(error):
            alert.alertStyle = .warning
            alert.messageText = "\(id.rawValue) was not signed in"
            alert.informativeText = "\(error)"
        }
        alert.window.level = .modalPanel
        alert.runModal()
    }
}

/// The link and whether a browser took it, carried from the thread the core
/// hands it out on to the thread that asks for the code.
nonisolated final class Handoff: @unchecked Sendable {
    private let lock = NSLock()
    private var held: (link: String?, opened: Bool) = (nil, false)

    var link: String? {
        get { lock.withLock { held.link } }
        set { lock.withLock { held.link = newValue } }
    }

    var opened: Bool {
        get { lock.withLock { held.opened } }
        set { lock.withLock { held.opened = newValue } }
    }
}
