import Foundation
import Testing

import SeatGaugeCore

/// The attribution record: its invariants, spans from observations, and one
/// locked writer. Seat names and instants are made up; no case reads a real login.
@Suite struct AttributionRecordTests {

    static func folder() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Whole seconds from a fixed origin, so a record reads back equal.
    static func at(_ seconds: Int) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + TimeInterval(seconds)) }

    static func span(_ from: Int, _ to: Int?, _ seen: Int, _ account: String) -> AttributionSpan {
        AttributionSpan(from: at(from), to: to.map(at), lastSeen: at(seen), account: account)
    }

    static func spans(_ file: URL, _ directory: String = "default") throws -> [AttributionSpan] {
        let data = try Data(contentsOf: file)
        return try JSONDecoder.attribution.decode(AttributionRecord.self, from: data).directories[directory] ?? []
    }

    static let guam = TimeZone(identifier: "Pacific/Guam")!

    // MARK: - The record's shape and its invariants

    @Test func theRecordKeepsItsInvariants() throws {
        let good = AttributionRecord(timeZone: "Pacific/Guam", directories: [
            "default": [Self.span(0, 100, 0, "work"), Self.span(100, 160, 150, "unattributed"),
                        Self.span(160, nil, 400, "personal")],
            "personal": [Self.span(0, 50, 50, "personal")],
        ])
        try good.validate()
        let data = try JSONEncoder.attribution.encode(good)
        #expect(try JSONDecoder.attribution.decode(AttributionRecord.self, from: data) == good)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"lastSeen\"") && text.contains("\"timeZone\""))

        let bad: [(String, [AttributionSpan])] = [
            ("overlapping", [Self.span(0, 100, 0, "work"), Self.span(90, 200, 90, "personal")]),
            ("unordered", [Self.span(100, 200, 100, "personal"), Self.span(0, 50, 0, "work")]),
            ("two open", [Self.span(0, nil, 10, "work"), Self.span(20, nil, 30, "personal")]),
            ("open before closed", [Self.span(0, nil, 10, "work"), Self.span(20, 30, 20, "personal")]),
            ("empty", [Self.span(10, 10, 10, "work")]),
            ("seen before from", [Self.span(10, 20, 5, "work")]),
            ("seen after to", [Self.span(10, 20, 25, "work")]),
            ("no account", [Self.span(0, 10, 0, "")]),
        ]
        for (name, spans) in bad {
            #expect(throws: AttributionProblem.self, "\(name) spans were accepted") {
                try AttributionRecord(timeZone: "UTC", directories: ["default": spans]).validate()
            }
        }
    }

    // MARK: - Observations become spans

    @Test func observationsBecomeSpans() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("attribution.json")
        let writer = AttributionWriter(file: file, timeZone: Self.guam)

        await writer.observe(.match("work"), now: Self.at(0))
        #expect(try Self.spans(file) == [Self.span(0, nil, 0, "work")])
        await writer.observe(.match("work"), now: Self.at(300))
        #expect(try Self.spans(file) == [Self.span(0, nil, 300, "work")])
        await writer.observe(.match("personal"), now: Self.at(600))
        #expect(try Self.spans(file) == [Self.span(0, 300, 300, "work"), Self.span(300, 600, 300, "unattributed"),
                                         Self.span(600, nil, 600, "personal")])
        // Personal was never extended, so it closes empty and is dropped.
        await writer.observe(.noMatch, now: Self.at(900))
        #expect(try Self.spans(file) == [Self.span(0, 300, 300, "work"), Self.span(300, 600, 300, "unattributed"),
                                         Self.span(600, 900, 600, "unattributed"),
                                         Self.span(900, nil, 900, "unattributed")])
        await writer.observe(.noMatch, now: Self.at(1200))
        let last = try #require(try Self.spans(file).last)
        #expect(last == Self.span(900, nil, 1200, "unattributed"))
        #expect(last.end == Self.at(1200))
        #expect(await writer.problem == nil)
    }

    // MARK: - An incomplete observation records nothing and breaks continuity

    @Test func anIncompleteObservationBreaksContinuity() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("attribution.json")
        let writer = AttributionWriter(file: file, timeZone: Self.guam)
        await writer.observe(.match("work"), now: Self.at(0))
        await writer.observe(.match("work"), now: Self.at(300))
        let before = try Data(contentsOf: file)
        await writer.observe(.incomplete, now: Self.at(600))
        #expect(try Data(contentsOf: file) == before)
        await writer.observe(.match("work"), now: Self.at(900))
        #expect(try Self.spans(file) == [Self.span(0, 300, 300, "work"), Self.span(300, 900, 300, "unattributed"),
                                         Self.span(900, nil, 900, "work")])
    }

    // MARK: - One serial writer, atomic, under the lock, with the zone kept

    @Test func oneLockedWriterKeepsTheFirstZone() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("attribution.json")
        #expect(AttributionFile.record(at: file).directories.isEmpty)

        let first = AttributionWriter(file: file, timeZone: Self.guam, lockTimeout: .milliseconds(300))
        await first.observe(.match("work"), now: Self.at(0))
        await first.observe(.match("work"), now: Self.at(60))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("attribution.json.lock").path))
        let later = AttributionWriter(file: file, timeZone: TimeZone(identifier: "Europe/London")!)
        await later.observe(.match("work"), now: Self.at(120))
        #expect(AttributionFile.record(at: file).timeZone == "Pacific/Guam")
        #expect(try Self.spans(file) == [Self.span(0, nil, 120, "work")])

        // A held lock: the observation writes nothing, and counts as incomplete.
        let before = try Data(contentsOf: file)
        let lock = open(root.appendingPathComponent("attribution.json.lock").path, O_CREAT | O_RDWR, 0o644)
        #expect(flock(lock, LOCK_EX | LOCK_NB) == 0)
        await first.observe(.match("work"), now: Self.at(180))
        #expect(try Data(contentsOf: file) == before)
        flock(lock, LOCK_UN)
        close(lock)
        await first.observe(.match("work"), now: Self.at(240))
        #expect(try Self.spans(file) == [Self.span(0, 120, 120, "work"), Self.span(120, 240, 120, "unattributed"),
                                         Self.span(240, nil, 240, "work")])
        // Nothing but the record and its lock is left behind: the write renamed its temp file.
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(names == ["attribution.json", "attribution.json.lock"])
    }

    // MARK: - Fails closed: a malformed record is never overwritten

    @Test func failsClosedOnAMalformedRecord() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("attribution.json")
        func encoded(_ spans: [AttributionSpan]) throws -> Data {
            try JSONEncoder.attribution.encode(AttributionRecord(timeZone: "UTC", directories: ["default": spans]))
        }
        let malformed: [Data] = [
            Data("{ not json".utf8),
            Data(#"{"spans": []}"#.utf8),
            try encoded([Self.span(0, 100, 0, "work"), Self.span(50, 200, 50, "personal")]),
            try encoded([Self.span(100, 200, 100, "personal"), Self.span(0, 50, 0, "work")]),
            try encoded([Self.span(0, nil, 10, "work"), Self.span(20, nil, 30, "personal")]),
        ]
        for bytes in malformed {
            try bytes.write(to: file)
            let writer = AttributionWriter(file: file, timeZone: Self.guam)
            await writer.observe(.match("work"), now: Self.at(1000))
            await writer.observe(.match("personal"), now: Self.at(2000))
            #expect(try Data(contentsOf: file) == bytes)
            #expect(await writer.problem == .attributionRecord)
            #expect(await writer.problem?.sentence == "attribution record unreadable")
            #expect(AttributionFile.record(at: file).directories.isEmpty)

            try FileManager.default.removeItem(at: file)
            await writer.observe(.match("personal"), now: Self.at(3000))
            #expect(await writer.problem == nil)
            #expect(try Self.spans(file) == [Self.span(3000, nil, 3000, "personal")])
        }
    }
}
