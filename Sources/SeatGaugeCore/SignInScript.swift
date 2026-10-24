import Foundation

/// The app's Sign in, as a one-off script Terminal opens. It runs the app's
/// own `seatgauge-cli login`, so Claude's login takes the pasted code in a
/// real terminal and prints its own result there. The app sees none of it,
/// only the marker the script leaves once the login has ended.
public enum SignInScript {

    public struct Written: Sendable {
        /// Private to the user; the app removes it once the login has ended.
        public let folder: URL
        public let script: URL
        /// The helper's exit status, written once the login has ended.
        public let marker: URL

        public enum Ending: Equatable, Sendable { case ended, neverStarted, outOfTime }

        /// Blocks until the login has ended, the folder has gone (the app
        /// removes it when Terminal will not open), the script is still
        /// there `start` seconds on (Terminal never ran it), or `limit`
        /// seconds have passed.
        public func wait(start: TimeInterval, limit: TimeInterval, every: TimeInterval = 1) -> Ending {
            let began = Date()
            while true {
                let files = FileManager.default
                if files.fileExists(atPath: marker.path) || !files.fileExists(atPath: folder.path) { return .ended }
                let waited = Date().timeIntervalSince(began)
                if waited >= start, files.fileExists(atPath: script.path) { return .neverStarted }
                if waited >= limit { return .outOfTime }
                Thread.sleep(forTimeInterval: every)
            }
        }
    }

    /// A fresh folder for this sign-in alone, readable by the user only,
    /// since the script names the seat and its seats file.
    public static func write(helper: URL, seat: String, seatsFile: URL,
                             in parent: URL = FileManager.default.temporaryDirectory) throws -> Written {
        let folder = parent.appendingPathComponent("seat-gauge-sign-in-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let script = folder.appendingPathComponent("sign-in.command")
        let marker = folder.appendingPathComponent("ended")
        let text = text(helper: helper, seat: seat, seatsFile: seatsFile, marker: marker)
        guard FileManager.default.createFile(atPath: script.path, contents: Data(text.utf8),
                                             attributes: [.posixPermissions: 0o700]) else {
            try? FileManager.default.removeItem(at: folder)
            throw ProcessFailure("the sign-in script could not be written, so nothing was opened.")
        }
        return Written(folder: folder, script: script, marker: marker)
    }

    /// Every value is passed quoted, so whatever a seat id or path holds it
    /// reaches the helper as one argument and never runs as shell.
    static func text(helper: URL, seat: String, seatsFile: URL, marker: URL) -> String {
        """
        #!/bin/sh
        # One sign-in, opened by Seat Gauge. It removes itself as it starts.
        rm -f "$0"
        ended() { printf '%s\\n' "$1" > \(quoted(marker.path)); trap - HUP INT TERM; }
        # A window closed mid-login still tells Seat Gauge the login ended;
        # Ctrl-C ends the login but keeps the window, as the end does.
        trap 'ended 129; exit 129' HUP
        trap 'ended 130' INT
        trap 'ended 143; exit 143' TERM
        \(quoted(helper.path)) login \(quoted(seat)) \(quoted(seatsFile.path))
        ended $?
        echo
        printf 'Press Return to close this window. '
        read -r _

        """
    }

    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
