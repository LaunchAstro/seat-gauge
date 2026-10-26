import Foundation
import Testing

import SeatGaugeCore
import SeatGaugeTestSupport

/// `spend.csv`'s text columns hold whatever a seat id, an attributed account
/// or a transcript's model says, so a comma, a quote or a line break in one
/// must neither move the other columns nor cost a line. The record is sealed
/// (ADR 0004), so a file written before quoting must read exactly as it did.
@Suite struct SpendCSVFieldTests {
    static let counts = TokenCounts(responses: 1, input: 9, output: 1, thinking: 0,
                                    cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0)

    static func row(seat: String = "default", model: String, usd: Decimal? = nil) -> SpendRow {
        SpendRow(seat: seat, day: "2026-10-25", hour: "22", model: model, counts: counts, usd: usd, sealed: false)
    }

    static func scratch() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-csv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test("a file the old writer wrote reads exactly as it did: the same rows, the same unreadable lines")
    func theOldWritersFileReadsAsBefore() throws {
        // Written by `seatgauge-cli spend` built from main at 6d04442, from
        // invented transcripts: one model with a quote in it, one with a comma,
        // and a seat named `work,team`, which that build accepted.
        let file = Fixture.directory.appendingPathComponent("spend-written-before-quoting.csv")
        let state = try Self.scratch().appendingPathComponent("state.json")
        let expected = [
            SpendRow(seat: "default", day: "2026-10-20", hour: "02", model: "claude-opus-5",
                     counts: TokenCounts(responses: 1, input: 100, output: 10, thinking: 0, cacheRead: 0,
                                         cacheWrite5m: 0, cacheWrite1h: 0),
                     usd: Decimal(string: "0.00075"), sealed: true),
            SpendRow(seat: "default", day: "2026-10-25", hour: "23", model: #"odd"model"#,
                     counts: TokenCounts(responses: 1, input: 7, output: 3, thinking: 0, cacheRead: 0,
                                         cacheWrite5m: 0, cacheWrite1h: 0),
                     usd: nil, sealed: false),
            SpendRow(seat: "default", day: "2026-10-26", hour: "00", model: "claude-opus-5",
                     counts: TokenCounts(responses: 1, input: 50, output: 5, thinking: 0, cacheRead: 0,
                                         cacheWrite5m: 0, cacheWrite1h: 0),
                     usd: Decimal(string: "0.000375"), sealed: false),
            SpendRow(seat: "team-1_b", day: "2026-10-21", hour: "04", model: "claude-sonnet-5",
                     counts: TokenCounts(responses: 1, input: 1000, output: 20, thinking: 0, cacheRead: 0,
                                         cacheWrite5m: 0, cacheWrite1h: 0),
                     usd: Decimal(string: "0.0022"), sealed: true),
        ]
        #expect(SpendCSV.read(file, state: state) == .partial(expected, "spend-written-before-quoting.csv: 2 lines could not be read"))
        #expect(SpendCSV.read(file) == expected)

        // Rewriting what it read changes none of those lines' bytes.
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        let kept = [lines[0], lines[1], lines[2], lines[3], lines[4]]
        #expect(SpendCSV.text(expected) == kept.joined(separator: "\n") + "\n")
    }

    @Test("a comma, a leading quote, a combining mark or a line break in a model or seat survives the round trip, and the record reads whole")
    func oddTextRoundTrips() throws {
        let models = ["vendor,model", #""quoted" model"#, #"odd"model"#, "\u{0301}vendor,model",
                      "\u{0301}\"mark", "\u{0301}plain", "a,\u{0301}b", "x\"\u{0301}", "ends\u{0600}",
                      "cr\rkept", "crlf\r\nkept", "sep\u{2028}kept"]
        let rows = models.map { Self.row(model: $0) }
            + [Self.row(seat: "work,team", model: "claude-opus-5", usd: Decimal(string: "0.5")),
               Self.row(seat: "line\nbreak", model: "lf\nmodel")]
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("spend.csv")
        try SpendCSV.write(rows, to: file)

        let read = SpendCSV.read(file, state: folder.appendingPathComponent("state.json"))
        #expect(read.isWhole)
        #expect(read.rows.map(\.model) == models + ["claude-opus-5", "lf model"])
        #expect(read.rows.map(\.seat) == Array(repeating: "default", count: models.count) + ["work,team", "line break"])
        #expect(read.rows.dropFirst(models.count).first?.usd == Decimal(string: "0.5"))
    }

    @Test("Sol proof, criterion 2: a \\n in a transcript's model is a space before cells are counted, and a \\r or \\r\\n stays as the record kept it")
    func lineBreaksFoldBeforeCounting() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let projects = folder.appendingPathComponent("profile/projects/-home-example-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let models = ["line\nbreak", "line break", "line\rbreak", "line\r\nbreak"]
        let lines = models.enumerated().map { index, model -> String in
            let object: [String: Any] = [
                "type": "assistant", "requestId": "req-\(index)", "sessionId": "s1", "cwd": "/home/example/proj",
                "timestamp": "2026-10-25T22:\(10 + index):00.000Z",
                "message": ["id": "msg-\(index)", "role": "assistant", "model": model,
                            "usage": ["input_tokens": 9, "output_tokens": 1]] as [String: Any],
            ]
            return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: projects.appendingPathComponent("s1.jsonl"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let csv = folder.appendingPathComponent("spend.csv")
        let rollup = SpendCoordinator(csv: csv, state: folder.appendingPathComponent("state.json"),
                                      primer: folder.appendingPathComponent("primer"), codex: nil, calendar: utc)
        let run = try #require(await rollup.run(profiles: [SpendProfile(seat: "work", projects: folder.appendingPathComponent("profile/projects"))],
                                                rates: .bundled, now: SpendRollupTests.date("2026-10-25T23:30:00Z")))
        #expect(run.responses == 4)
        let read = SpendCSV.read(csv, state: folder.appendingPathComponent("state.json"))
        #expect(read.isWhole)
        let byModel = Dictionary(uniqueKeysWithValues: read.rows.map { ($0.model, $0.responses) })
        #expect(byModel == ["line break": 2, "line\rbreak": 1, "line\r\nbreak": 1])
        #expect(read.rows.map(\.input).reduce(0, +) == 36)
    }

    @Test("Sol proof, criterion 2: a row the record kept with a \\r is the cell a fresh walk adds to, so nothing is counted twice")
    func aKeptCarriageReturnIsTheSameCell() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let projects = folder.appendingPathComponent("profile/projects/-home-example-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let object: [String: Any] = [
            "type": "assistant", "requestId": "req-1", "sessionId": "s1", "cwd": "/home/example/proj",
            "timestamp": "2026-10-25T22:30:00.000Z",
            "message": ["id": "msg-1", "role": "assistant", "model": "line\rbreak",
                        "usage": ["input_tokens": 9, "output_tokens": 1]] as [String: Any],
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: projects.appendingPathComponent("s1.jsonl"))
        // The line the writer before quoting made of that response.
        let csv = folder.appendingPathComponent("spend.csv")
        try Data((SpendCSV.header + "\nwork,2026-10-25,22,line\rbreak,1,9,1,0,0,0,0,,false\n").utf8).write(to: csv)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let rollup = SpendCoordinator(csv: csv, state: folder.appendingPathComponent("state.json"),
                                      primer: folder.appendingPathComponent("primer"), codex: nil, calendar: utc)
        _ = try await rollup.run(profiles: [SpendProfile(seat: "work", projects: folder.appendingPathComponent("profile/projects"))],
                                 rates: .bundled, now: SpendRollupTests.date("2026-10-26T01:00:00Z"))
        let read = SpendCSV.read(csv, state: folder.appendingPathComponent("state.json"))
        #expect(read.isWhole)
        #expect(read.rows.map(\.model) == ["line\rbreak"])
        #expect(read.rows.map(\.responses) == [1])
    }

    @Test("Sol proof, criterion 3: a line the record held reads and rewrites byte for byte, a combining mark at its start included")
    func aKeptLineRewritesAsItWas() {
        let lines = ["\u{0301}work,2026-10-25,22,plain,1,9,1,0,0,0,0,,false",
                     #""quoted",2026-10-25,22,odd"model,1,9,1,0,0,0,0,0.5,true"#,
                     "work,2026-10-25,22,cr\rkept,1,9,1,0,0,0,0,,false",
                     "work,2026-10-25,22,crlf\r\nkept,1,9,1,0,0,0,0,,false"]
        let text = SpendCSV.header + "\n" + lines.joined(separator: "\n") + "\n"
        let rows = SpendCSV.rows(text)
        #expect(rows.count == lines.count)
        #expect(rows.first?.seat == "\u{0301}work")
        #expect(rows.dropFirst().first?.seat == #""quoted""#)
        #expect(SpendCSV.text(rows) == text)
    }

    @Test("Sol proof, criterion 2: fresh rows that differ only by a \\n are one cell, added up, from any collector")
    func freshRowsFoldInTheMerge() {
        let counts = TokenCounts(responses: 1, input: 100, output: 10)
        let fresh = ["model\nb", "model b"].map {
            SpendRow(seat: "codex", day: "2026-09-20", hour: "10", model: $0, counts: counts,
                     usd: Decimal(string: "0.25"), sealed: false)
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let merged = SpendCSV.merge([], with: fresh, now: SpendRollupTests.date("2026-09-20T12:00:00Z"), calendar: utc)
        #expect(merged.count == 1)
        #expect(merged.first?.model == "model b")
        #expect(merged.first?.input == 200)
        #expect(merged.first?.responses == 2)
        #expect(merged.first?.usd == Decimal(string: "0.5"))
    }

    @Test("Sol proof, criterion 2: a row decoded from JSON with a \\n in it is written as one readable line")
    func aDecodedRowIsOneLine() throws {
        let json = #"{"seat":"work","day":"2026-10-25","hour":"22","model":"line\nbreak","responses":1,"input":9,"output":1,"thinking":0,"cacheRead":0,"cacheWrite5m":0,"cacheWrite1h":0,"sealed":false}"#
        let row = try JSONDecoder().decode(SpendRow.self, from: Data(json.utf8))
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("spend.csv")
        try SpendCSV.write([row], to: file)
        let read = SpendCSV.read(file, state: folder.appendingPathComponent("state.json"))
        #expect(read.isWhole)
        #expect(read.rows.map(\.model) == ["line break"])
    }

    @Test("a quoted line that does not close is skipped alone, and a line the record skipped before is still skipped")
    func aBrokenQuoteCostsOneLine() {
        let text = SpendCSV.header + "\n"
            + #""default","2026-10-25","20","unclosed,"1","9","1","0","0","0","0","","false""# + "\n"
            + #""default","2026-10-25","21","a,b","1","9","1","0","0","0","0","","false""# + "\n"
            + #"default,2026-10-25,22,"a,b",1,9,1,0,0,0,0,,false"# + "\n"
            + "default,2026-10-25,23,claude-opus-5,1,9,1,0,0,0,0,,false\n"
        #expect(SpendCSV.rows(text).map(\.hour) == ["21", "23"])
        #expect(SpendCSV.rows(text).first?.model == "a,b")
    }
}
