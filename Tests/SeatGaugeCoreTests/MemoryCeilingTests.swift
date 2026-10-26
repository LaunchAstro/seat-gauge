import Foundation
import Testing

@testable import SeatGaugeCore

/// The app runs all day, so no transcript and no child process may grow its
/// memory without bound. A line past `TranscriptLines.longestLine` is dropped
/// as it streams, a Log pass stops near its budget even inside such a line,
/// and a child that prints past its spec's limit is stopped.
@Suite struct MemoryCeilingTests {
    static func scratch() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-ceiling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func assistant(_ id: String, input: Int, padding: Int = 0) -> String {
        let text = String(repeating: "x", count: padding)
        return #"{"type":"assistant","timestamp":"2026-10-15T01:00:00Z","requestId":"request-\#(id)","message":{"id":"msg_\#(id)","model":"claude-test","content":[{"text":"\#(text)"}],"usage":{"input_tokens":\#(input),"output_tokens":1}}}"#
    }

    /// Just past the line ceiling.
    static var oversized: Int { TranscriptLines.longestLine + 1024 }

    // MARK: - Spend's transcript walk

    @Test("an assistant line past the line ceiling is skipped, and the lines after it still count")
    func spendDropsAnOversizedLine() throws {
        let root = try Self.scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let lines = [Self.assistant("a", input: 10), Self.assistant("big", input: 1000, padding: Self.oversized),
                     Self.assistant("b", input: 20)]
        try Data(lines.joined(separator: "\n").utf8).write(to: file)
        let reading = ClaudeCollector.read(file: file, primer: root.appendingPathComponent("primer"))
        #expect(reading.responses.map(\.messageID) == ["msg_a", "msg_b"])
        #expect(reading.skipped == 1)
    }

    @Test("a transcript under the ceiling reads exactly as before, a last line without a newline included")
    func spendOrdinaryFile() throws {
        let root = try Self.scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        // Big enough to span several reads, and no newline at the end.
        let lines = (0 ..< 40).map { Self.assistant("m\($0)", input: $0 + 1, padding: 20_000) }
        let text = lines.joined(separator: "\n")
        try Data(text.utf8).write(to: file)
        var seen: Set<String> = []
        let whole = ClaudeCollector.read(data: Data(text.utf8), primer: root.appendingPathComponent("primer"), seen: &seen)
        let streamed = ClaudeCollector.read(file: file, primer: root.appendingPathComponent("primer"))
        #expect(streamed.responses == whole.responses)
        #expect(streamed.responses.count == 40)
        #expect(streamed.skipped == 0)
    }

    @Test("a Codex line past the ceiling is unreadable without being decoded")
    func codexDropsAnOversizedLine() throws {
        let root = try Self.scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-big.jsonl")
        let usage = #"{"input_tokens":100,"output_tokens":10,"total_tokens":110}"#
        func tokens(_ at: String, padding: Int = 0) -> String {
            #"{"timestamp":"\#(at)","type":"event_msg","payload":{"type":"token_count","pad":"\#(String(repeating: "x", count: padding))","info":{"total_token_usage":\#(usage),"last_token_usage":\#(usage)}}}"#
        }
        let lines = [#"{"timestamp":"2026-09-20T10:00:00Z","type":"session_meta","payload":{"id":"session-big","cwd":"/work/project"}}"#,
                     tokens("2026-09-20T10:15:00Z", padding: Self.oversized)]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        let reading = CodexRollout.read(files: [file], calendar: Calendar(identifier: .gregorian))
        #expect(reading.cells.isEmpty)
        #expect(reading.skipped == 1)
    }

    static func allocated() -> Int {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return Int(statistics.size_in_use)
    }

    @Test("Sol proof, criterion 1: transcript chunks release memory during a file read")
    func chunksAreReleased() throws {
        let root = try Self.scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let line = Data(("{\"type\":\"user\",\"text\":\"" + String(repeating: "x", count: 1000) + "\"}\n").utf8)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        for _ in 0 ..< 48 { try handle.write(contentsOf: Data((0 ..< 1024).flatMap { _ in line })) }
        try handle.close()
        // Inside one pool, as a caller's own would be: what the read leaves
        // live is what it would hold until that pool drains.
        autoreleasepool {
            let before = Self.allocated()
            let reading = ClaudeCollector.read(file: file, primer: root.appendingPathComponent("primer"))
            let growth = Self.allocated() - before
            #expect(reading.responses.isEmpty)
            #expect(growth < 2 * TranscriptLines.longestLine, "\(growth) bytes still live after a 48 MB read")
        }
    }

    // MARK: - The Log's incremental read

    @Test("a torn line past the ceiling is passed by within one pass, and never kept in the checkpoint")
    func logPassesAnOversizedTornLine() throws {
        let root = try Self.scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let first = Self.assistant("a", input: 10) + "\n"
        let torn = String(repeating: "y", count: Self.oversized)
        try Data((first + torn).utf8).write(to: file)

        var state = SessionTokens()
        try state.read(file, tool: "claude", budget: 1 << 20)
        #expect(state.total.input == 10)
        // Past the torn line, rather than parked before it to read it whole
        // again on every pass.
        #expect(state.offset == UInt64(first.utf8.count + torn.utf8.count))
        let checkpoint = try JSONEncoder().encode(state)
        #expect(checkpoint.count < 64 << 10)

        // The line ends later; what follows it is read, and its end is not
        // taken for a line of its own.
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: Data(("yyyy\"}}\n" + Self.assistant("b", input: 20) + "\n").utf8))
        try handle.close()
        state = try JSONDecoder().decode(SessionTokens.self, from: checkpoint)
        try state.read(file, tool: "claude", budget: 1 << 20)
        #expect(state.total.input == 30)
        #expect(state.complete)
    }

    @Test("a pass stops near its budget even inside an oversized line")
    func logPassStopsNearItsBudget() throws {
        let root = try Self.scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let huge = String(repeating: "z", count: 3 * TranscriptLines.longestLine) + "\n" + Self.assistant("a", input: 10) + "\n"
        try Data(huge.utf8).write(to: file)
        var state = SessionTokens()
        try state.read(file, tool: "claude", budget: 1 << 20)
        #expect(state.offset <= UInt64(TranscriptLines.longestLine + (2 << 20)))
        while !state.complete { try state.read(file, tool: "claude", budget: 1 << 20) }
        #expect(state.total.input == 10)
    }

    // MARK: - Child output

    static func run(_ script: String, limit: Int) async -> Error? {
        let quiet = SearchPath(shell: nil, home: NSTemporaryDirectory())
        do {
            let session = try RealProcessRunner(searchPath: quiet).launch(ProcessSpec(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(4), outputLimit: limit))
            for try await _ in session.stdoutLines {}
            return nil
        } catch { return error }
    }

    @Test("a child that prints lines past its limit is stopped and named as such, not left to the timeout")
    func childLineFlood() async {
        let error = await Self.run("yes | head -c 8000000; sleep 30", limit: 1 << 20)
        #expect((error as? ProcessFailure)?.reason.contains("ran past 1 MB") == true, "\(String(describing: error))")
    }

    @Test("a child that prints one endless line is stopped the same way")
    func childTornFlood() async {
        let error = await Self.run("head -c 8000000 /dev/zero | tr '\\000' x; sleep 30", limit: 1 << 20)
        #expect((error as? ProcessFailure)?.reason.contains("ran past 1 MB") == true, "\(String(describing: error))")
    }

    @Test("a child under its limit reads every line as before")
    func childUnderLimit() async throws {
        let quiet = SearchPath(shell: nil, home: NSTemporaryDirectory())
        let session = try RealProcessRunner(searchPath: quiet).launch(ProcessSpec(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf 'one\\ntwo\\nthree\\n'"],
            environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(10), outputLimit: 1 << 20))
        var lines: [String] = []
        for try await line in session.stdoutLines { lines.append(line) }
        #expect(lines == ["one", "two", "three"])
    }
}
