import Foundation
import Testing

import SeatGaugeCore

/// Claude seats that own their login: the config rules, the template and
/// removal.
@Suite struct OwnLoginSeatTests {

    static func folder() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-login-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func seats(_ lines: String...) -> Data {
        Data("{ \"seats\": [ \(lines.joined(separator: ", ")) ] }".utf8)
    }

    static let bare = #"{ "id": "work", "label": "Work", "kind": "claude" }"#
    static let work = #"{ "id": "work", "label": "Work", "kind": "claude", "profile": "~/.claude-seat-work", "login": "own" }"#
    static let personal = #"{ "id": "personal", "label": "Personal", "kind": "claude", "profile": "~/.claude-seat-personal", "login": "own" }"#
    static let team = #"{ "id": "team", "label": "Team", "kind": "claude", "profile": "~/.claude-seat-team" }"#
    static let codex = #"{ "id": "codex", "label": "Codex", "kind": "codex" }"#

    static func profile(_ seat: Seat) -> URL? {
        guard case let .claude(directory) = seat.kind else { return nil }
        return directory
    }

    /// Records the seats a round asks for, and reads each as dormant.
    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func add(_ id: String) { lock.withLock { ids.append(id) } }
        var all: [String] { lock.withLock { ids } }
    }
    struct Recording: SeatFetching {
        let asked: Asked
        func fetch(_ seat: Seat, now: Date, last: Reading?) async -> Fetched {
            asked.add(seat.id.rawValue)
            return Fetched(state: .dormant(reason: "not read here"), lines: [])
        }
    }

    // MARK: - A claude seat with no profile is refused

    @Test func aClaudeSeatWithNoProfileIsRefused() throws {
        let tokens = try Self.folder()
        defer { try? FileManager.default.removeItem(at: tokens) }
        let withToken = #"{ "id": "work", "label": "Work", "kind": "claude", "token": "~/work.token" }"#
        let withLogin = #"{ "id": "work", "label": "Work", "kind": "claude", "login": "own" }"#
        let lists: [(String, Data)] = [
            ("alone", Self.seats(Self.bare)),
            ("first", Self.seats(Self.bare, Self.personal)),
            ("last", Self.seats(Self.personal, Self.codex, Self.bare)),
            ("with a token", Self.seats(Self.personal, withToken)),
            ("saying it owns a login", Self.seats(withLogin, Self.codex)),
        ]
        for (name, data) in lists {
            do {
                _ = try ConfigLoader.decode(data, tokenDirectory: tokens)
                Issue.record("a profile-less claude seat \(name) was read")
            } catch let problem as ConfigProblem {
                #expect(problem.reason.contains(#""work""#), "\(name): \(problem.reason)")
                #expect(problem.reason.contains(#"give it a profile and "login": "own""#), "\(name): \(problem.reason)")
                #expect(!problem.reason.contains("\n"), "\(name): one sentence")
            }
        }
        let token = #"{ "id": "personal", "label": "Personal", "kind": "claude", "profile": "~/.claude-seat-personal", "token": "~/personal.token" }"#
        let config = try ConfigLoader.decode(Self.seats(Self.work, token, Self.codex), tokenDirectory: tokens)
        #expect(config.seats.map(\.id.rawValue) == ["work", "personal", "codex"])
        #expect(config.seats[1].tokenFile?.lastPathComponent == "personal.token")
    }

    // MARK: - The seeded file names only profile seats that own their login

    @Test func theSeededFileNamesOnlyProfileSeatsThatOwnTheirLogin() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let tokens = root.appendingPathComponent("tokens", isDirectory: true)
        let codex = root.appendingPathComponent("auth.json")
        for id in ["personal", "work"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".seat-gauge/profiles/\(id)"),
                                                    withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: tokens, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: codex)
        let file = root.appendingPathComponent("seats.json")
        let loader = ConfigLoader(file: file, machine: SeatDiscovery(home: home, codexLogin: codex))
        let declared = try ConfigLoader.decode(Data(loader.seed().utf8)).seats
        for seat in declared {
            try Data("not a real token".utf8).write(to: tokens.appendingPathComponent("\(seat.id.rawValue).token"))
        }
        _ = try loader.loadOrCreate()
        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(written == loader.seed())
        #expect(written.contains("//"))
        #expect(written.contains("},\n") || written.contains(",\n  ]") || written.contains(",\n}"))

        let config = try ConfigLoader.decode(Data(written.utf8), tokenDirectory: tokens, home: home)
        #expect(config.pollMinutes == 5)
        #expect(config.seats.map(\.id) == declared.map(\.id))
        #expect(config.seats.map(\.id.rawValue) == ["personal", "work", "codex"])
        let claude = config.seats.filter { $0.kind != .codex }
        #expect(!claude.isEmpty)
        for seat in claude {
            #expect(Self.profile(seat)?.lastPathComponent == seat.id.rawValue)
            #expect(seat.tokenFile == nil, "\(seat.id.rawValue) pins a token")
        }
        #expect(config.seats.last?.kind == .codex)

        // The file is the user's once it exists, so a second load leaves it be.
        try Data("{ \"seats\": [ \(Self.personal) ] }".utf8).write(to: file)
        #expect(try loader.loadOrCreate().seats.map(\.id.rawValue) == ["personal"])
    }

    // MARK: - A seat removed from the config is gone, and nothing polls it

    @Test func aRemovedSeatIsGoneAndNothingPollsIt() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("seats.json")
        try Self.seats(Self.work, Self.team, Self.personal, Self.codex).write(to: file)
        let watcher = try ConfigWatcher(loader: ConfigLoader(file: file))
        #expect(await watcher.config.seats.map(\.id.rawValue) == ["work", "team", "personal", "codex"])

        try Self.seats(Self.work, Self.personal, Self.codex).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        #expect(await watcher.refresh())
        let config = await watcher.config
        #expect(config.seats.map(\.id.rawValue) == ["work", "personal", "codex"])

        let asked = Asked()
        let service = RefreshService(gap: .zero) { _ in Recording(asked: asked) }
        let states = await service.refresh(config.seats, states: [:], now: Date())
        #expect(asked.all.sorted() == ["codex", "personal", "work"])
        #expect(states[SeatID(rawValue: "team")] == nil)
    }

    // MARK: - The panel's problems are ranked for the title bar's one slot

    @Test func problemsAreRankedForTheTitleBarSlot() {
        let config = "seats.json: the id \"Work\" is not lowercase."
        let all: [PanelProblem] = [.timeZone, .attributionRecord, .config(config), .spendRecord]
        let slot = ProblemSlot(all)
        #expect(slot.title == config)
        #expect(slot.menu.count == 4)
        #expect(slot.menu.first == config)
        #expect(slot.menu[1] == "spend record unreadable")
        #expect(slot.menu[2] == "attribution record unreadable")
        #expect(slot.menu[3] == PanelProblem.timeZone.sentence)

        #expect(ProblemSlot([.attributionRecord, .spendRecord]).title == "spend record unreadable")
        #expect(ProblemSlot([.timeZone]).menu == [PanelProblem.timeZone.sentence])
        #expect(!PanelProblem.timeZone.sentence.isEmpty)
        let none = ProblemSlot([])
        #expect(none.title == nil)
        #expect(none.menu.isEmpty)
    }

    // MARK: - Fails closed: a refused file is kept, and the right seats stand in

    @Test func failsClosedWithTheFileKeptAndTheRightSeatsInUse() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("seats.json")
        let refused = Self.seats(Self.bare, Self.team, Self.codex)
        try refused.write(to: file)
        let loader = ConfigLoader(file: file)
        #expect(throws: ConfigProblem.self) { try loader.load() }
        #expect(throws: ConfigProblem.self) { try loader.loadOrCreate() }
        #expect(try Data(contentsOf: file) == refused)

        // At launch the seats first launch would seed stand in, under their
        // own names.
        let watcher = try ConfigWatcher(loader: loader)
        let launch = await watcher.config
        let seeded = try ConfigLoader.decode(Data(loader.seed().utf8)).seats
        #expect(!seeded.isEmpty)
        #expect(launch.seats.map(\.id) == seeded.map(\.id))
        #expect(await watcher.problem?.contains(#"give it a profile and "login": "own""#) == true)
        #expect(try Data(contentsOf: file) == refused)

        // A good read clears the problem, and a refused edit keeps it in use.
        try Self.seats(Self.personal, Self.codex).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        #expect(await watcher.refresh())
        #expect(await watcher.problem == nil)
        try refused.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: file.path)
        #expect(await watcher.refresh() == false)
        #expect(await watcher.config.seats.map(\.id.rawValue) == ["personal", "codex"])
        #expect(await watcher.problem?.contains(#""work""#) == true)
        #expect(try Data(contentsOf: file) == refused)
    }
}
