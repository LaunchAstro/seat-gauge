import Foundation
import Testing
@testable import SeatGaugeCore

/// Issue #94: `log.json` stays inside what a reader accepts for any number of
/// machines, on a budget each machine's probe and the app work out from the
/// config alone.
@Suite struct LogCapTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func closed(_ index: Int, label: String = "PROJECT-Log-work", at now: Date? = nil) -> SessionRow {
        let now = now ?? self.now
        var row = SessionRow(sessionId: "closed-\(index)", workspace: label, pane: "w1:p1", tool: "codex", status: "closed", asOf: now)
        row.closedAt = now.addingTimeInterval(-Double(index) * 10)
        row.tokens = TokenCounts(responses: 1, input: 100)
        return row
    }

    @Test("the probe takes its share as two bounded whole numbers and passes over anything else")
    func probeArguments() {
        let standard = SessionRetention.Budget.share(machines: 1)
        #expect(standard == SessionRetention.Budget(rows: 2_000, bytes: 2_000_000))
        let parsed = SessionProbe.arguments(["--directory", "/tmp/x", "--keep-rows", "500", "--keep-bytes", "500000"])
        #expect(parsed.directory?.path == "/tmp/x")
        #expect(parsed.keep == SessionRetention.Budget(rows: 500, bytes: 500_000))
        // Flags it does not know, in any order, change nothing.
        let mixed = SessionProbe.arguments(["--future", "--keep-bytes", "9000", "--colour", "red", "--keep-rows", "3"])
        #expect(mixed.keep == SessionRetention.Budget(rows: 3, bytes: 9_000))
        #expect(mixed.directory == nil)
        // Anything but a whole number in range leaves the standard share.
        for bad in [["--keep-rows", "0", "--keep-bytes", "10"], ["--keep-rows", "-4", "--keep-bytes", "10"],
                    ["--keep-rows", "2001", "--keep-bytes", "10"], ["--keep-rows", "5", "--keep-bytes", "2000001"],
                    ["--keep-rows", "5e2", "--keep-bytes", "10"], ["--keep-rows", "5;rm", "--keep-bytes", "10"],
                    ["--keep-rows", "99999999999999999999", "--keep-bytes", "10"], ["--keep-rows", "5"], ["--keep-rows"]] {
            #expect(SessionProbe.arguments(bad).keep == standard)
        }
        #expect(SessionProbe.arguments([]).directory == nil)
    }

    @Test("the app sends each machine its share of the file, worked out from the number of machines")
    func appSendsTheShare() async throws {
        let sent = Sent()
        let machines = (1...3).map { Machine(id: "m\($0)", label: "M\($0)", ssh: "m\($0)") } + [.here]
        let monitor = SessionLogMonitor(prober: MachineProber(runner: RecordingRunner(sent: sent), environment: [:]),
                                        file: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json"),
                                        config: { Config(seats: [], pollMinutes: 5, machines: machines) })
        _ = await monitor.read()
        #expect(sent.lines.count == 4)
        #expect(sent.lines.allSatisfy { $0.hasSuffix(" log-probe --keep-rows 500 --keep-bytes 500000")
            || $0.contains(" log-probe --directory ") && $0.hasSuffix(" --keep-rows 500 --keep-bytes 500000") })
    }

    @Test("a machine's share holds its open sessions, never dropped, and the newest closed ones that fit by row and by byte")
    func shareByRowsAndBytes() throws {
        let rows = (0..<300).map { closed($0) }
        let open = (0..<5).map { SessionRow(sessionId: "open-\($0)", workspace: "PROJECT-Log-work", pane: "w1:p\($0)",
                                            tool: "claude", status: "working", asOf: now) }
        let byRows = try #require(SessionRetention.Budget(rows: 50, bytes: SessionRetention.fileBytes))
        let kept = SessionRetention.kept((rows + open).shuffled(), row: { $0 }, now: now, budget: byRows)
        #expect(Set(kept.map(\.sessionId)) == Set(open.map(\.sessionId) + (0..<45).map { "closed-\($0)" }))
        // By bytes: the open rows and as many of the newest closed as fit.
        let size = rows.prefix(10).reduce(0) { $0 + SessionRetention.size($1) }
            + open.reduce(0) { $0 + SessionRetention.size($1) }
        let byBytes = try #require(SessionRetention.Budget(rows: 2_000, bytes: size + 5))
        let fitted = SessionRetention.kept(rows + open, row: { $0 }, now: now, budget: byBytes)
        #expect(Set(fitted.map(\.sessionId)) == Set(open.map(\.sessionId) + (0..<10).map { "closed-\($0)" }))
        // Open rows past the budget are all kept, with no closed one.
        let tight = try #require(SessionRetention.Budget(rows: 2, bytes: 10))
        #expect(Set(SessionRetention.kept(rows + open, row: { $0 }, now: now, budget: tight).map(\.sessionId)) == Set(open.map(\.sessionId)))
        // What was kept passes again whole, so the app keeps what a probe kept.
        #expect(SessionRetention.kept(fitted, row: { $0 }, now: now, budget: byBytes).map(\.sessionId) == fitted.map(\.sessionId))
        // The app's own fields do not change the measure.
        var marked = rows[0]; marked.machine = "a-long-machine-name"; marked.stale = true
        #expect(SessionRetention.size(marked) == SessionRetention.size(rows[0]))
    }

    @Test("forty machines with long labels, each sending more than its share, stay inside what a reader accepts")
    func manyMachinesStayInsideTheReader() async throws {
        let label = String(repeating: "L", count: 200) + "-" + String(repeating: "S", count: 150) + "-" + String(repeating: "W", count: 150)
        // The app reads the clock, so the rows are dated from it.
        let current = Date()
        var sessions = (0..<400).map { closed($0, label: label, at: current) }
        sessions += (0..<20).map { SessionRow(sessionId: "open-\($0)", workspace: label, pane: "w1:p\($0)", tool: "claude",
                                              status: "working", asOf: current) }
        let answer = String(decoding: try SessionLogFile.encoder().encode(SessionLogFile(updated: Date(), sessions: sessions)), as: UTF8.self)
        let machines = (1...40).map { Machine(id: "machine-\($0)", label: "M\($0)", ssh: "m\($0)") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let monitor = SessionLogMonitor(prober: MachineProber(runner: Answer(line: answer), environment: [:]),
                                        file: file, config: { Config(seats: [], pollMinutes: 5, machines: machines) })
        let log = await monitor.read()
        #expect(log.sessions.count <= 5_000)
        #expect(try Data(contentsOf: file).count <= 4_000_000)
        // Every open row on every machine is there.
        #expect(log.sessions.filter { $0.closedAt == nil }.count == 40 * 20)
        #expect(log.sessions.filter { $0.closedAt != nil }.count > 0)
        // A second monitor on the same config keeps the same rows.
        let again = await SessionLogMonitor(prober: MachineProber(runner: Answer(line: answer), environment: [:]),
                                            file: file, config: { Config(seats: [], pollMinutes: 5, machines: machines) }).read()
        #expect(Set(again.sessions.map(\.id)) == Set(log.sessions.map(\.id)))
    }

    @Test("a probe on a small share drops what does not fit from its ledger and checkpoint at the end of the pass")
    func probeDropsBeyondItsShare() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("rollout-old.jsonl").path
        let start = Date()
        try SessionLedger(directory: directory).append((0..<12).map { index in
            var row = SessionRow(sessionId: "closed-\(index)", workspace: "PROJECT-Log-work", pane: "w1:p1", tool: "codex",
                                 status: "closed", asOf: start)
            row.closedAt = start.addingTimeInterval(-Double(index) * 60)
            return SessionObservation(row: row, pid: 100 + index, processStart: "start", paths: index == 11 ? [path] : [])
        })
        var state = SessionCheckpoint()
        state.files[path] = SessionTokens(); state.owners[path] = "closed-11"
        try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("offsets.json"))
        let keep = try #require(SessionRetention.Budget(rows: 10, bytes: SessionRetention.fileBytes))
        let log = try await SessionProbe(runner: Answer(lines: { $0 == ["pane", "list"] ? [#"{"result":{"panes":[]}}"#]
            : $0 == ["workspace", "list"] ? [#"{"result":{"workspaces":[]}}"#] : [] }), directory: directory, home: root, keep: keep).run(now: start)
        #expect(Set(log.sessions.map(\.sessionId)) == Set((0..<10).map { "closed-\($0)" }))
        #expect(Set(try SessionLedger(directory: directory).rows().keys) == Set((0..<10).map { "closed-\($0)" }))
        let checkpoint = try JSONDecoder().decode(SessionCheckpoint.self, from: Data(contentsOf: directory.appendingPathComponent("offsets.json")))
        #expect(checkpoint.files[path] == nil)
    }
}

private final class Sent: @unchecked Sendable {
    private let lock = NSLock()
    private var said: [String] = []
    func add(_ line: String) { lock.withLock { said.append(line) } }
    var lines: [String] { lock.withLock { said } }
}

private struct RecordingRunner: ProcessRunning {
    let sent: Sent
    func launch(_ spec: ProcessSpec) throws -> any ProcessSession { CapSession(lines: [], sent: sent) }
}

private struct Answer: ProcessRunning {
    let lines: @Sendable ([String]) -> [String]
    init(line: String) { lines = { _ in [line] } }
    init(lines: @escaping @Sendable ([String]) -> [String]) { self.lines = lines }
    func launch(_ spec: ProcessSpec) throws -> any ProcessSession { CapSession(lines: lines(spec.arguments), sent: nil) }
}

private struct CapSession: ProcessSession {
    let stdoutLines: AsyncThrowingStream<String, Error>
    let sent: Sent?
    init(lines: [String], sent: Sent?) {
        self.sent = sent
        stdoutLines = AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
    func send(_ line: String) throws { sent?.add(line) }
    func closeInput() {}
    func terminate() {}
}
