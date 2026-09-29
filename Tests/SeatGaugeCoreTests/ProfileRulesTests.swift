import Foundation
import Testing

import SeatGaugeCore

/// Every Claude seat reads a login of its own: the config refuses a profile
/// that is the default login's or another seat's, and spend history walks the
/// profiles the config names, wherever they are.
@Suite struct ProfileRulesTests {

    static func home() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-profiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    static func decode(_ seats: [String], home: URL) throws -> Config {
        let text = "{ \"seats\": [\(seats.joined(separator: ", "))] }"
        return try ConfigLoader.decode(Data(text.utf8), tokenDirectory: home.appendingPathComponent("tokens"),
                                       home: home)
    }

    static func claude(_ id: String, profile: String) -> String {
        #"{ "id": "\#(id)", "label": "\#(id)", "kind": "claude", "profile": "\#(profile)", "login": "own" }"#
    }

    static func problem(_ seats: [String], home: URL) -> String? {
        do { _ = try decode(seats, home: home); return nil } catch {
            return (error as? ConfigProblem)?.reason
        }
    }

    @Test func aProfileThatIsTheDefaultLoginIsRefused() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"),
                                                withIntermediateDirectories: true)
        for profile in [home.path, home.path + "/", home.path + "/.claude", home.path + "/.claude/",
                        home.path + "/./.claude", home.path + "/other/../.claude"] {
            let reason = Self.problem([Self.claude("work", profile: profile)], home: home)
            #expect(reason?.contains("default login") == true, "\(profile): \(reason ?? "accepted")")
        }
        // A symlink to it is the same place.
        let link = home.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.appendingPathComponent(".claude"))
        #expect(Self.problem([Self.claude("work", profile: link.path)], home: home) != nil)
        // Anything else is a profile.
        let config = try Self.decode([Self.claude("work", profile: home.path + "/profiles/work")], home: home)
        #expect(config.seats.count == 1)
    }

    @Test func twoSeatsOnOneProfileAreRefusedInOneSentence() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let reason = Self.problem([Self.claude("work", profile: home.path + "/shared"),
                                   Self.claude("personal", profile: home.path + "/shared/")], home: home)
        #expect(reason == "seats.json: \"personal\" has the same profile as \"work\", so both cards would read one login; give each seat a directory of its own.")
        #expect(reason?.filter { $0 == "." }.count == 2)   // the file name's and the full stop
    }

    @Test func aClaudeSeatCannotTakeANameSpendHistoryKeeps() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        for id in ["default", "codex"] {
            #expect(Self.problem([Self.claude(id, profile: home.path + "/p")], home: home) != nil, "\(id)")
        }
        // A Codex seat is still called codex.
        let config = try Self.decode([#"{ "id": "codex", "label": "Codex", "kind": "codex" }"#], home: home)
        #expect(config.seats.first?.historyName == "codex")
    }

    @Test func spendWalksTheConfiguredProfilesWhereverTheyAre() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        for path in [".claude/projects", "anywhere/work-profile/projects", ".claude-seat-stray/projects"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(path),
                                                    withIntermediateDirectories: true)
        }
        let seats = [
            Seat(id: SeatID(rawValue: "work"), label: "Work",
                 kind: .claude(profileDir: home.appendingPathComponent("anywhere/work-profile"))),
            Seat(id: SeatID(rawValue: "empty"), label: "Empty",
                 kind: .claude(profileDir: home.appendingPathComponent("nothing-here"))),
            Seat(id: SeatID(rawValue: "codex"), label: "Codex", kind: .codex),
        ]
        let found = SpendProfile.from(seats: seats, home: home)
        // The default login, then each seat with transcripts, under its id. A
        // directory no seat names is not walked, whatever it is called.
        #expect(found.map(\.seat) == ["default", "work"])
        #expect(found.last?.projects.path == home.appendingPathComponent("anywhere/work-profile/projects").path)
        #expect(seats.map(\.historyName) == ["work", "empty", "codex"])
    }
}
