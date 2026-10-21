import Foundation
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// The panel reads the rate card with the record, once, and draws every
/// spend figure from that read.
@Suite(.sharedMirror) @MainActor struct SpendReadOnceTests {
    @Test func drawingAgainReadsNoRateCard() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-read-once-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let today = DateFormatter()
        today.dateFormat = "yyyy-MM-dd"
        let counts = TokenCounts(responses: 1, input: 1_000_000)
        try SpendCSV.write([SpendRow(seat: "personal", day: today.string(from: Date()), hour: "01",
                                     model: "claude-opus-5", counts: counts, usd: nil, sealed: false)],
                           to: folder.appendingPathComponent("spend.csv"))
        let card = RateCard(version: "test", models: ["claude-opus-5": Rate(input: 1234, output: 0, group: "opus")])
        try card.write(to: RateCard.defaultFile)
        defer { try? FileManager.default.removeItem(at: RateCard.defaultFile) }

        let mirror = GaugeMirror()
        mirror.readSpend(csv: folder.appendingPathComponent("spend.csv"),
                         state: folder.appendingPathComponent("state.json"),
                         attribution: folder.appendingPathComponent("attribution.json"))
        try FileManager.default.removeItem(at: RateCard.defaultFile)
        // A new measure redraws the tab; it prices on the card read with the record.
        try mirror.choose(measure: .usd, store: StateStore(file: folder.appendingPathComponent("state.json")))
        let line = try #require(mirror.chart.series.first { $0.name == "personal" })
        #expect(line.points.map(\.amount).reduce(0, +) == 1234)
    }

    @Test("seatgauge-cli spend reads back from the config's spendFrom, as the Spend tab does")
    func cliReadBackHonoursSpendFrom() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sol-spend-read-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Library/Application Support/com.launchastro.seatgauge")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude/projects"),
                                                withIntermediateDirectories: true)
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        let today = format.string(from: Date())
        let oldDay = format.string(from: Calendar.current.date(byAdding: .day, value: -7, to: Date())!)
        let config = "{\"seats\":[],\"spendFrom\":\"\(today)\"}"
        try Data(config.utf8).write(to: support.appendingPathComponent("seats.json"))
        let rows = [oldDay, today].map { day in
            SpendRow(seat: "personal", day: day, hour: "00", model: "claude-opus-5",
                     counts: TokenCounts(responses: 1, input: 1_000_000), usd: 5, sealed: true)
        }
        let csv = support.appendingPathComponent("spend.csv")
        try SpendCSV.write(rows, to: csv)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/seatgauge-cli")
        process.arguments = ["spend"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = root.path
        environment["CFFIXED_USER_HOME"] = root.path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let mirror = GaugeMirror()
        mirror.spendFrom = try ConfigLoader.decode(Data(config.utf8)).spendFrom
        mirror.readSpend(csv: csv, state: support.appendingPathComponent("state.json"),
                         attribution: support.appendingPathComponent("attribution.json"))
        let amount = try #require(mirror.chart.showing(.all).series.first { $0.isTotal })
            .points.map(\.amount).reduce(0, +)
        #expect(amount == 1_000_000)
        let readBack = try #require(output.split(separator: "\n").first { $0.hasPrefix("read back:") })
        let expected = "read back: \(Measure.tokens.figure(amount)), $5.00 on record, as the Spend tab's All draws it"
        #expect(String(readBack) == expected)
    }
}
