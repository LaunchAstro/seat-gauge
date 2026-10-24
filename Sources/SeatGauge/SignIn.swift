import AppKit
import SeatGaugeCore

/// The app's Sign in, on a card whose seat says it is not logged in. It opens
/// Terminal running this app's own `seatgauge-cli login` for the seat, so
/// Claude's login prints its link, takes the pasted code and says whether it
/// worked, all in Terminal. The app never sees the code; it reads the card
/// again once that login has ended.
enum SignIn {
    /// How long a sign-in may stay open before the card is read again
    /// anyway: `claude auth login`'s own 15 minutes, its minute-long status
    /// check, and Terminal's start, so the app never gives up first.
    nonisolated static let limit: TimeInterval = 1200
    /// How long Terminal has to start the script, which removes itself as
    /// it starts, before the seat is freed for another click.
    nonisolated static let opens: TimeInterval = 60

    /// Each waiting seat's attempt, so an attempt that has ended frees its
    /// seat only while no later one holds it.
    static var attempts: [SeatID: UUID] = [:]

    /// `seats` is unused: the helper reads the seats file itself.
    static func start(_ id: SeatID, seats: [Seat], done: @escaping @Sendable () -> Void) {
        guard !GaugeMirror.shared.signingIn.contains(id) else { return }
        let attempt = UUID()
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/seatgauge-cli")
        let written: SignInScript.Written
        do {
            guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                throw ProcessFailure("this copy of Seat Gauge has no seatgauge-cli inside it. Install it with make install, then sign in again.")
            }
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                throw ProcessFailure("Terminal is not on this Mac.")
            }
            written = try SignInScript.write(helper: helper, seat: id.rawValue, seatsFile: ConfigLoader.defaultFile)
            GaugeMirror.shared.signingIn.insert(id)
            attempts[id] = attempt
            NSWorkspace.shared.open([written.script], withApplicationAt: terminal,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard let error else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        try? FileManager.default.removeItem(at: written.folder)
                        guard free(id, attempt) else { return }
                        refused(id, error)
                    }
                }
            }
        } catch {
            refused(id, error)
            return
        }
        Thread.detachNewThread {
            _ = written.wait(start: opens, limit: limit)
            try? FileManager.default.removeItem(at: written.folder)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { if free(id, attempt) { done() } }
            }
        }
    }

    /// Frees the seat for another click if `attempt` still holds it, and
    /// says whether it did.
    static func free(_ id: SeatID, _ attempt: UUID) -> Bool {
        guard attempts[id] == attempt else { return false }
        attempts[id] = nil
        GaugeMirror.shared.signingIn.remove(id)
        return true
    }

    /// Why Terminal was not opened. Brought to the front, since a panel of
    /// an app that is not active stays hidden.
    static func refused(_ id: SeatID, _ error: any Error) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(id.rawValue) was not signed in"
        alert.informativeText = "\(error)"
        alert.runModal()
    }
}
