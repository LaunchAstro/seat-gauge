import Foundation

/// Signs one Claude seat in under its own profile, the one path every front
/// end takes. `claude auth login` does the sign-in and keeps what it gets
/// (ADR 0001); this carries its link out and the pasted code in, then asks
/// `claude auth status` whether it worked. The code goes to the CLI and
/// nowhere else: no line, no error, and nothing the CLI prints after it is
/// read, since a CLI may print the code back.
public enum SeatLogin {

    public static let usage = "usage: seatgauge-cli login <seat> [--email <address>] [seats.json]"

    /// `seatgauge-cli login`'s arguments, in any order after the seat.
    public struct Request: Equatable, Sendable {
        public let seat: String
        public let email: String?
        public let seatsFile: String?

        public init(seat: String, email: String?, seatsFile: String?) {
            self.seat = seat
            self.email = email
            self.seatsFile = seatsFile
        }

        public init(arguments: [String]) throws {
            var rest = arguments[...]
            var seat: String?, email: String?, file: String?
            while let argument = rest.popFirst() {
                if argument == "--email", email == nil, let value = rest.popFirst() {
                    email = value
                } else if argument.hasPrefix("-") {
                    throw ProcessFailure(usage)
                } else if seat == nil {
                    seat = argument
                } else if file == nil {
                    file = argument
                } else {
                    throw ProcessFailure(usage)
                }
            }
            guard let seat else { throw ProcessFailure(usage) }
            self.init(seat: seat, email: email, seatsFile: file)
        }
    }

    /// What `claude auth status` says of the seat once it is signed in.
    public struct SignedIn: Equatable, Sendable {
        public let email: String?
        public let plan: String?

        public init(email: String?, plan: String?) {
            self.email = email
            self.plan = plan
        }

        /// The proof as one sentence, worded the same by every front end.
        public func sentence(_ seat: String) -> String {
            let account = [email, plan].compactMap(\.self).joined(separator: ", ")
            return "\(seat) is signed in" + (account.isEmpty ? "." : " (\(account)).")
        }
    }

    /// Whether a front end offers Sign in: a Claude seat with its own login
    /// whose CLI said it is not logged in, in `ClaudeUsageParser`'s words. A
    /// token seat signs in with its token, and a seat dormant for any other
    /// reason is not waiting on a login.
    public static func offers(_ seat: Seat?, _ state: SeatState?) -> Bool {
        guard let seat, case .claude = seat.kind, seat.tokenFile == nil,
              case .dormant(reason: "not logged in")? = state else { return false }
        return true
    }

    /// Everything is checked before anything starts. `code` is asked once,
    /// on its own thread, when the CLI prompts for it, and may block until a
    /// person pastes; `link` gets the authorize link to open. A sign-in the
    /// CLI finishes in a browser of its own never asks for the code.
    public static func signIn(_ name: String, email: String?, seats: [Seat],
                              home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                              parent: [String: String] = ProcessInfo.processInfo.environment,
                              timeout: Duration = .seconds(900),
                              searchPath: SearchPath = .installs,
                              code: @escaping @Sendable () -> String?,
                              link: (String) -> Void) throws -> SignedIn {
        let profile = try profile(of: name, in: seats, home: home)
        if let email, !isAddress(email) {
            throw ProcessFailure("the --email value is not an email address, so nothing was started.")
        }
        // A fresh machine has no profile yet. Made for this user only, since
        // the login the CLI writes into it is.
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Neither a token nor another config directory is inherited, so the
        // CLI signs this profile in and no other.
        var environment = ChildEnvironment.make(from: parent, keeping: ["TERM"],
                                                setting: ClaudeFetcher.noUpdate.merging(
                                                    ["CLAUDE_CONFIG_DIR": profile.path]) { $1 })
        // The same PATH a poll gets, so the CLI is found wherever a poll finds it.
        environment["PATH"] = searchPath.joined(after: environment["PATH"])
        try login(name, email: email, environment: environment, timeout: timeout, code: code, link: link)
        return try status(name, environment: environment)
    }

    /// The seat's profile, or the reason it may not be signed in.
    static func profile(of name: String, in seats: [Seat], home: URL) throws -> URL {
        guard let seat = seats.first(where: { $0.id.rawValue == name }) else {
            throw ProcessFailure("no seat named \(name). Seats: " + seats.map(\.id.rawValue).joined(separator: ", "))
        }
        guard case let .claude(profile) = seat.kind else {
            throw ProcessFailure("\(name) is a Codex seat, which signs in with codex login, not claude.")
        }
        guard seat.tokenFile == nil else {
            throw ProcessFailure("\(name) signs in with a token. Give it \"login\": \"own\" in seats.json first, or its card will never read this login.")
        }
        // seats.json refuses these too; a seat list built any other way is
        // checked again here, before anything is written.
        let place = key(profile)
        guard ![home, home.appendingPathComponent(".claude")].map(key).contains(place) else {
            throw ProcessFailure("\(name) has the default login's directory as its profile, so signing it in would sign ~/.claude in instead. Give it a directory of its own.")
        }
        for other in seats where other.id != seat.id {
            if case let .claude(theirs) = other.kind, key(theirs) == place {
                throw ProcessFailure("\(name) has the same profile as \(other.id.rawValue), so signing one in would sign both in. Give each seat a directory of its own.")
            }
        }
        return profile
    }

    /// A profile's path as a Mac's default volume tells paths apart. A fresh
    /// machine's profile does not exist yet, but a parent of it may be a link,
    /// and the profile is made through that link. So `.` and `..` go by name,
    /// the deepest part that exists is resolved through every link in it, the
    /// rest is added as written, and the whole is folded for case and Unicode
    /// form. On a case-sensitive volume this refuses two spellings that are
    /// really two directories, which is the safe way to be wrong.
    static func key(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        let real = realpath(existing.path, nil).map { resolved in
            defer { free(resolved) }
            return String(cString: resolved)
        } ?? existing.path
        let path = rest.reduce(URL(fileURLWithPath: real)) { $0.appendingPathComponent($1) }.path
        return path.decomposedStringWithCanonicalMapping.lowercased()
    }

    /// One address, handed to the CLI as a value it cannot take for a flag.
    static func isAddress(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty && !text.hasPrefix("-")
            && !text.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.controlCharacters.contains($0) }
    }

    /// The pasted code once given, from whichever thread read it.
    private final class Pasted: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: String??
        func give(_ code: String?) { lock.withLock { answer = .some(code) } }
        var given: String?? { lock.withLock { answer } }
    }

    static func login(_ name: String, email: String?, environment: [String: String], timeout: Duration,
                      code: @escaping @Sendable () -> String?, link: (String) -> Void) throws {
        let child = try TerminalChild(["claude", "auth", "login", "--claudeai"] + (email.map { ["--email", $0] } ?? []),
                                      environment: environment)
        defer { child.stop() }
        let deadline = ContinuousClock.now + timeout
        let pasted = Pasted()
        // Only what the CLI printed before the code was sent is kept.
        var before = ""
        var asked = false, sent = false
        while true {
            guard ContinuousClock.now < deadline else {
                throw ProcessFailure("claude auth login was still waiting after \(max(1, Int((timeout.seconds / 60).rounded(.up)))) minutes, so it was stopped and \(name) was not signed in.")
            }
            guard let data = child.read() else { break }
            if data.isEmpty, !child.isRunning { break }
            if !sent { before += String(decoding: data, as: UTF8.self) }
            if !asked, before.contains("Paste code") {
                guard let found = before.firstMatch(of: /https:\/\/[^\s\x{07}\x{1B}]+/) else {
                    throw ProcessFailure("claude auth login asked for a code without printing a link, so \(name) was not signed in.")
                }
                link(String(found.output))
                asked = true
                Thread.detachNewThread { pasted.give(code()) }
            }
            if asked, !sent, let given = pasted.given {
                let typed = (given ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !typed.isEmpty else {
                    throw ProcessFailure("no code was pasted, so \(name) was not signed in.")
                }
                guard !typed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0)
                    || CharacterSet.controlCharacters.contains($0) }) else {
                    throw ProcessFailure("the pasted code has a space or a control character in it, so it was not sent and \(name) was not signed in.")
                }
                sent = true
                child.write(typed + "\r")
            }
        }
        let status = child.wait()
        guard status == 0 else {
            if sent {
                throw ProcessFailure("claude auth login stopped with status \(status) after the code was sent, so \(name) was not signed in. What it printed after the code is not shown, since it may repeat the code.")
            }
            throw ProcessFailure("claude auth login stopped with status \(status) before a code was sent, so \(name) was not signed in: \(plain(before))")
        }
    }

    /// The proof: the CLI's own word, under the same profile, that it is signed in.
    static func status(_ name: String, environment: [String: String]) throws -> SignedIn {
        let child = try TerminalChild(["claude", "auth", "status", "--json"], environment: environment)
        defer { child.stop() }
        let deadline = ContinuousClock.now + .seconds(60)
        var said = Data()
        while ContinuousClock.now < deadline, let data = child.read(), !data.isEmpty || child.isRunning {
            said.append(data)
        }
        // A status that never answers is stopped by the deferred stop, not waited on.
        guard ContinuousClock.now < deadline || !child.isRunning else {
            throw ProcessFailure("claude auth status did not answer within a minute, so \(name) was not signed in.")
        }
        let text = String(decoding: said, as: UTF8.self)
        let reply = text.firstIndex(of: "{").flatMap { start in
            text.lastIndex(of: "}").flatMap { end in start < end ? JSON.object(String(text[start...end])) : nil }
        }
        guard child.wait() == 0, let reply, reply["loggedIn"] as? Bool == true else {
            throw ProcessFailure("claude auth status says \(name) is not signed in.")
        }
        return SignedIn(email: JSON.text(reply["email"]), plan: JSON.text(reply["subscriptionType"]))
    }

    /// Terminal output as a sentence: escapes out, runs of space as one, the tail kept.
    static func plain(_ text: String) -> String {
        let bare = text.replacing(/\x{1B}\][^\x{07}\x{1B}]*(?:\x{07}|\x{1B}\\)|\x{1B}\[[0-?]*[ -\/]*[@-~]/, with: "")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(bare.suffix(300))
    }
}

/// A child on a pseudo-terminal, since `claude auth login` takes its code
/// only from one. Its output is read here and nowhere else.
final class TerminalChild {
    private let process = Process()
    private let master: Int32

    init(_ arguments: [String], environment: [String: String]) throws {
        var master: Int32 = -1, slave: Int32 = -1
        // Wide, so a long link is never wrapped across lines.
        var size = winsize(ws_row: 24, ws_col: 2000, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw ProcessFailure("no terminal could be opened for claude: \(String(cString: strerror(errno)))")
        }
        defer { close(slave) }
        process.executableURL = Fetch.env
        process.arguments = arguments
        process.environment = environment
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal
        do { try process.run() } catch {
            close(master)
            throw ProcessFailure("claude would not start: \(error.localizedDescription)")
        }
        self.master = master
    }

    deinit { close(master) }

    var isRunning: Bool { process.isRunning }

    /// What arrived within a tenth of a second, empty when nothing did, nil
    /// once every holder of the terminal has closed it.
    func read() -> Data? {
        var entry = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
        guard poll(&entry, 1, 100) > 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(master, &buffer, buffer.count)
        if count < 0, errno == EINTR || errno == EAGAIN { return Data() }
        return count > 0 ? Data(buffer[..<count]) : nil
    }

    func write(_ text: String) {
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let count = bytes.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
            guard count > 0 else { return }
            bytes = bytes.dropFirst(count)
        }
    }

    func wait() -> Int32 {
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// SIGTERM, then SIGKILL once the grace has run out, guarded on
    /// `isRunning` so a recycled pid is never the one that gets it.
    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        let grace = ContinuousClock.now + .milliseconds(400)
        while process.isRunning, ContinuousClock.now < grace { usleep(10_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
