import Foundation
import Testing

import SeatGaugeCore
import SeatGaugeTestSupport

/// A token seat's login lives in an OAuth token, not in its profile
/// directory, so `ClaudeFetcher` has to export it or the CLI is not logged in.
/// Every case here writes its own token file holding a value invented for the
/// case. No case reads `~/.config/claude-seats`, and nothing prints a value.
@Suite struct TokenSeatTests {

    /// Not a token and not shaped like one, so a case that leaked it would be
    /// leaking a string that means nothing anywhere.
    static let dummy = "not-a-real-token-0123456789"

    static let profile = URL(fileURLWithPath: "/tmp/seat-gauge-profile-personal", isDirectory: true)
    static let primer = URL(fileURLWithPath: "/tmp/seat-gauge-primer")

    /// A directory of this case's own, removed when the case ends.
    static func temporary() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-token-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    static func write(_ contents: String, named name: String, into directory: URL) throws -> URL {
        let file = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file, options: .atomic)
        return file
    }

    static func seat(_ id: String, profileDir: URL, tokenFile: URL?) -> Seat {
        Seat(id: SeatID(rawValue: id), label: id.capitalized,
             kind: .claude(profileDir: profileDir), tokenFile: tokenFile)
    }

    /// The transcript a live seat prints, cut where the recipe waits: after the
    /// result line, and after the `request_id` 2 reply. The work fixture is a
    /// logged-in seat's transcript.
    static func replies() throws -> [[String]] {
        let lines = try Fixture.lines("work")
        // The line the recipe waits at, read as the fetcher reads it: an object
        // whose own type is `result`, not a line that mentions one.
        guard let result = lines.firstIndex(where: {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])??["type"]
                as? String == "result"
        }) else { return [[], lines, []] }
        return [[], Array(lines[...result]), Array(lines[lines.index(after: result)...])]
    }

    /// A launch that answers nothing, for the cases that only read the recipe.
    /// The short timeout is what ends the fetch, so no case waits a minute.
    static func silent(_ seat: Seat) async -> (spec: ProcessSpec?, fetched: Fetched) {
        let runner = ScriptedRunner()
        let fetched = await ClaudeFetcher(runner: runner, primer: primer,
                                          timeout: .milliseconds(20))
            .fetch(seat, now: .now, last: nil)
        return (runner.launched.first, fetched)
    }

    @Test("A seat with a token file runs with CLAUDE_CODE_OAUTH_TOKEN set from it")
    func tokenSeatCarriesItsToken() async throws {
        let directory = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = try Self.write(Self.dummy + "\n", named: "personal.token", into: directory)

        let launch = await Self.silent(Self.seat("personal", profileDir: Self.profile, tokenFile: token))
        let spec = try #require(launch.spec)
        #expect(spec.environment[SeatToken.variable] == Self.dummy)
        #expect(spec.environment["CLAUDE_CONFIG_DIR"] == Self.profile.path)
    }

    @Test("A seat with no token file runs exactly as it did, with no token set")
    func seatWithoutTokenIsUnchanged() async throws {
        let launch = await Self.silent(Self.seat("team", profileDir: Self.profile, tokenFile: nil))
        let spec = try #require(launch.spec)
        // Cleared, not merely unset: a token exported into the app's own
        // environment would otherwise sign this seat in as whoever owns it.
        #expect(spec.environment[SeatToken.variable] == nil)
        #expect(spec.environment["CLAUDE_CONFIG_DIR"] == Self.profile.path)
    }

    @Test("An empty or unreadable token file is an unreadable seat with a reason")
    func unreadableTokenFileIsSaidNotCrashed() async throws {
        let directory = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let empty = try Self.write("   \n", named: "personal.token", into: directory)
        let missing = directory.appendingPathComponent("gone.token")
        let last = Reading(seat: SeatID(rawValue: "personal"), windows: [], takenAt: .now, plan: nil)

        for (file, word) in [(empty, "is empty"), (missing, "could not be read")] {
            let runner = ScriptedRunner()
            let fetched = await ClaudeFetcher(runner: runner, primer: Self.primer,
                                              timeout: .milliseconds(20))
                .fetch(Self.seat("personal", profileDir: Self.profile, tokenFile: file),
                       now: .now, last: last)
            guard case let .unreadable(reason, held) = fetched.state else {
                Issue.record("\(file.lastPathComponent) did not read as unreadable"); continue
            }
            #expect(reason.contains(word))
            #expect(reason.contains(file.lastPathComponent))
            #expect(held == last)
            // Nothing is spawned when the seat cannot be signed in.
            #expect(runner.launched.isEmpty)
            #expect(fetched.lines.isEmpty)
        }
    }

    @Test("The lines a fetch keeps never carry the token value")
    func recordedLinesNeverCarryTheToken() async throws {
        let directory = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = try Self.write(Self.dummy, named: "personal.token", into: directory)

        let runner = ScriptedRunner(replies: try Self.replies())
        let fetched = await ClaudeFetcher(runner: runner, primer: Self.primer)
            .fetch(Self.seat("personal", profileDir: Self.profile, tokenFile: token),
                   now: .now, last: nil)
        guard case let .live(reading) = fetched.state else {
            Issue.record("the scripted seat did not read live"); return
        }
        #expect(!reading.windows.isEmpty)
        #expect(!fetched.lines.isEmpty)
        // The transcript, what was written to the seat, and the redaction the
        // recorder runs before a fixture reaches the disk.
        for line in fetched.lines + runner.sent + fetched.lines.map(FixtureRecording.redact) {
            #expect(!line.contains(Self.dummy))
        }
    }

    @Test("seats.json names a token source, and falls back to the seat's own file")
    func configReadsTokenSources() throws {
        let directory = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let personal = try Self.write(Self.dummy, named: "personal.token", into: directory)
        let named = try Self.write(Self.dummy, named: "elsewhere.token", into: directory)

        let file = """
            { "seats": [
                { "id": "work", "label": "Work", "kind": "claude", "profile": "~/.claude-seat-work",
                  "login": "own" },
                { "id": "personal", "label": "Personal", "kind": "claude", "profile": "~/.claude-seat-personal" },
                { "id": "team", "label": "Team", "kind": "claude", "profile": "~/.claude-seat-team",
                  "token": "\(named.path)" },
                { "id": "codex", "label": "Codex", "kind": "codex" } ] }
            """
        let config = try ConfigLoader.decode(Data(file.utf8), tokenDirectory: directory)
        let sources = Dictionary(uniqueKeysWithValues: config.seats.map { ($0.id.rawValue, $0.tokenFile) })
        #expect(sources["personal"] == personal)              // the default, which is there
        #expect(sources["team"] == named)        // the one the file names
        #expect(sources["work"] == .some(nil))    // owns its login, so never
        #expect(sources["codex"] == .some(nil))     // codex signs in its own way

        // A seat with no file of its own keeps today's behaviour exactly.
        let bare = try ConfigLoader.decode(Data(file.utf8),
                                           tokenDirectory: directory.appendingPathComponent("empty"))
        #expect(bare.seats.first { $0.id.rawValue == "personal" }?.tokenFile == nil)

        // A seat with no profile is told, rather than quietly handed a token.
        let wrong = #"{ "seats": [ { "id": "work", "label": "N", "kind": "claude", "token": "/x" } ] }"#
        #expect(throws: ConfigProblem.self) {
            try ConfigLoader.decode(Data(wrong.utf8), tokenDirectory: directory)
        }
    }
}
