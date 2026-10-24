import AppKit
import SeatGaugeCore

/// The app's Sign in, on a card whose seat says it is not logged in. It opens
/// Terminal running this app's own `seatgauge-cli login` for the seat, so
/// Claude's login prints its link, takes the pasted code and says whether it
/// worked, all in Terminal. The app never sees the code; it reads the card
/// again once that login has ended.
enum SignIn {
    /// How long a sign-in may stay open before the card is read again
    /// anyway, as long as `claude auth login` itself waits.
    static let wait: TimeInterval = 900

    static func start(_ id: SeatID, seats: [Seat], done: @escaping @Sendable () -> Void) {
        guard !GaugeMirror.shared.signingIn.contains(id) else { return }
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
            NSWorkspace.shared.open([written.script], withApplicationAt: terminal,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard let error else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        try? FileManager.default.removeItem(at: written.folder)
                        GaugeMirror.shared.signingIn.remove(id)
                        refused(id, error)
                    }
                }
            }
        } catch {
            refused(id, error)
            return
        }
        Thread.detachNewThread {
            let end = Date().addingTimeInterval(wait)
            while Date() < end, FileManager.default.fileExists(atPath: written.folder.path),
                  !FileManager.default.fileExists(atPath: written.marker.path) {
                Thread.sleep(forTimeInterval: 1)
            }
            try? FileManager.default.removeItem(at: written.folder)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GaugeMirror.shared.signingIn.remove(id) }
                done()
            }
        }
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
