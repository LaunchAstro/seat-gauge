import Foundation
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// Spend read through the attribution record: how whole the record is, which
/// account an hour belongs to, and what the Spend tab and title bar say. Every
/// case writes its own records in a folder of its own, with seat names
/// and made-up instants only.
@Suite struct SpendAttributionTests {

    // MARK: - Fixtures

    struct Scratch {
        let folder: URL
        var csv: URL { folder.appendingPathComponent("spend.csv") }
        var state: URL { folder.appendingPathComponent("state.json") }
        var attribution: URL { folder.appendingPathComponent("attribution.json") }

        init() throws {
            folder = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("seat-gauge-attribution-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        func write(_ text: String, to file: URL) throws { try Data(text.utf8).write(to: file) }
        func bytes(_ file: URL) -> Data? { FileManager.default.contents(atPath: file.path) }
        func remove() { try? FileManager.default.removeItem(at: folder) }
    }

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func date(_ text: String) -> Date {
        let reader = ISO8601DateFormatter()
        reader.formatOptions = [.withInternetDateTime]
        return reader.date(from: text)!
    }

    static func row(_ seat: String, _ day: String, _ hour: String, input: Int = 1_000,
                    model: String = "claude-opus-5", sealed: Bool = true) -> SpendRow {
        let counts = TokenCounts(responses: 1, input: input, output: 100)
        return SpendRow(seat: seat, day: day, hour: hour, model: model, counts: counts,
                        usd: RateCard.bundled.usd(model: model, counts: counts), sealed: sealed)
    }

    static func span(_ from: String, _ to: String?, _ account: String, seen: String? = nil) -> AttributionSpan {
        AttributionSpan(from: date(from), to: to.map(date), lastSeen: date(seen ?? from), account: account)
    }

    static func writeRecord(_ record: AttributionRecord, to file: URL) throws {
        try JSONEncoder.attribution.encode(record).write(to: file)
    }

    // MARK: - Cases

    @Test func aWholeRecordIsAvailableAndAHeaderAloneIsEmpty() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let rows = [Self.row("personal", "2026-09-10", "09"), Self.row("codex", "2026-09-10", "10")]
        try scratch.write(SpendCSV.text(rows), to: scratch.csv)
        #expect(SpendCSV.read(scratch.csv, state: scratch.state) == .available(rows))

        try scratch.write(SpendCSV.header + "\n", to: scratch.csv)
        #expect(SpendCSV.read(scratch.csv, state: scratch.state) == .empty)
    }

    @Test func aMissingRecordIsEmptyOnlyBeforeTheFirstRollUp() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        #expect(SpendCSV.read(scratch.csv, state: scratch.state) == .empty)

        try scratch.write(#"{"timeZone":"UTC"}"#, to: scratch.state)
        #expect(SpendCSV.read(scratch.csv, state: scratch.state) == .empty)

        try StateStore(file: scratch.state).update { $0.rolledUpAt = Self.date("2026-09-10T00:00:00Z") }
        guard case .unavailable = SpendCSV.read(scratch.csv, state: scratch.state) else {
            Issue.record("a missing record after a roll-up must be unavailable"); return
        }

        try scratch.write("{ not json", to: scratch.state)
        guard case .unavailable = SpendCSV.read(scratch.csv, state: scratch.state) else {
            Issue.record("an unreadable state must not prove a first run"); return
        }
    }

    @Test func aRecordThatDoesNotReadWholeIsPartialOrUnavailable() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let good = [Self.row("personal", "2026-09-10", "09"), Self.row("personal", "2026-09-10", "10")]

        try Data([0xFF, 0xFE, 0x00, 0x2C]).write(to: scratch.csv)
        guard case .unavailable = SpendCSV.read(scratch.csv, state: scratch.state) else {
            Issue.record("a record that is not UTF-8 must be unavailable"); return
        }

        try scratch.write("seat,day,hour\n" + SpendCSV.text(good).split(separator: "\n").dropFirst()
            .joined(separator: "\n"), to: scratch.csv)
        guard case .unavailable = SpendCSV.read(scratch.csv, state: scratch.state) else {
            Issue.record("a record with the wrong header must be unavailable"); return
        }

        try scratch.write(SpendCSV.header + "\nnot,a,row\nnor,this\n", to: scratch.csv)
        guard case .unavailable = SpendCSV.read(scratch.csv, state: scratch.state) else {
            Issue.record("a record none of whose rows parse must be unavailable"); return
        }

        try scratch.write(SpendCSV.text(good) + "not,a,row\npersonal,2026-09-10,11,m,x,1,1,1,1,1,1,,true\n"
                          + "personal,2026-09-10,12,m,1,1,1,1,1,1,1,1.5x,true\n"
                          + "personal,2026-09-10,13,m,1,1,1,1,1,1,1,0.25,yes\n", to: scratch.csv)
        guard case let .partial(rows, reason) = SpendCSV.read(scratch.csv, state: scratch.state) else {
            Issue.record("a record with some bad lines must be partial"); return
        }
        #expect(rows == good)
        #expect(reason.contains("4"))

        // A `usd` that is not a decimal, or a `sealed` that is neither `true`
        // nor `false`, is a malformed row, so the coordinator refuses the record.
        try scratch.write(#"{"timeZone":"UTC"}"#, to: scratch.state)
        let coordinator = SpendCoordinator(csv: scratch.csv, state: scratch.state, primer: scratch.folder,
                                           codex: nil, calendar: Self.utc, log: { _ in })
        for bad in ["personal,2026-09-10,12,m,1,1,1,1,1,1,1,abc,true\n", "personal,2026-09-10,13,m,1,1,1,1,1,1,1,,TRUE\n"] {
            try scratch.write(SpendCSV.text(good) + bad, to: scratch.csv)
            #expect(SpendCSV.read(scratch.csv, state: scratch.state).isWhole == false)
            let before = scratch.bytes(scratch.csv)
            await #expect(throws: SpendRecordUnreadable.self) {
                _ = try await coordinator.run(profiles: [], rates: .bundled, now: Self.date("2026-09-10T12:00:00Z"))
            }
            #expect(scratch.bytes(scratch.csv) == before)
        }
    }

    @Test @MainActor func theCoordinatorNeverWritesOverARecordItCouldNotReadWhole() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let now = Self.date("2026-09-10T12:00:00Z")
        let coordinator = SpendCoordinator(csv: scratch.csv, state: scratch.state, primer: scratch.folder,
                                           codex: nil, calendar: Self.utc, log: { _ in })
        let good = SpendCSV.text([Self.row("personal", "2026-09-01", "09")])
        try scratch.write(#"{"timeZone":"UTC"}"#, to: scratch.state)

        for damaged in [good + "not,a,row\n", "seat,day\n" + good, SpendCSV.header + "\nnot,a,row\n"] {
            try scratch.write(damaged, to: scratch.csv)
            let csvBefore = scratch.bytes(scratch.csv)
            let stateBefore = scratch.bytes(scratch.state)
            await #expect(throws: SpendRecordUnreadable.self) {
                _ = try await coordinator.run(profiles: [], rates: .bundled, now: now)
            }
            #expect(scratch.bytes(scratch.csv) == csvBefore)
            #expect(scratch.bytes(scratch.state) == stateBefore)
        }

        try scratch.write(good, to: scratch.csv)
        let run = try await coordinator.run(profiles: [], rates: .bundled, now: now)
        #expect(run != nil)
        #expect(StateStore(file: scratch.state).load().rolledUpAt == now)

        // A record missing after a roll-up is rebuilt from a reset watermark:
        // the transcripts and rollouts the old watermark would pass by as read
        // are collected again, and the title bar says so until a clean run.
        typealias Logs = CodexSpendCoordinatorTests
        let logs = try Logs.Scratch()
        try Logs.oneSession(logs)
        // The Claude fixtures, copied so they can be dated before the roll-up.
        let fixtures = Logs.root.appendingPathComponent("Tests/Fixtures/spend", isDirectory: true)
        let profiles = try Logs.claudeProfiles.map { profile in
            let copy = logs.directory.appendingPathComponent(profile.seat, isDirectory: true)
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent(profile.seat), to: copy)
            return SpendProfile(seat: profile.seat, projects: copy.appendingPathComponent("projects"))
        }
        let walk = FileManager.default.enumerator(at: logs.directory, includingPropertiesForKeys: nil)
        while let url = walk?.nextObject() as? URL {
            if url.pathExtension == "jsonl" { try logs.touch(url, "2026-09-20T11:00:00Z") }
        }
        let rebuilder = logs.coordinator(codex: logs.collector)
        let first = Self.date("2026-09-25T00:00:00Z"), rebuilt = Self.date("2026-09-25T01:00:00Z")
        _ = try await rebuilder.run(profiles: profiles, rates: .bundled, now: first)
        let whole = try #require(scratchBytes(logs.csv))
        #expect(Set(SpendCSV.rows(String(decoding: whole, as: UTF8.self)).map(\.seat)) == ["default", "team", "codex"])

        try FileManager.default.removeItem(at: logs.csv)
        guard case .unavailable = SpendCSV.read(logs.csv, state: logs.state) else {
            Issue.record("a record missing after a roll-up reads as unavailable"); return
        }
        _ = try await rebuilder.run(profiles: profiles, rates: .bundled, now: rebuilt)
        #expect(scratchBytes(logs.csv) == whole)
        #expect(StateStore(file: logs.state).load().spendRebuiltAt == rebuilt)
        let mirror = GaugeMirror()
        let attribution = logs.directory.appendingPathComponent("attribution.json")
        mirror.readSpend(csv: logs.csv, state: logs.state, attribution: attribution)
        #expect(mirror.problems == ["spend record was missing, rebuilt from logs"])

        _ = try await rebuilder.run(profiles: profiles, rates: .bundled, now: Self.date("2026-09-25T02:00:00Z"))
        #expect(StateStore(file: logs.state).load().spendRebuiltAt == nil)
        mirror.readSpend(csv: logs.csv, state: logs.state, attribution: attribution)
        #expect(mirror.problems.isEmpty)
    }

    func scratchBytes(_ file: URL) -> Data? { FileManager.default.contents(atPath: file.path) }

    @Test func aMainLoginCellGoesToTheOneSpanItLiesWhollyInside() {
        // Tokyo is nine hours ahead of UTC with no daylight saving, so a local
        // hour lands inside these spans only when it is read in the stored zone.
        let record = AttributionRecord(timeZone: "Asia/Tokyo", directories: ["default": [
            Self.span("2026-09-10T01:00:00Z", "2026-09-10T02:00:00Z", "personal"),
            Self.span("2026-09-10T02:00:00Z", "2026-09-10T02:30:00Z", "work"),
            Self.span("2026-09-10T02:30:00Z", "2026-09-10T05:00:00Z", "work"),
            Self.span("2026-09-10T05:00:00Z", "2026-09-10T06:00:00Z", AttributionRecord.unattributed),
            Self.span("2026-09-10T07:00:00Z", nil, "personal", seen: "2026-09-10T08:30:00Z"),
        ]])
        let attribution = SpendAttribution(record: record)
        func account(_ hour: String) -> String {
            attribution.account(directory: "default", day: "2026-09-10", hour: hour)
        }
        #expect(account("10") == "personal")
        #expect(account("11") == AttributionRecord.unattributed)
        #expect(account("12") == "work")
        #expect(account("13") == "work")
        #expect(account("14") == AttributionRecord.unattributed)
        #expect(account("15") == AttributionRecord.unattributed)
        #expect(account("16") == "personal")
        #expect(account("17") == AttributionRecord.unattributed)
        #expect(account("01") == AttributionRecord.unattributed)
    }

    @Test func anHourThatDoesNotExistOrRepeatsIsUnattributed() {
        let record = AttributionRecord(timeZone: "Australia/Sydney", directories: ["default": [
            Self.span("2026-03-01T00:00:00Z", "2026-11-01T00:00:00Z", "personal"),
        ]])
        let attribution = SpendAttribution(record: record)
        func account(_ day: String, _ hour: String) -> String {
            attribution.account(directory: "default", day: day, hour: hour)
        }
        #expect(account("2026-10-04", "02") == AttributionRecord.unattributed)
        #expect(account("2026-04-05", "02") == AttributionRecord.unattributed)
        for day in ["2026-10-04", "2026-04-05"] {
            #expect(account(day, "01") == "personal")
            #expect(account(day, "03") == "personal")
        }
        #expect(account("2026-06-01", "02") == "personal")
    }

    @Test func aDirectoryWithNoSpansIsItsOwnSeats() {
        let record = AttributionRecord(timeZone: "UTC", directories: [
            "default": [Self.span("2026-09-10T00:00:00Z", "2026-09-11T00:00:00Z", "personal")],
            "work": [Self.span("2026-09-10T00:00:00Z", "2026-09-11T00:00:00Z", AttributionRecord.unattributed)],
        ])
        let attribution = SpendAttribution(record: record)
        #expect(attribution.account(directory: "default", day: "2026-09-10", hour: "09") == "personal")
        #expect(attribution.account(directory: "personal", day: "2026-09-10", hour: "09") == "personal")
        #expect(attribution.account(directory: "codex", day: "2026-09-10", hour: "09") == "codex")
        #expect(attribution.account(directory: "team", day: "2026-08-20", hour: "09") == "team")
        #expect(attribution.account(directory: "work", day: "2026-09-10", hour: "09")
            == AttributionRecord.unattributed)

        let bare = SpendAttribution(record: AttributionRecord(timeZone: "UTC"))
        #expect(bare.account(directory: "default", day: "2026-09-10", hour: "09")
            == AttributionRecord.unattributed)
    }

    @Test func theSpendTabNamesItsLinesByAccount() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let now = Self.date("2026-09-10T12:00:00Z")
        let rows = [Self.row("default", "2026-09-10", "02"), Self.row("default", "2026-09-10", "05"),
                    Self.row("personal", "2026-09-10", "03"), Self.row("codex", "2026-09-10", "04", model: "gpt-6-sol")]
        try scratch.write(SpendCSV.text(rows), to: scratch.csv)
        try Self.writeRecord(AttributionRecord(timeZone: "UTC", directories: ["default": [
            Self.span("2026-09-10T00:00:00Z", "2026-09-10T04:00:00Z", "personal"),
        ]]), to: scratch.attribution)

        func chart() -> SpendChart {
            SpendChart.read(csv: scratch.csv, state: scratch.state, attribution: scratch.attribution,
                            rates: .bundled, now: now, calendar: Self.utc)
        }
        let drawn = chart()
        #expect(drawn.series.map(\.name) == ["codex", "personal", "total"])
        let each = rows.compactMap(\.usd).reduce(0, +) / 3
        #expect(drawn.series.first { $0.name == "personal" }?.points.map(\.amount) == [each * 2])
        #expect(drawn.series.first { $0.name == "total" }?.points.map(\.amount) == [each * 3])
        #expect(drawn.note == nil)

        try scratch.write(SpendCSV.text(rows) + "not,a,row\n", to: scratch.csv)
        let partial = chart()
        #expect(partial.series.map(\.name) == ["codex", "personal", "total"])
        #expect(partial.note != nil)
        #expect(partial.note == SpendCSV.read(scratch.csv, state: scratch.state).reason)

        try scratch.write("seat,day\n", to: scratch.csv)
        let unavailable = chart()
        #expect(unavailable.series.isEmpty)
        #expect(unavailable.emptyMessage != nil)
        #expect(unavailable.emptyMessage == SpendCSV.read(scratch.csv, state: scratch.state).reason)
    }

    @Test @MainActor func theTitleBarSaysWhichRecordItCannotRead() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let good = SpendCSV.text([Self.row("personal", "2026-09-10", "09")])
        let here = TimeZone(identifier: "Asia/Tokyo")!
        let record = AttributionRecord(timeZone: "Asia/Tokyo")

        #expect(PanelProblem.reading(spend: .available(SpendCSV.rows(good)), attribution: .record(record),
                                     zone: here).isEmpty)
        #expect(PanelProblem.reading(spend: .empty, attribution: .missing, zone: here).isEmpty)
        #expect(PanelProblem.reading(spend: .partial([], "1 line"), attribution: .missing, zone: here)
            == [.spendRecord])
        #expect(PanelProblem.reading(spend: .unavailable("gone"), attribution: .malformed("bad"), zone: here)
            == [.spendRecord, .attributionRecord])
        #expect(PanelProblem.reading(spend: .empty, attribution: .record(record),
                                     zone: TimeZone(identifier: "UTC")!) == [.timeZone])

        let mirror = GaugeMirror()
        mirror.configProblem = "seats.json: work needs a profile"
        try scratch.write("{ not json", to: scratch.attribution)
        try scratch.write(good + "not,a,row\n", to: scratch.csv)
        mirror.readSpend(csv: scratch.csv, state: scratch.state, attribution: scratch.attribution)
        #expect(mirror.problems == ["seats.json: work needs a profile", "spend record unreadable",
                                    "attribution record unreadable"])

        try scratch.write(good, to: scratch.csv)
        try FileManager.default.removeItem(at: scratch.attribution)
        mirror.configProblem = nil
        mirror.readSpend(csv: scratch.csv, state: scratch.state, attribution: scratch.attribution)
        #expect(mirror.problems.isEmpty)
    }

    @Test func failsClosedWhenTheAttributionRecordCannotBeTrusted() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let now = Self.date("2026-09-10T12:00:00Z")
        let rows = [Self.row("default", "2026-09-10", "02"), Self.row("personal", "2026-09-10", "03")]
        try scratch.write(SpendCSV.text(rows), to: scratch.csv)

        for attribution in ["{ not json", nil] {
            if let attribution { try scratch.write(attribution, to: scratch.attribution) }
            else { try? FileManager.default.removeItem(at: scratch.attribution) }
            let chart = SpendChart.read(csv: scratch.csv, state: scratch.state, attribution: scratch.attribution,
                                        rates: .bundled, now: now, calendar: Self.utc)
            #expect(chart.series.map(\.name) == ["personal", "total"])
            let each = rows.compactMap(\.usd).reduce(0, +) / 2
            #expect(chart.series.first { $0.name == "personal" }?.points.map(\.amount) == [each])
            #expect(chart.series.first { $0.name == "total" }?.points.map(\.amount) == [each * 2])
        }

        let nowhere = SpendAttribution(record: AttributionRecord(timeZone: "Not/AZone", directories: [
            "default": [Self.span("2026-09-01T00:00:00Z", "2026-09-20T00:00:00Z", "personal")],
        ]))
        #expect(nowhere.account(directory: "default", day: "2026-09-10", hour: "02")
            == AttributionRecord.unattributed)
        #expect(nowhere.account(directory: "personal", day: "2026-09-10", hour: "02") == "personal")
    }
}
