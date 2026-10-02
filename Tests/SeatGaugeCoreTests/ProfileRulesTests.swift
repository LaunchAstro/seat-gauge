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

    /// The data volume's own path for a folder, which macOS firmlinks to the
    /// one under `/`. Path resolution never turns it back into the other.
    static func dataVolume(_ url: URL) throws -> String {
        // Foundation's own resolution drops `/private`, so ask the system.
        let real = try #require(realpath(url.path, nil))
        defer { free(real) }
        let data = "/System/Volumes/Data" + String(cString: real)
        try #require(FileManager.default.fileExists(atPath: data))
        return data
    }

    /// True when this volume takes `A` and `a` for one name.
    static func ignoresCase(_ folder: URL) -> Bool {
        pathconf(folder.path, _PC_CASE_SENSITIVE) == 0
    }

    @Test func theDefaultLoginUnderAnotherNameForItsVolumeOrItsCaseIsRefused() throws {
        // Before `~/.claude` exists and after, since a seat signed in to it
        // would make it.
        for made in [false, true] {
            let home = try Self.home()
            defer { try? FileManager.default.removeItem(at: home) }
            let main = home.appendingPathComponent(".claude", isDirectory: true)
            if made { try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true) }
            try FileManager.default.createDirectory(at: home.appendingPathComponent("sub"), withIntermediateDirectories: true)
            let data = try Self.dataVolume(home)
            var names = [data, data + "/", data + "/.claude", data + "/.claude/", data + "/./.claude",
                         data + "/other/../.claude", data + "//.claude", data + "/sub/missing/../../.claude",
                         home.path + "/missing/../sub/../.claude"]
            // A dangling link, and a link to that link, land where they point.
            let link = home.appendingPathComponent("linked")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: data + "/.claude")
            try FileManager.default.createSymbolicLink(atPath: home.path + "/relinked", withDestinationPath: "linked")
            names += [link.path, home.path + "/relinked", home.path + "/sub/../relinked/"]
            if Self.ignoresCase(home) {
                names += [home.path + "/.CLAUDE", home.path + "/.Claude/", data + "/.CLAUDE"]
            }
            for profile in names {
                let reason = Self.problem([Self.claude("work", profile: profile)], home: home)
                #expect(reason?.contains("default login") == true, "made \(made), \(profile): \(reason ?? "accepted")")
            }
            // A neighbour of the default login is a profile of its own.
            for profile in [".claude-work", ".claudex", "claude", ".claude.d", "work/.claude", "sub/.claude",
                            "sub/missing/../.claude"] {
                #expect(Self.problem([Self.claude("work", profile: data + "/" + profile)], home: home) == nil,
                        "made \(made), \(profile) refused")
            }
        }
    }

    @Test func oneProfileUnderTwoNamesIsRefusedWhetherOrNotItIsThereYet() throws {
        for made in [false, true] {
            let home = try Self.home()
            defer { try? FileManager.default.removeItem(at: home) }
            let shared = home.appendingPathComponent("profiles/shared", isDirectory: true)
            if made { try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true) }
            var others = [try Self.dataVolume(home) + "/profiles/shared", home.path + "/profiles/x/../shared"]
            if Self.ignoresCase(home) { others.append(home.path + "/PROFILES/Shared") }
            for other in others {
                let reason = Self.problem([Self.claude("work", profile: shared.path),
                                           Self.claude("personal", profile: other)], home: home)
                #expect(reason?.contains("same profile as \"work\"") == true, "made \(made), \(other): \(reason ?? "accepted")")
            }
            // Two folders side by side are two profiles.
            let config = try Self.decode([Self.claude("work", profile: shared.path),
                                          Self.claude("personal", profile: home.path + "/profiles/shared-2")], home: home)
            #expect(config.seats.count == 2)
        }
    }

    @Test func oneNameInTwoUnicodeFormsIsOneProfile() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        // "café" composed, and as "e" plus a combining accent.
        let reason = Self.problem([Self.claude("work", profile: home.path + "/caf\u{E9}"),
                                   Self.claude("personal", profile: home.path + "/cafe\u{301}")], home: home)
        #expect(reason?.contains("same profile as \"work\"") == true, "\(reason ?? "accepted")")
    }

    @Test func aProfileWhoseLinksGoRoundIsRefusedInOneSentence() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createSymbolicLink(atPath: home.path + "/a", withDestinationPath: "b")
        try FileManager.default.createSymbolicLink(atPath: home.path + "/b", withDestinationPath: "a")
        let reason = Self.problem([Self.claude("work", profile: home.path + "/a/work")], home: home)
        #expect(reason == "seats.json: the claude seat \"work\" has a profile whose path cannot be followed to a folder, since its links go round in a loop or it climbs out of a file; give it a directory of its own.")
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
        for path in [".claude/projects", "anywhere/work-profile/projects", "profiles/stray/projects"] {
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
