import Foundation
import Testing

import SeatGaugeCore

/// `seatgauge-cli login` against a fake `claude` that, like the real one,
/// takes the pasted code only from a terminal. The fake writes down every
/// call and the environment it got, so a refusal can be shown to have run
/// nothing and a sign-in to have reached only its own seat's profile.
@Suite struct SeatLoginTests {

    /// What the fake does once it has the code.
    enum Fake { case accepts(String), refuses, failsBeforePrompt }

    struct Scratch {
        let root: URL
        var home: URL { root.appendingPathComponent("home", isDirectory: true) }
        var calls: URL { root.appendingPathComponent("calls", isDirectory: true) }
        var bin: URL { root.appendingPathComponent("bin", isDirectory: true) }
        func profile(_ id: String) -> URL { home.appendingPathComponent("profiles/\(id)", isDirectory: true) }
        var parent: [String: String] { ["PATH": bin.path + ":/usr/bin:/bin", "HOME": home.path] }
        var ran: Bool { FileManager.default.fileExists(atPath: calls.appendingPathComponent("args").path) }
        func read(_ name: String) -> String {
            (try? String(contentsOf: calls.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    static func scratch(_ fake: Fake) throws -> Scratch {
        let scratch = Scratch(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-login-\(UUID().uuidString)", isDirectory: true))
        for directory in [scratch.home, scratch.calls, scratch.bin] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let afterCode = switch fake {
        case let .accepts(code): #"[ "$code" = "\#(code)" ] || exit 1; touch "$CLAUDE_CONFIG_DIR/.signed-in"; exit 0"#
        case .refuses, .failsBeforePrompt: "exit 1"
        }
        let beforePrompt = if case .failsBeforePrompt = fake { #"echo "OAuth error: no route" >&2; exit 2"# } else { ":" }
        // The link the real CLI prints, wrapped in a hyperlink and coloured.
        let script = #"""
        #!/bin/bash
        calls="\#(scratch.calls.path)"
        echo "$@" >> "$calls/args"
        env > "$calls/env-$2"
        [ -t 0 ] || { echo "stdin is not a terminal" >&2; exit 3; }
        case "$2" in
        login)
          \#(beforePrompt)
          printf 'Opening browser to sign in\nvisit: \e]8;;https://example.test/oauth/authorize?code=true&state=s1\e\\\e[94mhttps://example.test/oauth/authorize?code=true&state=s1\e[39m\e]8;;\e\\\n'
          printf 'Paste code here if prompted > '
          IFS= read -r code
          printf '%s' "$code" > "$calls/code"
          echo "Invalid code: $code"
          echo "Invalid code: $code" >&2
          \#(afterCode)
          ;;
        status)
          if [ -e "$CLAUDE_CONFIG_DIR/.signed-in" ]; then
            printf '{\n  "loggedIn": true,\n  "subscriptionType": "pro"\n}\n'; exit 0
          fi
          printf '{\n  "loggedIn": false\n}\n'; exit 1
          ;;
        esac
        """#
        let claude = scratch.bin.appendingPathComponent("claude")
        try script.write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        return scratch
    }

    static func seat(_ id: String, profile: URL, token: URL? = nil) -> Seat {
        Seat(id: SeatID(rawValue: id), label: id, kind: .claude(profileDir: profile), tokenFile: token)
    }

    /// The lines the command printed, gathered from any thread.
    final class Said: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        var all: String { lock.withLock { lines.joined(separator: "\n") } }
    }

    static func signIn(_ name: String, seats: [Seat], scratch: Scratch, email: String? = nil,
                       parent: [String: String]? = nil, code: String?, said: Said) throws -> SeatLogin.SignedIn {
        try SeatLogin.signIn(name, email: email, seats: seats, home: scratch.home,
                             parent: parent ?? scratch.parent, timeout: .seconds(20),
                             code: { code }, link: said.add)
    }

    static func refusal(_ body: () throws -> Any) -> String? {
        do { _ = try body(); return nil } catch { return "\(error)" }
    }

    // MARK: Refused before anything runs

    @Test func anUnknownSeatACodexSeatAndATokenSeatAreRefusedWithNothingRun() throws {
        let scratch = try Self.scratch(.accepts("c"))
        defer { scratch.remove() }
        let seats = [Self.seat("work", profile: scratch.profile("work")),
                     Seat(id: SeatID(rawValue: "codex"), label: "Codex", kind: .codex),
                     Self.seat("token", profile: scratch.profile("token"),
                               token: scratch.home.appendingPathComponent("token.token"))]
        let said = Said()
        let unknown = Self.refusal { try Self.signIn("nobody", seats: seats, scratch: scratch, code: "c", said: said) }
        #expect(unknown == "no seat named nobody. Seats: work, codex, token")
        let codex = Self.refusal { try Self.signIn("codex", seats: seats, scratch: scratch, code: "c", said: said) }
        #expect(codex == "codex is a Codex seat, which signs in with codex login, not claude.")
        let token = Self.refusal { try Self.signIn("token", seats: seats, scratch: scratch, code: "c", said: said) }
        #expect(token == "token signs in with a token. Give it \"login\": \"own\" in seats.json first, or its card will never read this login.")
        #expect(!scratch.ran)
        #expect(said.all.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: scratch.profile("token").path))
    }

    @Test func aProfileThatIsHomeTheDefaultLoginOrAnotherSeatsIsRefusedWithNothingRun() throws {
        let scratch = try Self.scratch(.accepts("c"))
        defer { scratch.remove() }
        let dotClaude = scratch.home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: dotClaude, withIntermediateDirectories: true)
        let link = scratch.home.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dotClaude)
        let said = Said()
        for profile in [scratch.home, dotClaude, scratch.home.appendingPathComponent("x/../.claude/"), link] {
            let reason = Self.refusal {
                try Self.signIn("work", seats: [Self.seat("work", profile: profile)], scratch: scratch,
                                code: "c", said: said)
            }
            #expect(reason == "work has the default login's directory as its profile, so signing it in would sign ~/.claude in instead. Give it a directory of its own.",
                    "\(profile.path)")
        }
        // On a volume that ignores case, another spelling is the same place.
        let shouted = scratch.home.appendingPathComponent(".CLAUDE", isDirectory: true)
        if FileManager.default.fileExists(atPath: shouted.path) {
            let reason = Self.refusal {
                try Self.signIn("work", seats: [Self.seat("work", profile: shouted)], scratch: scratch,
                                code: "c", said: said)
            }
            #expect(reason?.contains("default login") == true, "\(reason ?? "accepted")")
            try FileManager.default.createDirectory(at: scratch.profile("personal"), withIntermediateDirectories: true)
            let other = [Self.seat("personal", profile: scratch.profile("personal")),
                         Self.seat("work", profile: scratch.home.appendingPathComponent("PROFILES/PERSONAL"))]
            #expect(Self.refusal { try Self.signIn("work", seats: other, scratch: scratch, code: "c", said: said) }?
                .contains("same profile as personal") == true)
        }
        // Built by hand, since seats.json refuses two seats on one directory.
        let shared = [Self.seat("personal", profile: scratch.profile("personal")),
                      Self.seat("work", profile: scratch.profile("personal").appendingPathComponent("."))]
        let reason = Self.refusal { try Self.signIn("work", seats: shared, scratch: scratch, code: "c", said: said) }
        #expect(reason == "work has the same profile as personal, so signing one in would sign both in. Give each seat a directory of its own.")
        #expect(!scratch.ran)
        #expect(said.all.isEmpty)
    }

    @Test func aMalformedEmailIsRefusedWithNothingRun() throws {
        let scratch = try Self.scratch(.accepts("c"))
        defer { scratch.remove() }
        let seats = [Self.seat("work", profile: scratch.profile("work"))]
        let at = "@"
        for email in ["", "--console", "-x" + at + "example.test", "no-at-sign", "two words" + at + "example.test",
                      "line\nbreak" + at + "example.test", at + "example.test", "someone" + at, "a" + at + "b" + at + "c"] {
            let reason = Self.refusal {
                try Self.signIn("work", seats: seats, scratch: scratch, email: email, code: "c", said: Said())
            }
            #expect(reason == "the --email value is not an email address, so nothing was started.")
        }
        #expect(!scratch.ran)
        #expect(!FileManager.default.fileExists(atPath: scratch.profile("work").path))
    }

    // MARK: Signed in through a terminal

    @Test func theFakeTakesNoCodeFromAPipe() throws {
        // The proof the fake is as strict as the real CLI: piped, it refuses.
        let scratch = try Self.scratch(.accepts("c"))
        defer { scratch.remove() }
        let process = Process()
        process.executableURL = scratch.bin.appendingPathComponent("claude")
        process.arguments = ["auth", "login", "--claudeai"]
        process.standardInput = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 3)
    }

    @Test func aSeatSignsInThroughATerminalAndTheStatusProvesIt() throws {
        let marker = "PLANTED-CODE-\(UUID().uuidString)#state"
        let scratch = try Self.scratch(.accepts(marker))
        defer { scratch.remove() }
        let said = Said()
        let at = "@"
        let email = "someone" + at + "example.test"
        let signed = try Self.signIn("work", seats: [Self.seat("work", profile: scratch.profile("work"))],
                                     scratch: scratch, email: email, code: "  " + marker + "\n", said: said)
        #expect(signed == SeatLogin.SignedIn(email: nil, plan: "pro"))
        // The code went through whole and trimmed, compared without printing it.
        let arrived = scratch.read("code") == marker
        #expect(arrived, "the fake did not receive the pasted code as pasted")
        #expect(scratch.read("args") == "auth login --claudeai --email \(email)\nauth status --json\n")
        #expect(said.all.contains("https://example.test/oauth/authorize?code=true&state=s1"))
        #expect(!said.all.contains("\u{1b}"))
        // The fake printed the code back on stdout and stderr; none of it is said.
        let leaked = said.all.contains("PLANTED-CODE")
        #expect(!leaked, "the pasted code reached the command's output")
        // A fresh machine has no profile yet: it is made, for this user only.
        let made = try FileManager.default.attributesOfItem(atPath: scratch.profile("work").path)
        #expect((made[.posixPermissions] as? Int) == 0o700)
    }

    @Test func oneSeatsSignInNeverReachesAnother() throws {
        let scratch = try Self.scratch(.accepts("code-1"))
        defer { scratch.remove() }
        let tokenFile = scratch.home.appendingPathComponent("personal.token")
        try "PERSONAL-TOKEN-MARKER".write(to: tokenFile, atomically: true, encoding: .utf8)
        let seats = [Self.seat("personal", profile: scratch.profile("personal"), token: tokenFile),
                     Self.seat("work", profile: scratch.profile("work"))]
        var parent = scratch.parent
        parent["CLAUDE_CODE_OAUTH_TOKEN"] = "PARENT-TOKEN-MARKER"
        parent["CLAUDE_CONFIG_DIR"] = scratch.profile("personal").path
        parent["ANTHROPIC_API_KEY"] = "PARENT-KEY-MARKER"
        _ = try Self.signIn("work", seats: seats, scratch: scratch, parent: parent, code: "code-1", said: Said())
        for call in ["env-login", "env-status"] {
            let env = scratch.read(call)
            #expect(env.contains("CLAUDE_CONFIG_DIR=\(scratch.profile("work").path)\n"), "\(call)")
            #expect(!env.contains("MARKER"), "\(call) carried a token or key it was not given")
            #expect(!env.contains("CLAUDE_CODE_OAUTH_TOKEN"), "\(call)")
            #expect(!env.contains(scratch.profile("personal").path), "\(call)")
        }
        #expect(FileManager.default.fileExists(atPath: scratch.profile("work").appendingPathComponent(".signed-in").path))
        #expect(!FileManager.default.fileExists(atPath: scratch.profile("personal").path))
    }

    // MARK: Failures say why, never the code

    @Test func aRefusedCodeFailsWithoutTheCodeInAnyErrorOrLine() throws {
        let marker = "PLANTED-CODE-\(UUID().uuidString)"
        let scratch = try Self.scratch(.refuses)
        defer { scratch.remove() }
        let said = Said()
        let reason = Self.refusal {
            try Self.signIn("work", seats: [Self.seat("work", profile: scratch.profile("work"))],
                            scratch: scratch, code: marker, said: said)
        } ?? ""
        // Compared as a flag, so a failure here cannot print the code either.
        let worded = reason == "claude auth login stopped with status 1 after the code was sent, so work was not signed in. What it printed after the code is not shown, since it may repeat the code."
        #expect(worded, "the refusal is worded otherwise\(reason.contains("PLANTED-CODE") ? " and carries the code" : ": \(reason)")")
        let leaked = reason.contains("PLANTED-CODE") || said.all.contains("PLANTED-CODE")
        #expect(!leaked, "the pasted code reached an error or a line")
        #expect(!scratch.read("args").contains("status"))
    }

    @Test func noCodeOrAMalformedOneIsNeverSent() throws {
        for code: String? in [nil, "", "   ", "PLANTED-CODE one", "PLANTED-CODE\u{1b}[2J", "PLANTED-CODE\u{3}"] {
            let scratch = try Self.scratch(.accepts("x"))
            defer { scratch.remove() }
            let reason = Self.refusal {
                try Self.signIn("work", seats: [Self.seat("work", profile: scratch.profile("work"))],
                                scratch: scratch, code: code, said: Said())
            } ?? ""
            let expected = (code ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "no code was pasted, so work was not signed in."
                : "the pasted code has a space or a control character in it, so it was not sent and work was not signed in."
            let matched = reason == expected
            #expect(matched, "case \(code == nil ? "nil" : "\(code!.count) characters"): \(reason.contains("PLANTED") ? "the code leaked" : reason)")
            #expect(scratch.read("code").isEmpty)
        }
    }

    @Test func aLoginThatStopsBeforeThePromptSaysWhatItPrinted() throws {
        let scratch = try Self.scratch(.failsBeforePrompt)
        defer { scratch.remove() }
        let reason = Self.refusal {
            try Self.signIn("work", seats: [Self.seat("work", profile: scratch.profile("work"))],
                            scratch: scratch, code: "c", said: Said())
        }
        #expect(reason == "claude auth login stopped with status 2 before a code was sent, so work was not signed in: OAuth error: no route")
    }

    // MARK: The command line

    @Test func theArgumentsNameOneSeatAnEmailAndASeatsFile() throws {
        let at = "@"
        let email = "someone" + at + "example.test"
        #expect(try SeatLogin.Request(arguments: ["work"]) == .init(seat: "work", email: nil, seatsFile: nil))
        #expect(try SeatLogin.Request(arguments: ["work", "--email", email, "s.json"])
                == .init(seat: "work", email: email, seatsFile: "s.json"))
        #expect(try SeatLogin.Request(arguments: ["work", "s.json", "--email", email])
                == .init(seat: "work", email: email, seatsFile: "s.json"))
        for wrong in [[], ["--email", email], ["work", "--email"], ["work", "--sso"], ["work", "a.json", "b.json"]] {
            #expect(Self.refusal { try SeatLogin.Request(arguments: wrong) }
                    == "usage: seatgauge-cli login <seat> [--email <address>] [seats.json]")
        }
    }
}
