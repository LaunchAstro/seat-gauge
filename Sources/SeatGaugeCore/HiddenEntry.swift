import Foundation

/// A terminal's settings while `seatgauge-cli login` reads a pasted code. A
/// sign-in code is a secret, and a terminal that echoes it keeps it in the
/// window and its scrollback, so echo is off while the code is read. Whatever
/// ends the command, a sign-in, a failure, Ctrl-C or a kill, every setting is
/// left as it was found.
///
/// The settings live in this object and change only under its lock, so the
/// thread reading the code can never turn echo off after `end` has put the
/// terminal back. A signal does no work in its handler: the handler is empty,
/// and a dispatch source on an ordinary thread puts the terminal back and then
/// ends the command by the same signal.
public final class HiddenEntry: @unchecked Sendable {
    private static let endings = [SIGINT, SIGTERM]

    private let terminal: Int32
    private let found: termios
    private let lock = NSLock()
    private var ended = false
    private var sources: [any DispatchSourceSignal] = []

    /// Nil when `terminal` is not one, such as a code piped in.
    public init?(terminal: Int32 = STDIN_FILENO) {
        var settings = termios()
        guard isatty(terminal) == 1, tcgetattr(terminal, &settings) == 0 else { return nil }
        self.terminal = terminal
        found = settings
    }

    /// Ctrl-C and a kill put the terminal back before they end the command.
    /// The empty handler only keeps the signal from ending it first; unlike
    /// an ignored signal, a caught one is reset for every child the command
    /// starts.
    public func endOnSignals() {
        lock.withLock {
            guard !ended else { return }
            for ending in Self.endings {
                signal(ending) { _ in }
                let source = DispatchSource.makeSignalSource(signal: ending, queue: .global())
                source.setEventHandler { [self] in
                    end()
                    kill(getpid(), ending)
                }
                source.resume()
                sources.append(source)
            }
        }
    }

    /// Echo off for the code, before the prompt shows, so nothing pasted at
    /// once is echoed. The line still ends on Return, and anything already
    /// typed is kept. Nothing once `end` has run.
    public func hide() {
        lock.withLock {
            guard !ended else { return }
            var quiet = found
            quiet.c_lflag &= ~tcflag_t(ECHO)
            tcsetattr(terminal, TCSANOW, &quiet)
        }
    }

    /// The settings as they were found, once the code is read.
    public func restore() {
        lock.withLock {
            guard !ended else { return }
            put()
        }
    }

    /// The settings as they were found, for good, and the signals back to
    /// ending the command as they always did.
    public func end() {
        lock.withLock {
            guard !ended else { return }
            ended = true
            put()
            guard !sources.isEmpty else { return }
            for source in sources { source.cancel() }
            for ending in Self.endings { signal(ending, SIG_DFL) }
        }
    }

    private func put() {
        var settings = found
        tcsetattr(terminal, TCSANOW, &settings)
    }
}
