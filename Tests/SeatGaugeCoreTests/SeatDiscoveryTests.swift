import Foundation
import Testing

import SeatGaugeCore

/// First launch seeds `seats.json` from what is on the machine: each profile
/// folder under the app's profile root and a signed-in codex, found by name
/// and existence alone, or one fresh Claude seat when no profile is there.
/// Every case builds an invented machine in a temporary folder: a home, a
/// token directory and a codex login.
@Suite struct SeatDiscoveryTests {

    /// A planted credential. It is in every login and token file a case
    /// makes, and must never reach the seeded file.
    static let marker = "sk-ant-oat01-SEATGAUGE-PLANTED-MARKER"

    struct Machine {
        let root: URL
        var home: URL { root.appendingPathComponent("home", isDirectory: true) }
        var profiles: URL { home.appendingPathComponent(".seat-gauge/profiles", isDirectory: true) }
        var tokens: URL { root.appendingPathComponent("tokens", isDirectory: true) }
        var codexLogin: URL { root.appendingPathComponent("codex/auth.json") }
        var seats: URL { root.appendingPathComponent("support/seats.json") }
        var discovery: SeatDiscovery { SeatDiscovery(home: home, codexLogin: codexLogin) }
        var loader: ConfigLoader { ConfigLoader(file: seats, machine: discovery) }

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("seat-gauge-seed-\(UUID().uuidString)", isDirectory: true)
            for folder in [home, tokens, codexLogin.deletingLastPathComponent()] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
        }

        /// A profile under the root, with a login file in it that nothing may
        /// read: the file and the profile itself are mode 000.
        @discardableResult
        func profile(_ name: String, in folder: URL? = nil) throws -> URL {
            let directory = (folder ?? profiles).appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.sealed(Data(#"{"oauthAccount":{"accountUuid":"\#(marker)"}}"#.utf8),
                            at: directory.appendingPathComponent(".claude.json"))
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
            return directory
        }

        func link(_ name: String, to target: String) throws {
            try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: profiles.appendingPathComponent(name).path,
                                                       withDestinationPath: target)
        }

        func token(_ id: String) throws {
            try Self.sealed(Data(marker.utf8), at: tokens.appendingPathComponent("\(id).token"))
        }

        func signInCodex() throws {
            try Self.sealed(Data(#"{"tokens":{"id_token":"\#(marker)"}}"#.utf8), at: codexLogin)
        }

        static func sealed(_ data: Data, at file: URL) throws {
            try data.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        }

        /// Mode 000 folders cannot be listed, so open everything up first.
        func remove() {
            for folder in [home, profiles] {
                for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                    chmod(folder.appendingPathComponent(name).path, 0o700)
                }
            }
            if let walk = FileManager.default.enumerator(atPath: root.path) {
                for case let path as String in walk {
                    chmod(root.appendingPathComponent(path).path, 0o700)
                }
            }
            try? FileManager.default.removeItem(at: root)
        }

        /// The seeded text decoded as the app will decode it, against this
        /// machine's home and token directory.
        func decode(_ text: String) throws -> Config {
            try ConfigLoader.decode(Data(text.utf8), tokenDirectory: tokens, home: home)
        }
    }

    static func profile(_ seat: Seat) -> String? {
        guard case let .claude(directory) = seat.kind else { return nil }
        return directory.resolvingSymlinksInPath().path
    }

    static func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    // MARK: - What is under the profile root is seeded, and nothing is read

    @Test func seedsTheProfilesUnderTheRootAndCodexAndReadsNoLogin() throws {
        let machine = try Machine()
        defer { machine.remove() }
        let work = try machine.profile("work")
        let team = try machine.profile("team")
        try machine.signInCodex()
        // Profiles named some other way, and token files, are not the app's.
        try machine.profile(".claude-seat-other", in: machine.home)
        try machine.token("other")
        try machine.token("work")

        let config = try machine.loader.loadOrCreate()
        let written = try String(contentsOf: machine.seats, encoding: .utf8)
        #expect(config.seats.map(\.id.rawValue) == ["team", "work", "codex"])
        #expect(config.seats.map(\.label) == ["Team", "Work", "Codex"])
        #expect(config.seats.compactMap(Self.profile) == [team, work].map(Self.resolved))
        #expect(config.pollMinutes == 5)
        #expect(written.contains("// "))
        #expect(!written.contains(Self.marker))
        #expect(!written.contains(".claude-seat-other"))
        // The file passes the loader's own rules as it is, and no seat in it
        // takes a token, whatever lies in the token directory.
        let decoded = try machine.decode(written)
        #expect(decoded.seats.map(\.id) == config.seats.map(\.id))
        #expect(decoded.seats.allSatisfy { $0.tokenFile == nil })
    }

    @Test func theProfileRootIsUnderTheHomeAndOutsideTheDefaultLogin() {
        let root = SeatDiscovery().profileRoot.standardizedFileURL.path
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        #expect(root == home + "/.seat-gauge/profiles")
        #expect(!root.hasPrefix(home + "/.claude/") && !root.hasPrefix(home + "/.claude-"))
    }

    @Test func codexIsSeededOnlyWhenItIsSignedIn() throws {
        let machine = try Machine()
        defer { machine.remove() }
        try machine.profile("work")
        // Codex's folder with no login in it is not a signed-in codex.
        try FileManager.default.createDirectory(at: machine.codexLogin.deletingLastPathComponent()
            .appendingPathComponent("sessions"), withIntermediateDirectories: true)
        #expect(machine.discovery.seats().map(\.id) == ["work"])
        try machine.signInCodex()
        #expect(machine.discovery.seats().map(\.id) == ["work", "codex"])
    }

    // MARK: - No Claude profile: one fresh seat that owns its login

    @Test func anEmptyHomeSeedsOneFreshClaudeSeatThatOwnsItsLogin() throws {
        let machine = try Machine()
        defer { machine.remove() }
        // A token file under the fresh seat's name is not taken.
        try machine.token(SeatDiscovery.freshSeat)

        let config = try machine.loader.loadOrCreate()
        let written = try String(contentsOf: machine.seats, encoding: .utf8)
        let fresh = machine.profiles.appendingPathComponent(SeatDiscovery.freshSeat, isDirectory: true)
        #expect(config.seats.map(\.id.rawValue) == ["claude"])
        #expect(config.seats.map(\.label) == ["Claude"])
        #expect(config.seats.compactMap(Self.profile) == [Self.resolved(fresh)])
        #expect(written.contains(#""login": "own""#))
        let decoded = try machine.decode(written)
        #expect(decoded.seats.map(\.id.rawValue) == ["claude"])
        #expect(decoded.seats.first?.tokenFile == nil)
        // The profile is made, private to the user, and empty: the card is
        // dormant until step 3 signs it in.
        let made = try FileManager.default.attributesOfItem(atPath: fresh.path)
        #expect(made[.type] as? FileAttributeType == .typeDirectory)
        #expect((made[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fresh.path).isEmpty)

        // The comments walk the four steps in order, in plain words.
        let steps = ["// 1. ", "// 2. ", "// 3. ", "// 4. "].map { written.range(of: $0)?.lowerBound }
        #expect(steps.allSatisfy { $0 != nil })
        #expect(steps.compactMap { $0 } == steps.compactMap { $0 }.sorted())
        #expect(written.contains("~/.seat-gauge/profiles"))
        for team in ["claude-seat", "claude-seats", ".token", "hey", "nathan", "houston", "herdr", "/opt/homebrew"] {
            #expect(!written.contains(team), "\(team) in the template")
        }
    }

    @Test func aSignedInCodexAloneStillGetsAFreshClaudeSeat() throws {
        let machine = try Machine()
        defer { machine.remove() }
        try machine.signInCodex()
        #expect(machine.discovery.seats().map(\.id) == ["claude", "codex"])
        #expect(try machine.decode(machine.loader.seed()).seats.map(\.id.rawValue) == ["claude", "codex"])
    }

    @Test func whenTheFreshNameIsTakenTheFileSaysHowToAddASeat() throws {
        let machine = try Machine()
        defer { machine.remove() }
        let main = machine.home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        // Each blocks the fresh profile's path with something that is not a profile.
        let blockers: [(String, () throws -> Void)] = [
            ("a file", { try Data().write(to: machine.profiles.appendingPathComponent("claude")) }),
            ("a link to the default login", { try machine.link("claude", to: main.path) }),
            ("a link to nowhere", { try machine.link("claude", to: machine.root.appendingPathComponent("gone").path) }),
        ]
        for (name, block) in blockers {
            try? FileManager.default.removeItem(at: machine.profiles)
            try FileManager.default.createDirectory(at: machine.profiles, withIntermediateDirectories: true)
            try block()
            let config = try machine.decode(machine.loader.seed())
            #expect(config.seats.isEmpty, "\(name)")
            #expect(machine.loader.seed() == ConfigLoader.template, "\(name)")
        }
        #expect(ConfigLoader.template.contains("No seat was found"))
        #expect(ConfigLoader.template.contains(#"// { "id": "work", "label": "Work", "kind": "claude", "profile": "~/.seat-gauge/profiles/work", "login": "own" },"#))
        #expect(ConfigLoader.template.contains(#"// { "id": "codex", "label": "Codex", "kind": "codex" },"#))
        #expect(try machine.decode(ConfigLoader.template).pollMinutes == 5)
    }

    // MARK: - Hostile machines: links, two names for one place, odd names

    @Test func aProfileThatIsTheDefaultLoginUnderAnyNameIsNotSeeded() throws {
        let machine = try Machine()
        defer { machine.remove() }
        let main = machine.home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: main.appendingPathComponent("projects"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: machine.home.appendingPathComponent("other"),
                                                withIntermediateDirectories: true)
        try machine.profile("work")
        try machine.link("main", to: main.path)
        try machine.link("relative", to: "../../.claude")
        try machine.link("slash", to: main.path + "/")
        try machine.link("dotted", to: machine.home.path + "/./other/../.claude")
        try machine.link("inside", to: main.appendingPathComponent("projects").path)
        try machine.link("home", to: machine.home.path)
        try machine.link("up", to: "../..")
        // The data volume's own name for the same folder, which no path
        // resolution turns back into the home's.
        let data = "/System/Volumes/Data/private" + Self.resolved(main)
        if FileManager.default.fileExists(atPath: data) { try machine.link("firmlink", to: data) }

        let written = machine.loader.seed()
        #expect(machine.discovery.seats().map(\.id) == ["work"])
        #expect(try machine.decode(written).seats.map(\.id.rawValue) == ["work"])
        for name in ["main", "relative", "slash", "dotted", "inside", "home", "up", "firmlink"] {
            #expect(!written.contains("profiles/\(name)\""), "\(name) was seeded")
        }
    }

    @Test func aProfileRootThatIsTheDefaultLoginOrTheHomeSeedsNoClaudeSeat() throws {
        for target in [".claude", ".", ".claude/projects"] {
            let machine = try Machine()
            defer { machine.remove() }
            for folder in [".claude/projects", ".claude/todos", "work", ".seat-gauge"] {
                try FileManager.default.createDirectory(at: machine.home.appendingPathComponent(folder),
                                                        withIntermediateDirectories: true)
            }
            try FileManager.default.createSymbolicLink(atPath: machine.profiles.path,
                                                       withDestinationPath: machine.home.appendingPathComponent(target).path)
            try machine.signInCodex()
            #expect(machine.discovery.seats().map(\.id) == ["codex"], "root at \(target)")
            #expect(try machine.decode(machine.loader.seed()).seats.map(\.id.rawValue) == ["codex"])
        }
    }

    @Test func twoNamesForOnePlaceSeedOneSeat() throws {
        let machine = try Machine()
        defer { machine.remove() }
        let work = try machine.profile("work")
        // A link that sorts before the real folder still gives way to it.
        try machine.link("aaa", to: work.path)
        try machine.link("zzz", to: "aaa")
        // Two links to one profile kept elsewhere: the first by name stays.
        let elsewhere = machine.root.appendingPathComponent("elsewhere/profile", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try machine.link("q", to: elsewhere.path)
        try machine.link("p", to: elsewhere.path)

        let written = machine.loader.seed()
        #expect(machine.discovery.seats().map(\.id) == ["p", "work"])
        let config = try machine.decode(written)
        #expect(config.seats.map(\.id.rawValue) == ["p", "work"])
        #expect(Set(config.seats.compactMap(Self.profile)).count == 2)
    }

    @Test func anOddOrReservedNameIsNotSeededAndNeverReachesTheFile() throws {
        let machine = try Machine()
        defer { machine.remove() }
        try machine.profile("work")
        let odd = ["Work2", "TEAM", "default", "codex", "a b", "q\"uote", "back\\slash", "new\nline",
                   "tab\there", "caf\u{E9}", "dot.ted", ".hidden", "-dash", "_under", "x*y", "\u{2028}",
                   "\u{FF57}ork"]
        for name in odd { try machine.profile(name) }
        // Not folders: a file, a link to nowhere, a link to itself and a link to a file.
        try Data().write(to: machine.profiles.appendingPathComponent("file"))
        try machine.link("gone", to: machine.root.appendingPathComponent("missing").path)
        try machine.link("loop", to: "loop")
        try Data().write(to: machine.root.appendingPathComponent("plain"))
        try machine.link("filelink", to: machine.root.appendingPathComponent("plain").path)

        let written = machine.loader.seed()
        #expect(machine.discovery.seats().map(\.id) == ["work"])
        #expect(try machine.decode(written).seats.map(\.id.rawValue) == ["work"])
        for name in odd + ["file", "gone", "loop", "filelink"] {
            #expect(!written.contains("profiles/\(name)"), "\(name) reached the file")
        }
        // Digits, a dash and an underscore are a fine id.
        try machine.profile("team-2_b")
        #expect(machine.discovery.seats().map(\.id) == ["team-2_b", "work"])
        #expect(try machine.decode(machine.loader.seed()).seats.map(\.label) == ["Team-2_b", "Work"])
    }

    @Test func aHomeWithQuotesInItsPathStillSeedsAFileThatParses() throws {
        let machine = try Machine()
        defer { machine.remove() }
        let home = machine.root.appendingPathComponent("a \"home\" \\ with \t marks\n", isDirectory: true)
        let work = home.appendingPathComponent(".seat-gauge/profiles/work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let written = ConfigLoader(file: machine.seats,
                                   machine: SeatDiscovery(home: home, codexLogin: machine.codexLogin)).seed()
        let config = try ConfigLoader.decode(Data(written.utf8), tokenDirectory: machine.tokens, home: home)
        #expect(config.seats.compactMap(Self.profile) == [Self.resolved(work)])
    }

    // MARK: - An existing seats.json is never rewritten

    @Test func anExistingSeatsFileIsNeverRewritten() throws {
        let machine = try Machine()
        defer { machine.remove() }
        try machine.profile("work")
        try machine.signInCodex()
        try FileManager.default.createDirectory(at: machine.seats.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        // The user's file, even an empty list, is theirs.
        let mine = Data(#"{ "seats": [] }"#.utf8)
        try mine.write(to: machine.seats)
        #expect(try machine.loader.loadOrCreate().seats.isEmpty)
        #expect(try Data(contentsOf: machine.seats) == mine)

        // A file that does not parse is said, and kept.
        let broken = Data("{ \"seats\": [ ,, ] }".utf8)
        try broken.write(to: machine.seats)
        #expect(throws: ConfigProblem.self) { try machine.loader.loadOrCreate() }
        #expect(try Data(contentsOf: machine.seats) == broken)

        // A link to a file not there yet is a name that is taken: it is
        // neither replaced nor followed.
        try FileManager.default.removeItem(at: machine.seats)
        let target = machine.root.appendingPathComponent("elsewhere.json")
        try FileManager.default.createSymbolicLink(at: machine.seats, withDestinationURL: target)
        #expect(throws: ConfigProblem.self) { try machine.loader.loadOrCreate() }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: machine.seats.path) == target.path)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        // And no draft is left beside it.
        let left = try FileManager.default.contentsOfDirectory(atPath: machine.seats.deletingLastPathComponent().path)
        #expect(left == ["seats.json"])
    }

    // MARK: - A file refused at launch: the machine's seats stand in

    @Test func aFileRefusedAtLaunchKeepsItAndTheMachinesSeatsStandIn() async throws {
        let machine = try Machine()
        defer { machine.remove() }
        try machine.profile("work")
        try machine.signInCodex()
        try FileManager.default.createDirectory(at: machine.seats.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let refused = Data(#"{ "seats": [ { "id": "Work", "label": "Work", "kind": "claude" } ] }"#.utf8)
        try refused.write(to: machine.seats)

        let watcher = try ConfigWatcher(loader: machine.loader)
        #expect(await watcher.config.seats.map(\.id.rawValue) == ["work", "codex"])
        #expect(await watcher.problem?.contains(#""Work""#) == true)
        #expect(try Data(contentsOf: machine.seats) == refused)
    }
}
