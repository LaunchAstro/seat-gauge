import Foundation
import Testing

@testable import SeatGaugeCore

/// "Every Claude seat has its own login", asked one way by all three checks:
/// `seats.json`, first launch and Sign in. A profile is refused when it is the
/// home, `~/.claude` or anything inside `~/.claude`, or another seat's, under
/// any name for the same place.
@Suite struct ProfilePlaceTests {
    struct Home {
        let url: URL
        var main: URL { url.appendingPathComponent(".claude", isDirectory: true) }

        init(made: Bool) throws {
            url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("seat-gauge-place-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url.appendingPathComponent("sub"),
                                                    withIntermediateDirectories: true)
            if made { try FileManager.default.createDirectory(at: main.appendingPathComponent("projects"),
                                                              withIntermediateDirectories: true) }
        }

        func remove() { try? FileManager.default.removeItem(at: url) }
        func link(_ name: String, to target: String) throws {
            try FileManager.default.createSymbolicLink(atPath: url.path + "/" + name, withDestinationPath: target)
        }
    }

    static func claude(_ id: String, _ profile: String) -> String {
        #"{ "id": "\#(id)", "label": "\#(id)", "kind": "claude", "profile": "\#(profile)", "login": "own" }"#
    }

    /// Why `seats.json` refuses these seats, or nil.
    static func config(_ seats: [String], home: Home) -> String? {
        let text = "{ \"seats\": [\(seats.joined(separator: ", "))] }"
        do {
            _ = try ConfigLoader.decode(Data(text.utf8), tokenDirectory: home.url.appendingPathComponent("tokens"),
                                        home: home.url)
            return nil
        } catch { return (error as? ConfigProblem)?.reason ?? "\(error)" }
    }

    /// Why Sign in refuses the first of these seats, or nil.
    static func login(_ profiles: [String], home: Home) -> String? {
        let seats = profiles.enumerated().map { index, path in
            Seat(id: SeatID(rawValue: "s\(index)"), label: "s\(index)", kind: .claude(profileDir: URL(fileURLWithPath: path)))
        }
        do { _ = try SeatLogin.profile(of: "s0", in: seats, home: home.url); return nil } catch {
            return (error as? ProcessFailure)?.reason ?? "\(error)"
        }
    }

    /// The data volume's own path for a folder, which macOS firmlinks to the
    /// one under `/`.
    static func dataVolume(_ url: URL) throws -> String {
        let real = try #require(realpath(url.path, nil))
        defer { free(real) }
        let data = "/System/Volumes/Data" + String(cString: real)
        try #require(FileManager.default.fileExists(atPath: data))
        return data
    }

    /// Names for `~/.claude` (`inside` empty) or a folder inside it, in every
    /// form the checks know: as written, `.`, `..`, a doubled slash, the data
    /// volume, a link, a dangling link, a link to a link, a link's own `..`,
    /// another case and another Unicode form.
    static func forms(_ home: Home, inside: String) throws -> [String] {
        let data = try dataVolume(home.url)
        let tail = inside.isEmpty ? "" : "/" + inside
        var names = [home.url.path + "/.claude" + tail, home.url.path + "/./.claude" + tail,
                     home.url.path + "/sub/../.claude" + tail, home.url.path + "//.claude" + tail,
                     data + "/.claude" + tail, data + "/sub/missing/../../.claude" + tail,
                     home.url.path + "/.CLAUDE" + tail, home.url.path + "/.Claude" + tail.uppercased()]
        let link = "l\(abs(inside.hashValue))"
        try home.link(link, to: data + "/.claude" + tail)
        try home.link(link + "-again", to: link)
        try home.link(link + "-climb", to: "sub/missing/../../.claude" + tail)
        names += [home.url.path + "/" + link, home.url.path + "/" + link + "-again",
                  home.url.path + "/sub/../" + link + "-again/", home.url.path + "/" + link + "-climb"]
        if !inside.isEmpty {
            // "é" as one scalar and as e plus a combining accent.
            names += [home.url.path + "/.claude/caf\u{E9}", home.url.path + "/.claude/cafe\u{301}"]
        }
        return names
    }

    @Test("a profile inside ~/.claude is refused by seats.json, Sign in and first launch alike")
    func refusesAProfileInsideTheDefaultLogin() throws {
        for made in [false, true] {
            let home = try Home(made: made)
            defer { home.remove() }
            for profile in try Self.forms(home, inside: "work") + [home.main.path + "/projects/x"] {
                let said = Self.config([Self.claude("work", profile)], home: home)
                #expect(said?.contains("default login") == true, "made \(made), \(profile): \(said ?? "accepted")")
                #expect(Self.login([profile], home: home)?.contains("default login") == true,
                        "made \(made), \(profile): sign in accepted")
                #expect(ProfilePlace.isDefaultLogin(URL(fileURLWithPath: profile), home: home.url))
            }
        }
    }

    @Test("the home and ~/.claude stay refused through every form, made or not")
    func defaultLoginThroughEveryForm() throws {
        for made in [false, true] {
            let home = try Home(made: made)
            defer { home.remove() }
            let data = try Self.dataVolume(home.url)
            for profile in try Self.forms(home, inside: "") + [home.url.path, home.url.path + "/", data, data + "/"] {
                #expect(Self.config([Self.claude("work", profile)], home: home)?.contains("default login") == true,
                        "made \(made), \(profile)")
                #expect(Self.login([profile], home: home)?.contains("default login") == true, "made \(made), \(profile)")
            }
            // Neighbours of the default login, and the home's other folders, are profiles of their own.
            for name in [".claude-work", ".claudex", "claude", ".claude.d", "work/.claude", "sub/.claude",
                         "sub/missing/../.claude", ".seat-gauge/profiles/work"] {
                let profile = data + "/" + name
                #expect(Self.config([Self.claude("work", profile)], home: home) == nil, "made \(made), \(name) refused")
                #expect(Self.login([profile], home: home) == nil, "made \(made), \(name) refused by sign in")
            }
        }
    }

    @Test("two seats on one place are refused through every form, whether or not it is there yet")
    func sameProfileThroughEveryForm() throws {
        for made in [false, true] {
            let home = try Home(made: made)
            defer { home.remove() }
            let work = home.url.appendingPathComponent("profiles/work")
            if made { try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true) }
            try FileManager.default.createDirectory(at: home.url.appendingPathComponent("profiles"),
                                                    withIntermediateDirectories: true)
            let data = try Self.dataVolume(home.url)
            try home.link("w", to: work.path)
            try home.link("w2", to: "w")
            let others = [work.path + "/", home.url.path + "/profiles/./work", home.url.path + "/sub/../profiles/work",
                          data + "/profiles/work", home.url.path + "/w", home.url.path + "/w2",
                          home.url.path + "/profiles/WORK", home.url.path + "/PROFILES/Work"]
            for other in others {
                let said = Self.config([Self.claude("one", work.path), Self.claude("two", other)], home: home)
                #expect(said?.contains("same profile") == true, "made \(made), \(other): \(said ?? "accepted")")
                #expect(Self.login([work.path, other], home: home)?.contains("same profile") == true,
                        "made \(made), \(other): sign in accepted")
            }
            // Two Unicode forms of one name are one place.
            let composed = home.url.path + "/profiles/caf\u{E9}", decomposed = home.url.path + "/profiles/cafe\u{301}"
            #expect(Self.config([Self.claude("one", composed), Self.claude("two", decomposed)], home: home) != nil)
            #expect(Self.login([composed, decomposed], home: home) != nil)
            #expect(Self.config([Self.claude("one", work.path), Self.claude("two", work.path + "-two")], home: home) == nil)
            // Sign in is handed a seat list built any way at all, so another
            // seat whose path cannot be walked still counts by the name the
            // CLI would join it to.
            try Data().write(to: home.url.appendingPathComponent("profiles/file"))
            try home.link("profiles/loop", to: "loop")
            for other in [home.url.path + "/profiles/file/../work", home.url.path + "/profiles/loop/../work"] {
                #expect(Self.login([work.path, other], home: home)?.contains("same profile") == true,
                        "made \(made), \(other): sign in accepted")
            }
        }
    }

    @Test("first launch lists a profile exactly when seats.json and Sign in would take it")
    func allThreeAskOneRule() throws {
        let home = try Home(made: true)
        defer { home.remove() }
        let root = home.url.appendingPathComponent(SeatDiscovery.profileFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try Self.dataVolume(home.url)
        let elsewhere = home.url.appendingPathComponent("elsewhere/work")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        // Each profile folder is a link, so first launch meets every target.
        let targets = ["inside": home.main.appendingPathComponent("projects").path, "main": home.main.path,
                       "home": home.url.path, "data": data + "/.claude/projects", "elsewhere": elsewhere.path,
                       "own": root.path + "/../own-profile"]
        try FileManager.default.createDirectory(atPath: root.path + "/../own-profile", withIntermediateDirectories: true)
        for (name, target) in targets {
            try FileManager.default.createSymbolicLink(atPath: root.path + "/" + name, withDestinationPath: target)
        }
        let listed = Set(SeatDiscovery(home: home.url, codexLogin: home.url.appendingPathComponent("none"))
            .seats().map(\.id))
        for (name, target) in targets {
            let configTakes = Self.config([Self.claude("work", target)], home: home) == nil
            let loginTakes = Self.login([target], home: home) == nil
            #expect(configTakes == loginTakes, "\(name)")
            #expect(listed.contains(name) == configTakes, "\(name): listed \(listed.contains(name)), config \(configTakes)")
        }
        #expect(listed == ["elsewhere", "own"])
    }
}
