import Foundation

/// The terminal's settings while `login` reads a pasted code. A sign-in code
/// is a secret, and a terminal that echoes it keeps it in the window and its
/// scrollback, so echo is off while the code is read. Whatever ends the
/// command, a sign-in, a failure or Ctrl-C, the terminal is left as it was
/// found.
enum HiddenEntry {
    /// The settings `begin` found, read by the signal handler, which may
    /// capture nothing. Set before the handler is installed and never again.
    nonisolated(unsafe) private static var found = termios()
    nonisolated(unsafe) private static var active = false

    /// The signals that end the command with the code prompt up: Ctrl-C,
    /// and a plain `kill`.
    private static let endings = [SIGINT, SIGTERM]

    /// Remembers stdin's settings and puts them back on Ctrl-C or a kill.
    /// Nothing when stdin is not a terminal, such as a code piped in.
    static func begin() {
        guard isatty(STDIN_FILENO) == 1, tcgetattr(STDIN_FILENO, &found) == 0 else { return }
        active = true
        for ending in endings {
            // Only async-signal-safe calls: put the settings back, then die
            // of the same signal, so a caller still sees how the command ended.
            signal(ending) { signalNumber in
                tcsetattr(STDIN_FILENO, TCSANOW, &HiddenEntry.found)
                signal(signalNumber, SIG_DFL)
                raise(signalNumber)
            }
        }
    }

    /// Echo off for the code, before the prompt shows, so nothing pasted at
    /// once is echoed. The line still ends on Return, and anything already
    /// typed is kept.
    static func hide() {
        guard active else { return }
        var quiet = found
        quiet.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &quiet)
    }

    /// The settings as `begin` found them.
    static func restore() {
        guard active else { return }
        tcsetattr(STDIN_FILENO, TCSANOW, &found)
    }

    /// `restore`, and the signals back to ending the command as they always did.
    static func end() {
        guard active else { return }
        restore()
        for ending in endings { signal(ending, SIG_DFL) }
        active = false
    }
}
