import Foundation
import Testing

import SeatGaugeCore

/// Which seat the main Claude login is, observed on every poll. The ids are made up and every `.claude.json` is written by the case.
@Suite struct IdentityObserverTests {

    /// A home with a main login and two seat profiles, each file written as given.
    struct Home {
        let root: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("seat-gauge-identity-\(UUID().uuidString)", isDirectory: true)
            for name in [".claude-seat-work", ".claude-seat-personal"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(name),
                                                        withIntermediateDirectories: true)
            }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        var main: URL { root.appendingPathComponent(".claude.json") }
        func profile(_ seat: String) -> URL { root.appendingPathComponent(".claude-seat-\(seat)/.claude.json") }
        func write(_ text: String?, to file: URL) throws {
            if let text { try Data(text.utf8).write(to: file) } else { try? FileManager.default.removeItem(at: file) }
        }
        var seats: [Seat] {
            [Seat(id: SeatID(rawValue: "work"), label: "Work",
                  kind: .claude(profileDir: root.appendingPathComponent(".claude-seat-work"))),
             Seat(id: SeatID(rawValue: "personal"), label: "Personal",
                  kind: .claude(profileDir: root.appendingPathComponent(".claude-seat-personal"))),
             Seat(id: SeatID(rawValue: "codex"), label: "Codex", kind: .codex)]
        }
        func observe() -> IdentityObservation { IdentityObserver.observe(seats: seats, home: root) }
    }

    static func login(_ id: String) -> String {
        #"{"oauthAccount": {"accountUuid": "\#(id)", "organizationRateLimitTier": "default_claude_max_5x"}, "numStartups": 3}"#
    }

    // MARK: - Match

    @Test func theMainLoginMatchesOneSeat() throws {
        let home = try Home()
        defer { home.remove() }
        try home.write(Self.login("id-alpha"), to: home.main)
        try home.write(Self.login("id-alpha"), to: home.profile("work"))
        try home.write(Self.login("id-beta"), to: home.profile("personal"))
        #expect(home.observe() == .match("work"))
        try home.write(Self.login("id-beta"), to: home.main)
        #expect(home.observe() == .match("personal"))
    }

    // MARK: - No match

    @Test func theMainLoginMatchesNoSeat() throws {
        let home = try Home()
        defer { home.remove() }
        try home.write(Self.login("id-gamma"), to: home.main)
        try home.write(Self.login("id-alpha"), to: home.profile("work"))
        try home.write(Self.login("id-beta"), to: home.profile("personal"))
        #expect(home.observe() == .noMatch)
    }

    // MARK: - Incomplete

    @Test func anythingMissingIsIncomplete() throws {
        let home = try Home()
        defer { home.remove() }
        let good = { () throws -> Void in
            try home.write(Self.login("id-alpha"), to: home.main)
            try home.write(Self.login("id-alpha"), to: home.profile("work"))
            try home.write(Self.login("id-beta"), to: home.profile("personal"))
        }
        let expired = #"{"numStartups": 3, "oauthAccount": null}"#
        let cases: [(String, URL, String?)] = [
            ("the main file missing", home.main, nil),
            ("the main file mid-write", home.main, #"{"oauthAccount": {"accountUu"#),
            ("the main file with no account", home.main, #"{"numStartups": 3}"#),
            ("a profile missing", home.profile("personal"), nil),
            ("a profile that does not parse", home.profile("personal"), "not json"),
            ("an expired profile", home.profile("personal"), expired),
            ("two seats with the main id", home.profile("personal"), Self.login("id-alpha")),
        ]
        for (name, file, text) in cases {
            try good()
            #expect(home.observe() == .match("work"), "the good home before \(name)")
            try home.write(text, to: file)
            #expect(home.observe() == .incomplete, "\(name)")
        }
    }

    // MARK: - The id stays in memory

    @Test func noIdIsKept() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write(Self.login("id-alpha"), to: home.main)
        try home.write(Self.login("id-alpha"), to: home.profile("work"))
        try home.write(Self.login("id-beta"), to: home.profile("personal"))
        let (poller, lines, record) = try Self.poller(home)
        await poller.poll()
        #expect(!lines.all.isEmpty)
        #expect(!lines.all.contains { $0.contains("id-alpha") || $0.contains("id-beta") })
        let written = try String(contentsOf: record, encoding: .utf8)
        #expect(written.contains("work"))
        #expect(!written.contains("id-alpha") && !written.contains("id-beta"))
    }

    // MARK: - Every poll observes once, through the app's hook

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [String] = []
        func add(_ line: String) { lock.withLock { kept.append(line) } }
        var all: [String] { lock.withLock { kept } }
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: TimeInterval = 1_790_000_000
        func next() -> Date { lock.withLock { seconds += 300; return Date(timeIntervalSince1970: seconds) } }
    }

    struct Dormant: SeatFetching {
        func fetch(_ seat: Seat, now: Date, last: Reading?) async -> Fetched {
            Fetched(state: .dormant(reason: "not read here"), lines: [])
        }
    }

    static func poller(_ home: Home) throws -> (Poller<ContinuousClock, ContinuousClock>, Lines, URL) {
        let config = home.root.appendingPathComponent("seats.json")
        let seats = [#"{ "id": "work", "label": "Work", "kind": "claude", "profile": "\#(home.root.path)/.claude-seat-work", "login": "own" }"#,
                     #"{ "id": "personal", "label": "Personal", "kind": "claude", "profile": "\#(home.root.path)/.claude-seat-personal", "login": "own" }"#,
                     #"{ "id": "codex", "label": "Codex", "kind": "codex" }"#]
        try Data("{ \"seats\": [ \(seats.joined(separator: ", ")) ] }".utf8).write(to: config)
        let record = home.root.appendingPathComponent("attribution.json")
        let lines = Lines()
        let clock = Clock()
        let poller = Poller(watcher: try ConfigWatcher(loader: ConfigLoader(file: config)),
                            service: RefreshService(gap: .zero) { _ in Dormant() },
                            store: GaugeStore(file: home.root.appendingPathComponent("readings.json")),
                            clock: ContinuousClock(),
                            identity: IdentityObserver.hook(writer: AttributionWriter(file: record), home: home.root,
                                                            now: { clock.next() }),
                            log: { lines.add($0) })
        return (poller, lines, record)
    }

    static func spans(_ record: URL) throws -> [AttributionSpan] {
        try JSONDecoder.attribution.decode(AttributionRecord.self, from: Data(contentsOf: record))
            .directories["default"] ?? []
    }

    @Test func everyPollObservesOnceThroughTheAppsHook() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write(Self.login("id-alpha"), to: home.main)
        try home.write(Self.login("id-alpha"), to: home.profile("work"))
        try home.write(Self.login("id-beta"), to: home.profile("personal"))
        let (poller, _, record) = try Self.poller(home)
        await poller.poll()
        await poller.poll()
        var spans = try Self.spans(record)
        #expect(spans.count == 1)
        #expect(spans.first?.account == "work")
        #expect(spans.first.map { $0.lastSeen.timeIntervalSince($0.from) } == 300)

        try home.write(Self.login("id-beta"), to: home.main)
        await poller.poll()
        spans = try Self.spans(record)
        #expect(spans.map(\.account) == ["work", "unattributed", "personal"])
        #expect(spans.last?.to == nil)
    }

    // MARK: - Fails closed

    @Test func failsClosedOnAnIncompleteObservation() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write(Self.login("id-alpha"), to: home.main)
        try home.write(Self.login("id-alpha"), to: home.profile("work"))
        try home.write(Self.login("id-beta"), to: home.profile("personal"))
        let (poller, _, record) = try Self.poller(home)
        await poller.poll()
        let before = try Data(contentsOf: record)
        for text in [nil, "", "{", #"{"oauthAccount": 7}"#, #"{"oauthAccount": {"accountUuid": 7}}"#] {
            try home.write(text, to: home.main)
            #expect(home.observe() == .incomplete, "\(String(describing: text))")
            await poller.poll()
            #expect(try Data(contentsOf: record) == before, "\(String(describing: text))")
        }
    }
}
