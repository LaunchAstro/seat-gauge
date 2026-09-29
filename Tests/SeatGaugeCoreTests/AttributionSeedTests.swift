import Foundation
import Testing

import SeatGaugeCore

/// `seatgauge-cli attribute --seed`, run as the built binary. Every seed and record is written by the case, with made-up seats and times.
@Suite struct AttributionSeedTests {

    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func folder() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-seed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    struct Ran { let status: Int32; let out: String }

    /// Every wait on the command is bounded: `waitUntilExit` can miss an
    /// exit when it is called from a task, so the cases poll `isRunning`
    /// against a deadline and end the command past it.
    static let limit: TimeInterval = 30

    static func seed(_ seed: URL, _ record: URL) throws -> (Process, Pipe) {
        let task = Process()
        task.executableURL = repository.appendingPathComponent(".build/debug/seatgauge-cli")
        task.arguments = ["attribute", "--seed", seed.path, "--record", record.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        return (task, pipe)
    }

    static func run(_ seed: URL, _ record: URL) throws -> Ran {
        let (task, pipe) = try Self.seed(seed, record)
        let deadline = Date(timeIntervalSinceNow: limit)
        while task.isRunning, Date() < deadline { usleep(20_000) }
        return finished(task, pipe)
    }

    /// The command's status and words, or -1 when it outlived its deadline.
    static func finished(_ task: Process, _ pipe: Pipe) -> Ran {
        guard !task.isRunning else {
            task.terminate()
            return Ran(status: -1, out: "the command was still running after \(Int(limit)) s")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return Ran(status: task.terminationStatus, out: String(decoding: data, as: UTF8.self))
    }

    static func write(_ text: String, to url: URL) throws { try Data(text.utf8).write(to: url) }

    static func oneSentence(_ out: String) -> Bool {
        let lines = out.split(separator: "\n")
        return lines.count == 1 && lines[0].hasSuffix(".")
    }

    static func spans(_ record: URL) throws -> [AttributionSpan] {
        try JSONDecoder.attribution.decode(AttributionRecord.self, from: Data(contentsOf: record))
            .directories["default"] ?? []
    }

    static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    static let timeline = """
        [
          { "from": "2026-01-01T00:00:00Z", "to": "2026-01-05T00:00:00Z", "account": "alpha" },
          { "directory": "default", "from": "2026-01-05T00:00:00Z", "to": "2026-01-06T00:00:00Z", "account": "unattributed" },
          { "from": "2026-01-06T00:00:00Z", "account": "beta" }
        ]
        """

    // MARK: - A seed writes its spans

    @Test func aSeedWritesItsSpans() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = root.appendingPathComponent("seed.json"), record = root.appendingPathComponent("attribution.json")
        try Self.write(Self.timeline, to: seed)
        let before = Date(timeIntervalSinceNow: -1)
        let ran = try Self.run(seed, record)
        let after = Date(timeIntervalSinceNow: 1)
        #expect(ran.status == 0, "\(ran.out)")
        #expect(Self.oneSentence(ran.out), "\(ran.out)")
        let spans = try Self.spans(record)
        #expect(spans.count == 3)
        #expect(spans[0] == AttributionSpan(from: Self.date("2026-01-01T00:00:00Z"), to: Self.date("2026-01-05T00:00:00Z"),
                                            lastSeen: Self.date("2026-01-01T00:00:00Z"), account: "alpha"))
        #expect(spans[1].account == "unattributed" && spans[1].lastSeen == spans[1].from)
        #expect(spans[2].from == Self.date("2026-01-06T00:00:00Z") && spans[2].to == nil && spans[2].account == "beta")
        #expect(spans[2].lastSeen >= before && spans[2].lastSeen <= after)
        let zone = try JSONDecoder.attribution.decode(AttributionRecord.self, from: Data(contentsOf: record)).timeZone
        #expect(zone == TimeZone.current.identifier)
    }

    // MARK: - An identical rerun changes nothing

    @Test func anIdenticalRerunChangesNothing() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = root.appendingPathComponent("seed.json"), record = root.appendingPathComponent("attribution.json")
        try Self.write(Self.timeline, to: seed)
        #expect(try Self.run(seed, record).status == 0)
        var before = try Data(contentsOf: record)
        var again = try Self.run(seed, record)
        #expect(again.status == 0, "\(again.out)")
        #expect(Self.oneSentence(again.out), "\(again.out)")
        #expect(try Data(contentsOf: record) == before)

        // An observation extends the open span; the seed is still all there.
        await AttributionWriter(file: record).observe(.match("beta"), now: Date(timeIntervalSinceNow: 60))
        before = try Data(contentsOf: record)
        again = try Self.run(seed, record)
        #expect(again.status == 0, "\(again.out)")
        #expect(try Data(contentsOf: record) == before)
    }

    // MARK: - A seed that disagrees with the record refuses

    @Test func aSeedThatDisagreesRefuses() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = root.appendingPathComponent("seed.json"), record = root.appendingPathComponent("attribution.json")
        try Self.write(Self.timeline, to: seed)
        #expect(try Self.run(seed, record).status == 0)
        let before = try Data(contentsOf: record)
        let disagreeing = [
            #"[{ "from": "2026-01-04T00:00:00Z", "to": "2026-01-05T12:00:00Z", "account": "alpha" }]"#,
            #"[{ "from": "2026-01-01T00:00:00Z", "to": "2026-01-05T00:00:00Z", "account": "gamma" }]"#,
            #"[{ "from": "2026-01-06T00:00:00Z", "account": "gamma" }]"#,
            #"[{ "from": "2025-12-01T00:00:00Z", "to": "2025-12-10T00:00:00Z", "account": "alpha" },"#
                + #" { "from": "2025-12-05T00:00:00Z", "to": "2025-12-20T00:00:00Z", "account": "beta" }]"#,
        ]
        for text in disagreeing {
            try Self.write(text, to: seed)
            let ran = try Self.run(seed, record)
            #expect(ran.status == 1, "\(text): \(ran.out)")
            #expect(Self.oneSentence(ran.out), "\(text): \(ran.out)")
            #expect(try Data(contentsOf: record) == before, "\(text)")
        }
    }

    // MARK: - The command refuses while the app is running

    @Test func refusesWhileTheAppIsRunning() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = root.appendingPathComponent("seed.json"), record = root.appendingPathComponent("attribution.json")
        try Self.write(Self.timeline, to: seed)
        var app: RunningLock? = RunningLock.claim(in: root)
        #expect(app != nil)
        let ran = try Self.run(seed, record)
        #expect(ran.status == 1, "\(ran.out)")
        #expect(Self.oneSentence(ran.out), "\(ran.out)")
        #expect(ran.out.contains("running"), "\(ran.out)")
        #expect(!FileManager.default.fileExists(atPath: record.path))
        app = nil
        #expect(try Self.run(seed, record).status == 0)
    }

    // MARK: - The seed waits for the lock every writer takes

    @Test func theSeedTakesTheWritersLock() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = root.appendingPathComponent("seed.json"), record = root.appendingPathComponent("attribution.json")
        try Self.write(Self.timeline, to: seed)
        let lock = open(root.appendingPathComponent("attribution.json.lock").path, O_CREAT | O_RDWR, 0o644)
        #expect(flock(lock, LOCK_EX | LOCK_NB) == 0)
        let (task, pipe) = try Self.seed(seed, record)
        try await Task.sleep(for: .seconds(1.5))
        #expect(task.isRunning)
        #expect(!FileManager.default.fileExists(atPath: record.path))
        flock(lock, LOCK_UN)
        close(lock)
        let deadline = Date(timeIntervalSinceNow: Self.limit)
        while task.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let ran = Self.finished(task, pipe)
        #expect(ran.status == 0, "\(ran.out)")
        #expect(try Self.spans(record).count == 3)
    }

    // MARK: - Fails closed

    @Test func failsClosedOnABadSeedOrRecord() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = root.appendingPathComponent("seed.json"), record = root.appendingPathComponent("attribution.json")
        var ran = try Self.run(seed, record)
        #expect(ran.status == 1 && Self.oneSentence(ran.out), "a missing seed: \(ran.out)")
        #expect(!FileManager.default.fileExists(atPath: record.path))

        let bad = [
            "{ not json",
            #"{ "from": "2026-01-01T00:00:00Z", "account": "alpha" }"#,
            #"[{ "from": "2026-01-05T00:00:00Z", "to": "2026-01-05T00:00:00Z", "account": "alpha" }]"#,
            #"[{ "from": "2026-01-05T00:00:00Z", "to": "2026-01-06T00:00:00Z", "account": "" }]"#,
            #"[{ "from": "2026-01-01T00:00:00Z", "account": "alpha" }, { "from": "2026-01-03T00:00:00Z", "account": "beta" }]"#,
        ]
        for text in bad {
            try Self.write(text, to: seed)
            ran = try Self.run(seed, record)
            #expect(ran.status == 1, "\(text): \(ran.out)")
            #expect(Self.oneSentence(ran.out), "\(text): \(ran.out)")
            #expect(!FileManager.default.fileExists(atPath: record.path), "\(text)")
        }

        let malformed = Data("{ not a record".utf8)
        try malformed.write(to: record)
        try Self.write(Self.timeline, to: seed)
        ran = try Self.run(seed, record)
        #expect(ran.status == 1, "\(ran.out)")
        #expect(Self.oneSentence(ran.out), "\(ran.out)")
        #expect(try Data(contentsOf: record) == malformed)
    }
}
