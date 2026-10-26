import Foundation
import Testing

import SeatGaugeCore
import SeatGaugeTestSupport

/// `spend.csv`'s model column holds whatever a transcript says, so a comma, a
/// line break or a mark that joins the comma beside it must neither move the
/// other columns nor cost a line. The record is sealed (ADR 0004), so a file
/// the old writer wrote must read exactly as it did, and rewrite its readable
/// lines byte for byte.
@Suite struct SpendCSVFieldTests {
    static let counts = TokenCounts(responses: 1, input: 9, output: 1)

    static func row(seat: String = "default", model: String) -> SpendRow {
        SpendRow(seat: seat, day: "2026-10-25", hour: "22", model: model, counts: counts, usd: nil, sealed: false)
    }

    static func scratch() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-csv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func line(_ index: Int, model: String, at timestamp: String, input: Int = 9) -> String {
        let object: [String: Any] = [
            "type": "assistant", "requestId": "req-\(index)", "sessionId": "s1", "cwd": "/home/example/proj",
            "timestamp": timestamp,
            "message": ["id": "msg-\(index)", "role": "assistant", "model": model,
                        "usage": ["input_tokens": input, "output_tokens": 1]] as [String: Any],
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    /// One roll-up over one invented transcript, into `folder`.
    static func rollUp(_ lines: [String], in folder: URL, now: String,
                       rates: RateCard = .bundled) async throws -> SpendRun? {
        let projects = folder.appendingPathComponent("profile/projects/-home-example-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: projects.appendingPathComponent("s1.jsonl"))
        let rollup = SpendCoordinator(csv: folder.appendingPathComponent("spend.csv"),
                                      state: folder.appendingPathComponent("state.json"),
                                      primer: folder.appendingPathComponent("primer"), codex: nil,
                                      calendar: SpendRollupTests.utc)
        return try await rollup.run(
            profiles: [SpendProfile(seat: "work", projects: folder.appendingPathComponent("profile/projects"))],
            rates: rates, now: SpendRollupTests.date(now))
    }

    @Test("a file the old writer wrote reads exactly as it did: the same rows, the same unreadable lines, its readable lines rewritten byte for byte")
    func theOldWritersFileReadsAsBefore() throws {
        // Written by `seatgauge-cli spend` built from main at 99cff86 under a
        // scratch home with TZ=UTC, from one invented transcript whose models
        // were `claude-opus-5`, `vendor,model`, a model whose line breaks
        // carry a quoted line and two plain ones, `cr\rkept` and a model
        // starting with U+0301.
        let file = Fixture.directory.appendingPathComponent("spend-written-before-folding.csv")
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        func row(_ hour: String, _ model: String, _ input: Int, _ output: Int, _ usd: String?) -> SpendRow {
            SpendRow(seat: "default", day: "2026-10-25", hour: hour, model: model,
                     counts: TokenCounts(responses: 1, input: input, output: output),
                     usd: usd.flatMap { Decimal(string: $0) }, sealed: false)
        }
        let expected = [row("00", "claude-opus-5", 10, 1, "0.000075"), row("02", "prefix", 9, 1, nil),
                        row("22", "tail", 30, 3, nil), row("03", "cr\rkept", 40, 4, nil)]
        #expect(SpendCSV.read(file, state: folder.appendingPathComponent("state.json"))
            == .partial(expected, "spend-written-before-folding.csv: 3 lines could not be read"))
        #expect(SpendCSV.read(file) == expected)

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(SpendCSV.text(expected) == [lines[0], lines[1], lines[3], lines[5], lines[6]].joined(separator: "\n") + "\n")
    }

    @Test("a comma, a line break, or a mark that joins the comma beside it, in a model or seat, is written as a space and the record reads whole")
    func oddTextReadsWhole() throws {
        let models = ["vendor,model", "line\nbreak", "\u{0301}mark", "ends\u{0600}", "a,\u{0301}b",
                      #""quoted" model"#, #"odd"model"#, "cr\rkept", "crlf\r\nkept", "sep\u{2028}kept", ",", "\n", ""]
        let rows = models.map { Self.row(model: $0) } + [Self.row(seat: "work\u{0600}", model: "plain")]
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("spend.csv")
        try SpendCSV.write(rows, to: file)

        let read = SpendCSV.read(file, state: folder.appendingPathComponent("state.json"))
        #expect(read.isWhole)
        #expect(read.rows == rows)
        #expect(read.rows.map(\.model) == ["vendor model", "line break", " \u{0301}mark", "ends\u{0600} ",
                                           "a,\u{0301}b", #""quoted" model"#, #"odd"model"#, "cr\rkept",
                                           "crlf\r\nkept", "sep\u{2028}kept", " ", " ", "", "plain"])
        #expect(read.rows.last?.seat == "work\u{0600} ")
    }

    @Test("every seat and model built from separators, quotes and joining marks is written as a line that reads back as its own row")
    func anyTextReadsBack() {
        let pieces = [",", "\n", "\r", "\r\n", "\"", " ", "a", "\u{0301}", "\u{0600}", "\u{200D}", "\u{0915}",
                      "\u{094D}", "\u{0903}", "\u{1F1E6}", "\u{1F44D}", "\u{2028}", "\u{FE0F}", "\u{1100}", "\u{1161}"]
        var state: UInt64 = 0x5EA7_6A06
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        func text() -> String { (0 ..< next(6)).map { _ in pieces[next(pieces.count)] }.joined() }
        let rows = (0 ..< 5000).map { _ in Self.row(seat: text(), model: text()) }
        #expect(SpendCSV.rows(SpendCSV.text(rows)) == rows)
    }

    @Test("a model differing only by a comma or a \\n is one cell before it is counted, and a \\r or \\r\\n stays as the record kept it")
    func separatorsFoldBeforeCounting() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let models = ["line\nbreak", "line break", "line,break", "line\rbreak", "line\r\nbreak"]
        let lines = models.enumerated().map { Self.line($0, model: $1, at: "2026-10-25T22:\(10 + $0):00.000Z") }
        let run = try #require(try await Self.rollUp(lines, in: folder, now: "2026-10-25T23:30:00Z"))
        #expect(run.responses == 5)
        let read = SpendCSV.read(folder.appendingPathComponent("spend.csv"), state: folder.appendingPathComponent("state.json"))
        #expect(read.isWhole)
        let byModel = Dictionary(uniqueKeysWithValues: read.rows.map { ($0.model, $0.responses) })
        #expect(byModel == ["line break": 3, "line\rbreak": 1, "line\r\nbreak": 1])
        #expect(read.rows.map(\.input).reduce(0, +) == 45)
    }

    @Test("the old writer's transcripts, rolled up afresh, give a record that reads whole")
    func oddTranscriptsRollUpWhole() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ghost = "prefix,1,9,1,0,0,0,0,,false\n\"victim\",\"2026-10-20\",\"02\",\"ghost\",\"1\",\"900000\",\"1\",\"0\",\"0\",\"0\",\"0\",\"123.45\",\"true\"\ndefault,2026-10-25,22,tail"
        let models = ["claude-opus-5", "vendor,model", ghost, "\u{0301}mark"]
        let lines = models.enumerated().map { Self.line($0, model: $1, at: "2026-10-25T0\($0):30:00.000Z") }
        _ = try #require(try await Self.rollUp(lines, in: folder, now: "2026-10-25T06:00:00Z"))
        let read = SpendCSV.read(folder.appendingPathComponent("spend.csv"), state: folder.appendingPathComponent("state.json"))
        #expect(read.isWhole)
        #expect(read.rows.count == 4)
        #expect(read.rows.map(\.seat) == ["work", "work", "work", "work"])
        #expect(read.rows.compactMap(\.usd).allSatisfy { $0 < 1 })
        #expect(read.rows.map(\.input).reduce(0, +) == 36)
    }

    @Test("Sol r1: a rate is found by the name the record writes, so the roll-up and the views that reprice agree, and two rates that fold to one name leave it unpriced",
          arguments: [true, false])
    func ratesAreFoundByTheWrittenName(bothListed: Bool) async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        var models = ["vendor,model": Rate(input: 1, output: 0, group: "other")]
        if bothListed { models["vendor model"] = Rate(input: 2, output: 0, group: "other") }
        let rates = RateCard(version: "test", models: models)
        let lines = [Self.line(0, model: "vendor,model", at: "2026-10-25T22:10:00.000Z", input: 1_000_000),
                     Self.line(1, model: "vendor model", at: "2026-10-25T22:20:00.000Z", input: 1_000_000)]
        _ = try #require(try await Self.rollUp(lines, in: folder, now: "2026-10-25T23:30:00Z", rates: rates))
        let read = SpendCSV.read(folder.appendingPathComponent("spend.csv"), state: folder.appendingPathComponent("state.json"))
        let row = try #require(read.rows.first)
        #expect(read.rows.count == 1)
        #expect(row.model == "vendor model")
        #expect(row.responses == 2)
        #expect(row.usd == (bothListed ? nil : 2))
        #expect(rates.usd(model: row.model, counts: row.counts) == row.usd)
        #expect(rates.rate(for: "vendor,model") == (bothListed ? nil : models["vendor,model"]))
        // A plain card prices as it always has.
        #expect(RateCard.bundled.rate(for: "claude-opus-5") == RateCard.bundled.models["claude-opus-5"])
        let decoded = try JSONDecoder().decode(RateCard.self, from: JSONEncoder().encode(rates))
        #expect(decoded == rates)
    }

    @Test("a row the record kept with a \\r is the cell a fresh walk adds to, so nothing is counted twice")
    func aKeptCarriageReturnIsTheSameCell() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        // The line the old writer made of that response.
        try Data((SpendCSV.header + "\nwork,2026-10-25,22,line\rbreak,1,9,1,0,0,0,0,,false\n").utf8)
            .write(to: folder.appendingPathComponent("spend.csv"))
        _ = try await Self.rollUp([Self.line(1, model: "line\rbreak", at: "2026-10-25T22:30:00.000Z")],
                                  in: folder, now: "2026-10-26T01:00:00Z")
        let read = SpendCSV.read(folder.appendingPathComponent("spend.csv"), state: folder.appendingPathComponent("state.json"))
        #expect(read.isWhole)
        #expect(read.rows.map(\.model) == ["line\rbreak"])
        #expect(read.rows.map(\.responses) == [1])
    }

    @Test("#143: the old writer's line for a model starting with a joining mark goes once a walk writes that response under its real hour, so it is counted once")
    func aMisreadHourGoesOnceTheWalkRecountsIt() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        // The line the old writer made of model `\u{0301}x,y`: the mark joins
        // the comma before it, so it reads with hour `22,\u{0301}x` and model `y`.
        try Data((SpendCSV.header + "\nwork,2026-10-25,22,\u{0301}x,y,1,9,1,0,0,0,0,,false\n").utf8)
            .write(to: folder.appendingPathComponent("spend.csv"))
        _ = try await Self.rollUp([Self.line(1, model: "\u{0301}x,y", at: "2026-10-25T22:30:00.000Z")],
                                  in: folder, now: "2026-10-26T01:00:00Z")
        let read = SpendCSV.read(folder.appendingPathComponent("spend.csv"), state: folder.appendingPathComponent("state.json"))
        #expect(read.isWhole)
        #expect(read.rows.map(\.hour) == ["22"])
        #expect(read.rows.map(\.model) == [" \u{0301}x y"])
        #expect(read.rows.map(\.responses) == [1])
    }

    @Test("#143: a misread line stays while nothing in the record counts its response again (ADR 0004)")
    func aMisreadHourStaysUntilRecounted() {
        let misread = SpendCSV.rows(SpendCSV.header + "\nwork,2026-10-25,22,\u{0301}x,y,1,9,1,0,0,0,0,,false\n")
        #expect(misread.map(\.hour) == ["22,\u{0301}x"])
        // A walk that found other responses that day, but not this one.
        let fresh = [Self.row(seat: "work", model: "claude-opus-5"), Self.row(seat: "work", model: "y")]
        let now = SpendRollupTests.date("2026-10-26T01:00:00Z")
        let merged = SpendCSV.merge(misread, with: fresh, now: now, calendar: SpendRollupTests.utc)
        #expect(merged.count == 3)
        #expect(merged.contains(misread[0]))
        // A row the record holds as sealed is never dropped.
        let sealed = misread.map { SpendRow(cell: $0.cell, counts: $0.counts, usd: nil, sealed: true) }
        let recount = [Self.row(seat: "work", model: "\u{0301}x,y")]
        #expect(SpendCSV.merge(sealed, with: recount, now: now, calendar: SpendRollupTests.utc).count == 2)
    }

    @Test("a line the record held reads and rewrites byte for byte, a combining mark or a quote at its start included")
    func aKeptLineRewritesAsItWas() {
        let lines = ["\u{0301}work,2026-10-25,22,plain,1,9,1,0,0,0,0,,false",
                     #""quoted",2026-10-25,22,odd"model,1,9,1,0,0,0,0,0.5,true"#,
                     "work,2026-10-25,22,cr\rkept,1,9,1,0,0,0,0,,false",
                     "work,2026-10-25,22,crlf\r\nkept,1,9,1,0,0,0,0,,false",
                     "work,2026-10-25,22,a\u{0600},b,1,9,1,0,0,0,0,,false"]
        let text = SpendCSV.header + "\n" + lines.joined(separator: "\n") + "\n"
        let rows = SpendCSV.rows(text)
        #expect(rows.count == lines.count)
        #expect(rows.first?.seat == "\u{0301}work")
        #expect(rows.dropFirst().first?.seat == #""quoted""#)
        #expect(rows.last?.model == "a\u{0600},b")
        #expect(SpendCSV.text(rows) == text)
    }

    @Test("a row decoded from JSON goes through the same fold, so it is written as one readable line (#109)")
    func aDecodedRowIsOneLine() throws {
        let json = #"{"seat":"work","day":"2026-10-25","hour":"22","model":"line\nbreak,b","responses":1,"input":9,"output":1,"thinking":0,"cacheRead":0,"cacheWrite5m":0,"cacheWrite1h":0,"sealed":false}"#
        let row = try JSONDecoder().decode(SpendRow.self, from: Data(json.utf8))
        #expect(row.model == "line break b")
        #expect(row.cell == SpendCell(seat: "work", day: "2026-10-25", hour: "22", model: "line\nbreak,b"))
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("spend.csv")
        try SpendCSV.write([row], to: file)
        let read = SpendCSV.read(file, state: folder.appendingPathComponent("state.json"))
        #expect(read.isWhole)
        #expect(read.rows == [row])
        #expect(try JSONDecoder().decode(SpendRow.self, from: JSONEncoder().encode(row)) == row)
    }
}
