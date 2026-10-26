import Foundation
import Testing

import SeatGaugeCore
import SeatGaugeTestSupport

/// What `seatgauge-cli record` keeps of a seat's reply, and where it puts it.
/// A recording is a real seat's own usage, so only what the parsers read
/// survives, credentials never do, and the file is the user's alone, outside
/// every tracked folder of the clone.
@Suite struct RecordingTests {
    static func scratch() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-recording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func mode(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test("credential fields go, nested, escaped or in free text, and so does everything the parsers never read")
    func credentialsAndUnreadFieldsGo() {
        let lines = [
            #"{"token":"opaque-secret-a","authorization":"Bearer opaque-secret-b"}"#,
            #"{"type":"result","is_error":true,"result":"failed: {\"token\":\"opaque-secret-c\",\"authorization\":\"Bearer opaque-secret-d\"} and Authorization: Bearer opaque-secret-e, password=opaque-secret-f","nested":{"password":"opaque-secret-g","deeper":[{"api_key":"opaque-secret-h","cookie":"opaque-secret-i"}]},"refresh_token":"opaque-secret-j","access_token":"opaque-secret-k","secret":"opaque-secret-l","client_secret":"opaque-secret-m"}"#,
            #"{"type":"system","subtype":"init","organization":"Invented Widgets Pty Ltd","userId":"invented-user-7","chatgptAccountId":"invented-account-8","skills":["invented-skill"],"agents":["invented-agent"],"slash_commands":["/invented-command"],"mcp_servers":[{"name":"invented-server"}],"model":"claude-haiku-4-5"}"#,
            "Authorization: Bearer opaque-secret-n printed as plain text",
        ]
        let clean = lines.map(FixtureRecording.redact)
        let all = clean.joined(separator: "\n")
        // Compared through Bools, so a failure never prints a planted value.
        let leaked = all.contains("opaque-secret")
        #expect(!leaked)
        for unread in ["Invented Widgets", "invented-user", "invented-account", "invented-skill",
                       "invented-agent", "invented-command", "invented-server"] {
            let kept = all.contains(unread)
            #expect(!kept, "\(unread)")
        }
        // What the parsers read is kept, one line for each line read.
        #expect(clean.count == lines.count)
        #expect(clean[1].contains(#""is_error":true"#))
        // A kept string that mentions a credential goes whole.
        #expect(clean[1].contains(#""result":"[redacted]""#))
        #expect(clean[2].contains(#""subtype":"init""#))
        #expect(clean[2].contains("claude-haiku-4-5"))
    }

    @Test("a redacted transcript still reads to the same windows for every fixture seat")
    func redactedTranscriptsReadTheSame() async throws {
        let profile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("seat-gauge-recording-profile")
        let work = Seat(id: SeatID(rawValue: "work"), label: "Work", kind: .claude(profileDir: profile))
        let primer = URL(fileURLWithPath: "/tmp/seat-gauge-primer")
        for redacted in [false, true] {
            let batches = RunnerTests.batches(try Fixture.lines("own"),
                                              waitingFor: ["\"request_id\": \"1\"", "\"request_id\":\"2\""])
            let runner = ScriptedRunner(replies: redacted ? batches.map { $0.map(FixtureRecording.redact) } : batches)
            let claude = await ClaudeFetcher(runner: runner, primer: primer).fetch(work, now: .now, last: nil)
            #expect(RunnerTests.windows(claude.state).map(\.kind) == [.fiveHour, .weekly, .fable], "redacted: \(redacted)")
            #expect(RunnerTests.windows(claude.state).map(\.usedPercent).count == 3)

            let codexBatches = RunnerTests.batches(try Fixture.lines("codex"), waitingFor: ["\"id\":1", nil, "\"id\":2"])
            let codexRunner = ScriptedRunner(replies: redacted ? codexBatches.map { $0.map(FixtureRecording.redact) } : codexBatches)
            let codex = await CodexFetcher(runner: codexRunner, authFile: RunnerTests.authFile)
                .fetch(RunnerTests.codex, now: .now, last: nil)
            #expect(RunnerTests.windows(codex.state).map(\.usedPercent) == [90], "redacted: \(redacted)")
        }
        let raw = try Fixture.lines("own")
        let plain = await ClaudeFetcher(runner: ScriptedRunner(replies: RunnerTests.batches(raw, waitingFor: ["\"request_id\": \"1\"", "\"request_id\":\"2\""])), primer: primer).fetch(work, now: .now, last: nil)
        let clean = await ClaudeFetcher(runner: ScriptedRunner(replies: RunnerTests.batches(raw, waitingFor: ["\"request_id\": \"1\"", "\"request_id\":\"2\""]).map { $0.map(FixtureRecording.redact) }), primer: primer).fetch(work, now: .now, last: nil)
        #expect(RunnerTests.windows(plain.state) == RunnerTests.windows(clean.state))
    }

    @Test("a recording goes to .scratch/recordings, private to the user, and replaces only its own file")
    func recordingsAreOwnerOnlyAndOutsideTheFixtures() throws {
        let clone = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: clone) }
        let folder = clone.appendingPathComponent(".scratch/recordings", isDirectory: true)

        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 12))!
        let written = try FixtureRecording.write(["{}"], seat: SeatID(rawValue: "work"), date: day, into: folder)
        #expect(written.deletingLastPathComponent().path == folder.path)
        #expect(written.lastPathComponent == "work-2026-09-22.jsonl")
        #expect(try Self.mode(written) == 0o600)
        #expect(try Self.mode(folder) == 0o700)
        // A second recording that day replaces the first, still private.
        _ = try FixtureRecording.write(["{\"type\":\"result\"}"], seat: SeatID(rawValue: "work"), date: day, into: folder)
        #expect(try String(contentsOf: written, encoding: .utf8) == "{\"type\":\"result\"}\n")
        #expect(try Self.mode(written) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["work-2026-09-22.jsonl"])
    }

    @Test("a seat id that would leave the recordings folder writes nothing")
    func aClimbingIDWritesNothing() throws {
        let clone = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: clone) }
        let folder = clone.appendingPathComponent(".scratch/recordings", isDirectory: true)
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 12))!
        for id in ["../../escaped", "a/b", "/abs", ""] {
            #expect(throws: (any Error).self, "\(id)") {
                try FixtureRecording.write(["{}"], seat: SeatID(rawValue: id), date: day, into: folder)
            }
        }
        let left = FileManager.default.enumerator(atPath: clone.path)?.allObjects as? [String] ?? []
        #expect(left.allSatisfy { !$0.hasSuffix(".jsonl") })
    }

    @Test("Sol proof, criterion 2: a credential inside JSON written into a kept string goes, nested or with an escaped name")
    func embeddedJSONCredentialsGo() {
        let lines = [
            #"{"type":"result","result":"failed: {\"token\":{\"value\":\"opaque-secret-object\"}}"}"#,
            #"{"type":"result","result":"failed: {\"to\\u006ben\":\"opaque-secret-unicode\"}"}"#,
            #"{"type":"result","result":"failed: {\"password\":\"firstword secondword thirdword\"}"}"#,
            #"{"type":"result","result":"failed: {\"note\":\"an unclosed body \"token\":\"opaque-secret-open"}"#,
        ]
        let all = lines.map(FixtureRecording.redact).joined(separator: "\n")
        for planted in ["opaque-secret", "secondword", "thirdword"] {
            let kept = all.contains(planted)
            #expect(!kept, "\(planted)")
        }
    }

    @Test("Sol proof, criterion 2: a spaced API key, a quoted passphrase and an unsegmented sk- key go whole")
    func freeTextCredentialsGoWhole() {
        let key = "sk-" + String(repeating: "aB12", count: 12)
        let lines = [
            #"{"type":"result","result":"API key: opaque-secret-spaced"}"#,
            #"{"type":"result","result":"password: \"firstword secondword thirdword\" was refused"}"#,
            #"{"type":"result","result":"key supplied: \#(key)"}"#,
            #"{"type":"result","result":"Authorization: Basic b3BhcXVlLXNlY3JldC1iYXNpYw=="}"#,
            #"{"type":"result","result":"a run like Zx9Qw8Er7Ty6Ui5Op4As3Df2 is nobody's prose"}"#,
        ]
        let all = lines.map(FixtureRecording.redact).joined(separator: "\n")
        for planted in ["opaque-secret", "secondword", "thirdword", key, "b3BhcXVl", "Zx9Qw8Er7Ty6"] {
            let kept = all.contains(planted)
            #expect(!kept, "\(planted.prefix(8))")
        }
        // An error sentence that names nothing secret is kept as it was.
        #expect(FixtureRecording.redact(#"{"type":"result","result":"Not logged in · Please run /login"}"#)
                == #"{"result":"Not logged in · Please run /login","type":"result"}"#)
    }

    @Test("Sol proof, #116: a key label spaced twice, a bare key or keys label and a PIN go whole")
    func spacedAndBareKeyLabelsGoWhole() {
        let value = "k4N8q2R6v9T3m7W5"
        for text in ["API  key: \(value)", "private  key: \(value)", "key: \(value)", "PIN: 531862",
                     "keys: \(value)", "signing key \(value)", "pin code 531862",
                     "key_id \(value)", "KEY1 \(value)", "pin_code 531862", "PINs 531862",
                     // Opus read: a key or pin joined to the word beside it, camelCase or capitals.
                     "keyId: \(value)", "signingKeyId: \(value)", "keyMaterial: \(value)", "KeyHash: \(value)",
                     "userPIN: 531862", "MyPin: 531862", "SIMPIN 531862", "pinNumber: 531862", "PINnumber 531862"] {
            #expect(FixtureRecording.redact(#"{"id":0,"result":"\#(text)"}"#) == #"{"id":0,"result":"[redacted]"}"#,
                    "\(text.prefix(5))")
        }
        // Words that only contain the letters are prose, and stay.
        let prose = "Keychain locked, keyboard pinned, spinning up, Pinterest opinion"
        #expect(FixtureRecording.redact(#"{"id":0,"result":"\#(prose)"}"#) == #"{"id":0,"result":"\#(prose)"}"#)
    }

    @Test("Sol proof, criterion 1: mixed-case prefixed key labels and plural pincode labels redact whole, in every case mix")
    func mixedCasePrefixedKeyLabelsRedactWhole() {
        func mixes(_ word: String) -> [String] {
            word.reduce([""]) { done, letter in done.flatMap { [$0 + letter.lowercased(), $0 + letter.uppercased()] } }
        }
        // Every word the rule names, plural `pincodes` included (Sol round 3).
        for word in ["key", "keys", "pin", "pins", "pincode", "pincodes"].flatMap(mixes) {
            for prefix in ["", "signing", "user", "SIM", "my ", "API  "] {
                for suffix in [":", " ", "_id:", "Id:", "1:", "Number:"] {
                    let text = "\(prefix)\(word)\(suffix) 531862"
                    #expect(FixtureRecording.redact(#"{"id":0,"result":"\#(text)"}"#) == #"{"id":0,"result":"[redacted]"}"#,
                            "\(text)")
                }
            }
        }
    }

    @Test("#142: a key or pin spelt in look-alike letters, and an OTP, code, seed, signature or client id label, go whole")
    func lookAlikesAndOtherLabelsGoWhole() {
        let value = "k4N8q2R6v9T3m7W5"
        // Fullwidth, Cyrillic, dotted and dotless i, and a modifier-letter colon.
        for (index, text) in ["\u{FF4B}\u{FF45}\u{FF59}: \(value)", "\u{FF30}\u{FF29}\u{FF2E}: 531862",
                     "k\u{0435}y: \(value)", "p\u{0456}n: 531862", "P\u{0130}N: 531862", "p\u{0131}n: 531862",
                     "pin\u{02D0} 531862",
                     // Fullwidth brackets and a no-break space, refused before #142, stay refused.
                     "\u{FF3B}\(value)\u{FF3D}", "resets\u{00A0}soon", "Zx9Qw8Er7Ty6\u{2026}Ui5Op4As3Df2",
                     "OTP: 531862", "code: 531862", "code 531862", "Code - 531862", "code (531862)", "code. 531862",
                     "Code-531862", "your verification code is 531862",
                     "seed: \(value)", "seedphrase: abandon ability able", "mnemonic: abandon ability able",
                     "signature: \(value)", "client id: \(value)", "client  id: \(value)", "client - id: \(value)",
                     "client_id: \(value)", "client_ids: \(value)", "client__id: \(value)", "clientId: \(value)"].enumerated() {
            let line = String(decoding: try! JSONSerialization.data(withJSONObject: ["id": 0, "result": text]), as: UTF8.self)
            // A Bool, so a failure names the case by its place in the list and never prints any of its value.
            let redacted = FixtureRecording.redact(line) == #"{"id":0,"result":"[redacted]"}"#
            #expect(redacted, "case \(index)")
        }
        // A word that only contains the letters is prose, a Codex model keeps
        // its name, and a folder called code is not a label.
        let prose = "seeded cache, hotpot, client identity, gpt-5.1-codex-max, Claude Code in /home/seat/code"
        #expect(FixtureRecording.redact(#"{"id":0,"result":"\#(prose)"}"#) == #"{"id":0,"result":"\#(prose)"}"#)
    }

    @Test("#156, #154: a home or Mac name that hides a refused character or a credential label goes whole")
    func neutralisedNamesHideNothing() {
        let value = "k4N8q2R6v9T3m7W5"
        let users = "/" + "Users"
        // A home folder named with something the plain rule refuses: the
        // fullwidth quote, backslash and apostrophe of #156, a fullwidth letter, and every ASCII
        // character outside the plain set that the home rule swallows.
        let refused = ["\u{FF02}", "\u{FF3C}", "\u{FF07}", "\u{FF4B}"] + "#$&'*<=>@^`{|}~".map(String.init)
        let homes = refused.flatMap { ["/home/\($0)/ \(value)", "\(users)/a\($0)b/ \(value)"] }
        // A label the home or Mac name rule swallows (#154).
        for (index, text) in (homes + ["\(users)/pin: 531862", "token.local \(value)"]).enumerated() {
            let line = String(decoding: try! JSONSerialization.data(withJSONObject: ["id": 0, "result": text]), as: UTF8.self)
            // A Bool, so a failure names the case by its place in the list and never prints any of its value.
            let redacted = FixtureRecording.redact(line) == #"{"id":0,"result":"[redacted]"}"#
            #expect(redacted, "case \(index)")
        }
        // A plain home and Mac name are still made neutral and kept.
        #expect(FixtureRecording.redact(#"{"id":0,"result":"\#(users)/jo.smith-2/code on Jos-Mac.local"}"#)
                == #"{"id":0,"result":"/home/seat/code on seat-mac.local"}"#)
    }

    /// #158: home folders and Mac names spelt in ways the rules once read
    /// past, each with what it must become. The first four are the ticket's.
    static let oddSpellings: [(text: String, kept: String)] = {
        let users = "/" + "Users", home = "/" + "home"
        return [
            ("\(users)/./jsmith/x", "/home/seat/x"),
            ("\(users)//jsmith/x", "/home/seat/x"),
            ("/" + "users/jsmith/x", "/home/seat/x"),
            ("Jos-MacBook-Pro.local" + "domain", "seat-mac.local"),
            ("\(users)/.//./jsmith/x", "/home/seat/x"),
            ("\(home.uppercased())/jsmith/x", "/home/seat/x"),
            ("Jos_Mac.local", "seat-mac.local"),
            ("jos.mac.local", "seat-mac.local"),
            ("Jos-Mac.LOCAL", "seat-mac.local"),
        ]
    }()

    @Test("#158: a home or Mac name in an odd spelling is made neutral", arguments: oddSpellings.indices)
    func oddSpellingsKeepNoName(case index: Int) {
        let (text, kept) = Self.oddSpellings[index]
        let line = String(decoding: try! JSONSerialization.data(withJSONObject: ["id": 0, "result": text]), as: UTF8.self)
        // A Bool, so a failure names the case by its index and never prints the name.
        let neutral = FixtureRecording.redact(line) == #"{"id":0,"result":"\#(kept)"}"#
        #expect(neutral, "case \(index)")
    }

    /// #158: percent-encoding spells a home path, an email or a label's
    /// colon that the plain rule would see written out. The first three are the ticket's.
    static let percentEncoded = ["%2F" + "Users%2Fjsmith", "jsmith%40example.com", "code%3A531862",
                                 "%2f" + "users%2fjsmith", "%252F" + "Users%252Fjsmith"]

    @Test("#158: a percent-encoded string goes whole", arguments: percentEncoded.indices)
    func percentEncodingGoesWhole(case index: Int) {
        let line = String(decoding: try! JSONSerialization.data(withJSONObject: ["id": 0, "result": Self.percentEncoded[index]]),
                          as: UTF8.self)
        let redacted = FixtureRecording.redact(line) == #"{"id":0,"result":"[redacted]"}"#
        #expect(redacted, "case \(index)")
    }

    /// #158, from the Opus read of #161: a `..` step climbs out of one folder
    /// into another, back to a home root or past one, which no rule can follow.
    static let parentSteps: [String] = {
        let users = "/" + "Users", home = "/" + "home"
        return ["\(users)/../jsmith/x", "\(users)/..\(users)/jsmith/x", "\(home)/..\(users)/jsmith/x", "\(users)/..\(home)/jsmith/x",
                "\(users)/./..\(users)/jsmith", "\(users)/../\(users)/jsmith/x", "\(users)/Shared/../jsmith/x",
                "\(users)/jsmith/../otheruser/x", "..\(users)/jsmith", "\(users)/jsmith/x/.."]
    }()

    @Test("#158: a path with a .. step goes whole", arguments: parentSteps.indices)
    func aParentStepGoesWhole(case index: Int) {
        let line = String(decoding: try! JSONSerialization.data(withJSONObject: ["id": 0, "result": Self.parentSteps[index]]),
                          as: UTF8.self)
        let redacted = FixtureRecording.redact(line) == #"{"id":0,"result":"[redacted]"}"#
        #expect(redacted, "case \(index)")
    }

    /// Sol #161 r1: the wider rules took seconds on a long run before the
    /// length limit refused it. The bound is far above a refusal's
    /// microseconds and far below the 13 s such a run took at that head.
    @Test("#158: a long run of slashes or name characters goes at once", arguments: ["/", "_", "a", "."])
    func aLongRunGoesAtOnce(character: String) {
        let line = String(decoding: try! JSONSerialization.data(withJSONObject: ["id": 0, "result": String(repeating: character, count: 16_000)]),
                          as: UTF8.self)
        let started = ContinuousClock.now
        let redacted = FixtureRecording.redact(line) == #"{"id":0,"result":"[redacted]"}"#
        #expect(redacted)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test("#158: a percent sign in prose is kept")
    func aPercentInProseIsKept() {
        #expect(FixtureRecording.redact(#"{"id":0,"result":"90% of the weekly limit used"}"#)
                == #"{"id":0,"result":"90% of the weekly limit used"}"#)
        // Nor is an ellipsis written as dots a `..` step.
        #expect(FixtureRecording.redact(#"{"id":0,"result":"Loading... done."}"#) == #"{"id":0,"result":"Loading... done."}"#)
    }

    @Test("Sol proof, criterion 4: a recordings folder that is a link writes nothing and changes nothing outside")
    func aLinkedFolderWritesNothing() throws {
        let clone = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: clone) }
        let outside = clone.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let kept = outside.appendingPathComponent("work-2026-09-22.jsonl")
        try Data("must-preserve".utf8).write(to: kept)
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 12))!

        // The recordings folder itself a link, and then the folder above it.
        let folder = clone.appendingPathComponent(".scratch/recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        #expect(throws: (any Error).self) {
            try FixtureRecording.write(["{}"], seat: SeatID(rawValue: "work"), date: day, into: folder)
        }
        try FileManager.default.removeItem(at: folder.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: folder.deletingLastPathComponent(), withDestinationURL: outside)
        #expect(throws: (any Error).self) {
            try FixtureRecording.write(["{}"], seat: SeatID(rawValue: "work"), date: day, into: folder)
        }
        #expect(try String(contentsOf: kept, encoding: .utf8) == "must-preserve")
        #expect(try Self.mode(outside) == 0o755)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["work-2026-09-22.jsonl"])
    }

    @Test("Sol proof, criterion 2: an escaped-quote password, a quoted bearer and a cookie list go whole")
    func credentialSentencesGoWhole() {
        let lines = [
            #"{"type":"result","result":"password: \"firstword \\\"quoted\\\" secondword thirdword\" was refused"}"#,
            #"{"type":"result","result":"Authorization: Bearer \"opaque-secret-bearer\""}"#,
            #"{"type":"result","result":"Cookie: name=opaque-first; other=opaque-second"}"#,
        ]
        let all = lines.map(FixtureRecording.redact).joined(separator: "\n")
        for planted in ["opaque-secret", "opaque-first", "opaque-second", "secondword", "thirdword", "quoted"] {
            let kept = all.contains(planted)
            #expect(!kept, "\(planted)")
        }
    }

    @Test("seatgauge-cli record writes to .scratch/recordings under the folder it runs in, 600, and never into Tests/Fixtures")
    func theCLIRecordsIntoScratch() throws {
        let scratch = try SeatLoginTests.scratch(.accepts("unused"))
        defer { scratch.remove() }
        // A claude that prints the own-login fixture whatever it is asked.
        let reply = scratch.root.appendingPathComponent("reply.jsonl")
        try (try Fixture.lines("own").joined(separator: "\n") + "\n").write(to: reply, atomically: true, encoding: .utf8)
        let claude = scratch.bin.appendingPathComponent("claude")
        try "#!/bin/sh\ncat \"\(reply.path)\"\nsleep 1\n".write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        let seats = scratch.root.appendingPathComponent("seats.json")
        let entry: [String: Any] = ["id": "work", "label": "Work", "kind": "claude",
                                    "profile": scratch.profile("work").path, "login": "own"]
        try JSONSerialization.data(withJSONObject: ["seats": [entry]]).write(to: seats)
        let clone = scratch.root.appendingPathComponent("clone", isDirectory: true)
        try FileManager.default.createDirectory(at: clone.appendingPathComponent("Tests/Fixtures"), withIntermediateDirectories: true)

        let task = Process()
        task.executableURL = AttributionSeedTests.repository.appendingPathComponent(".build/debug/seatgauge-cli")
        task.arguments = ["record", "work", seats.path]
        task.currentDirectoryURL = clone
        task.environment = scratch.parent.merging(["SHELL": "/bin/sh", "CFFIXED_USER_HOME": scratch.home.path]) { $1 }
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        let deadline = Date(timeIntervalSinceNow: 60)
        while task.isRunning, Date() < deadline { usleep(50_000) }
        if task.isRunning { task.terminate() }
        task.waitUntilExit()

        #expect(task.terminationStatus == 0)
        let folder = clone.appendingPathComponent(".scratch/recordings", isDirectory: true)
        let written = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        #expect(written.count == 1 && written.allSatisfy { $0.hasPrefix("work-") && $0.hasSuffix(".jsonl") })
        if let name = written.first { #expect(try Self.mode(folder.appendingPathComponent(name)) == 0o600) }
        #expect(try Self.mode(folder) == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: clone.appendingPathComponent("Tests/Fixtures").path).isEmpty)
    }

    @Test("Sol proof, criterion 2: a single-quoted value, a long run with a non-ASCII letter, and 200 characters with a newline go whole")
    func plainRuleEdgesGoWhole() {
        let run = "Z\u{0445}9Qw8Er7Ty6Ui5Op4As3Df2Z\u{0445}9Qw8Er7Ty6Ui5Op4As3Df2"
        let long = String(repeating: "x", count: 200) + "\n"
        for value in ["'purple canyon finch'", run, long] {
            let line = String(decoding: try! JSONSerialization.data(withJSONObject: ["type": "result", "result": value]), as: UTF8.self)
            #expect(FixtureRecording.redact(line) == #"{"result":"[redacted]","type":"result"}"#, "\(value.prefix(6))")
        }
        #expect(FixtureRecording.redact(#"{"type":"result","result":"\#(String(repeating: "x", count: 200))"}"#)
                == #"{"result":"\#(String(repeating: "x", count: 200))","type":"result"}"#)
    }
}
