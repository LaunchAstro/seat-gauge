import Foundation
import Testing

@testable import SeatGaugeCore

/// The daily copy of `spend.csv` and `attribution.json`: one dated folder a
/// day, none on a day with no change, the last 30 kept, and the live files
/// left alone when a copy fails.
@Suite struct HistoryBackupTests {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("seat-gauge-backup-\(UUID().uuidString)", isDirectory: true)
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    var backup: HistoryBackup { HistoryBackup(support: folder, calendar: calendar) }
    let day = ISO8601DateFormatter().date(from: "2026-09-25T09:00:00Z")!

    func live(_ csv: String, _ attribution: String = "{}") throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(csv.utf8).write(to: folder.appendingPathComponent("spend.csv"))
        try Data(attribution.utf8).write(to: folder.appendingPathComponent("attribution.json"))
    }

    func text(_ file: URL) -> String? {
        FileManager.default.contents(atPath: file.path).map { String(decoding: $0, as: UTF8.self) }
    }

    var dated: [String] { backup.days() }

    @Test func aDayGetsOneDatedCopyOfBothFiles() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try live("one", #"{"a":1}"#)

        let written = try #require(try backup.run(now: day))
        #expect(written.lastPathComponent == "2026-09-25")
        #expect(text(written.appendingPathComponent("spend.csv")) == "one")
        #expect(text(written.appendingPathComponent("attribution.json")) == #"{"a":1}"#)

        // Later the same day, with a change, still one copy for the day.
        try live("two")
        #expect(try backup.run(now: day.addingTimeInterval(3600)) == nil)
        #expect(dated == ["2026-09-25"])
    }

    @Test func aDayWithNoChangeWritesNoCopy() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try live("one")
        try backup.run(now: day)

        #expect(try backup.run(now: day.addingTimeInterval(86_400)) == nil)
        try live("two")
        #expect(try backup.run(now: day.addingTimeInterval(2 * 86_400)) != nil)
        #expect(dated == ["2026-09-25", "2026-09-27"])
    }

    @Test func onlyTheLastThirtyDaysAreKept() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        for n in 0..<32 {
            try live("day \(n)")
            try backup.run(now: day.addingTimeInterval(Double(n) * 86_400))
        }
        #expect(dated.count == HistoryBackup.kept)
        #expect(dated.first == "2026-09-27")
        #expect(dated.last == "2026-10-26")
    }

    @Test func theRollUpTakesTheDaysCopyBesideTheRecord() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("attribution.json"))
        let coordinator = SpendCoordinator(csv: folder.appendingPathComponent("spend.csv"),
                                           state: folder.appendingPathComponent("state.json"),
                                           primer: folder, codex: nil, calendar: calendar, log: { _ in })
        _ = try await coordinator.run(profiles: [], rates: .bundled, now: day)
        #expect(dated == ["2026-09-25"])
    }

    @Test func missingAttributionDoesNotClaimTheDaysBackup() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: folder.appendingPathComponent("spend.csv"))

        #expect(try backup.run(now: day) == nil)

        try Data(#"{"a":1}"#.utf8).write(
            to: folder.appendingPathComponent("attribution.json"))
        let written = try #require(try backup.run(now: day.addingTimeInterval(60)))
        #expect(text(written.appendingPathComponent("spend.csv")) == "one")
        #expect(text(written.appendingPathComponent("attribution.json")) == #"{"a":1}"#)
    }

    @Test func aFailedCopyLeavesTheLiveFilesAlone() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try live("one", #"{"a":1}"#)
        // A file where the backups folder should be, so no copy can be made.
        try Data("in the way".utf8).write(to: backup.folder)

        #expect(throws: (any Error).self) { try backup.run(now: day) }
        #expect(text(folder.appendingPathComponent("spend.csv")) == "one")
        #expect(text(folder.appendingPathComponent("attribution.json")) == #"{"a":1}"#)
    }
}
