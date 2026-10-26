import Foundation
import Testing

@testable import SeatGaugeCore

/// Numbers from outside the app (a remote machine's probe, a Codex rollout, a
/// rate-limit reply, the config file) used to reach trapping arithmetic, and a
/// trap ends the always-on process, which then meets the same input on
/// relaunch. Each case is the security review's own input, and passes when the
/// value is refused or saturated rather than crashing the test run.
@Suite struct CheckedNumbersTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// A probe answer in round numbers, with one line swapped for `line`.
    static func probe(_ key: String, _ line: String) -> [String] {
        let good = [
            "cores 10",
            "memsize 34359738368",
            "memfree 70",
            "load { 4.00 3.00 2.00 }",
            "disk /dev/disk3s5   1000000000 800000000 200000000    80% 100 200 1%   /System/Volumes/Data",
            "cpu CPU usage: 30.0% user, 10.0% sys, 60.0% idle ",
            "end",
        ]
        return good.map { $0.hasPrefix(key + " ") ? line : $0 }
    }

    // MARK: - MachineLoad

    @Test("a disk row whose free blocks overflow bytes is no reading")
    func diskOverflow() {
        #expect(MachineProbe.parse(Self.probe("disk", "disk /dev/x 100 50 9223372036854775807"), at: Self.now) == nil)
    }

    @Test("a negative or absurd free block count is no reading")
    func diskNegative() {
        #expect(MachineProbe.parse(Self.probe("disk", "disk dev 100 0 -9223372036854775807"), at: Self.now) == nil)
        #expect(MachineProbe.parse(Self.probe("disk", "disk dev nan 0 10"), at: Self.now) == nil)
    }

    @Test("an idle figure too long for a Double is no reading")
    func cpuInfinite() {
        let digits = String(repeating: "9", count: 400)
        #expect(MachineProbe.parse(Self.probe("cpu", "cpu CPU usage: 0% user, \(digits)% idle"), at: Self.now) == nil)
    }

    @Test("non-finite loads, a core count of none and memory out of range are no reading",
          arguments: [("load", "load { inf 1.0 1.0 }"), ("load", "load { nan 1.0 1.0 }"),
                      ("load", "load { -1.0 1.0 1.0 }"), ("load", "load { 1e300 1.0 1.0 }"), ("cores", "cores 0"), ("cores", "cores -4"),
                      ("memfree", "memfree 101"), ("memfree", "memfree -9223372036854775808"),
                      ("memsize", "memsize -1")])
    func outOfRange(_ key: String, _ line: String) {
        #expect(MachineProbe.parse(Self.probe(key, line), at: Self.now) == nil)
    }

    @Test("an ordinary answer still reads the same")
    func ordinaryProbe() throws {
        let reading = try #require(MachineProbe.parse(Self.probe("end", "end"), at: Self.now))
        #expect(reading.diskFreeBytes == 200_000_000 * 1024)
        #expect(reading.cpuUsed == 40)
        #expect(reading.ramUsed == 30)
    }

    // MARK: - Codex rollouts

    static func rollout(_ usage: String) throws -> CodexReading {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-numbers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rollout-numbers.jsonl")
        let lines = [
            #"{"timestamp":"2026-09-20T10:00:00Z","type":"session_meta","payload":{"id":"session-numbers","cwd":"/work/project"}}"#,
            #"{"timestamp":"2026-09-20T10:00:01Z","type":"turn_context","payload":{"model":"gpt-6-sol"}}"#,
            #"{"timestamp":"2026-09-20T10:15:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":\#(usage),"last_token_usage":\#(usage)}}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return CodexRollout.read(files: [file], calendar: utc)
    }

    @Test("a rollout with both cache counts at Int.max is an unreadable line, not a trap")
    func codexCacheUnderflow() throws {
        let max = Int.max
        let reading = try Self.rollout(#"{"input_tokens":0,"cached_input_tokens":\#(max),"cache_write_input_tokens":\#(max),"output_tokens":1,"total_tokens":1}"#)
        #expect(reading.cells.isEmpty)
        #expect(reading.skipped == 1)
    }

    @Test("a negative token count is an unreadable line")
    func codexNegative() throws {
        let reading = try Self.rollout(#"{"input_tokens":-5,"output_tokens":1,"total_tokens":1}"#)
        #expect(reading.cells.isEmpty)
        #expect(reading.skipped == 1)
    }

    @Test("an ordinary rollout still counts the same")
    func codexOrdinary() throws {
        let reading = try Self.rollout(#"{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":100,"total_tokens":1100}"#)
        #expect(reading.skipped == 0)
        #expect(Array(reading.cells.values) == [TokenCounts(responses: 1, input: 600, output: 100, cacheRead: 400)])
    }

    // MARK: - Claude transcripts

    static func assistant(id: String, output: String) -> String {
        #"{"type":"assistant","requestId":"req-\#(id)","timestamp":"2026-09-20T10:00:00Z","message":{"id":"msg-\#(id)","model":"claude-test","usage":{"input_tokens":1,"output_tokens":\#(output)}}}"#
    }

    @Test("a transcript usage figure past the ceiling or below zero is an unreadable line")
    func claudeOutOfRange() {
        var seen: Set<String> = []
        let lines = [Self.assistant(id: "a", output: "\(Int.max)"), Self.assistant(id: "b", output: "-3"),
                     Self.assistant(id: "c", output: "7")]
        let reading = ClaudeCollector.read(data: Data(lines.joined(separator: "\n").utf8),
                                           primer: URL(fileURLWithPath: "/nowhere/primer"), seen: &seen)
        #expect(reading.skipped == 2)
        #expect(reading.responses.map(\.counts.output) == [7])
    }

    // MARK: - TokenCounts

    @Test("adding token counts saturates at the largest Int rather than trapping")
    func tokenSumSaturates() {
        let big = TokenCounts(responses: .max, input: .max, output: .max, thinking: .max,
                              cacheRead: .max, cacheWrite5m: .max, cacheWrite1h: .max)
        var sum = big
        sum += TokenCounts(responses: 1, input: 1, output: 1, thinking: 1, cacheRead: 1, cacheWrite5m: 1, cacheWrite1h: 1)
        #expect(sum == big)
        let low = TokenCounts(input: .min) - TokenCounts(input: 1)
        #expect(low.input == .min)
    }

    @Test("ordinary token sums are unchanged")
    func tokenSumOrdinary() {
        #expect(TokenCounts(input: 2, output: 3) + TokenCounts(input: 5, cacheRead: 7)
                == TokenCounts(input: 7, output: 3, cacheRead: 7))
        #expect(TokenCounts(input: 7, output: 3) - TokenCounts(input: 2) == TokenCounts(input: 5, output: 3))
    }

    // MARK: - Reset times

    @Test("a reset at 1e30 drops the window rather than reaching the countdown")
    func resetFarFuture() {
        let codex = #"{"id":2,"result":{"rateLimits":{"primary":{"windowDurationMins":300,"usedPercent":10,"resetsAt":1e30}}}}"#
        let claude = #"{"type":"control_response","response":{"request_id":"2","response":{"rate_limits_available":true,"rate_limits":{"limits":[{"kind":"session","percent":10,"resets_at":1e30}]}}}}"#
        if case let .live(windows, _) = CodexRateLimitsParser.windows(from: [codex]) {
            Issue.record("a reset at 1e30 was read as \(windows)")
        }
        if case let .live(windows, _) = ClaudeUsageParser.windows(from: [claude], requestID: "2") {
            Issue.record("a reset at 1e30 was read as \(windows)")
        }
    }

    @Test("a countdown to a saved reset far in the future, or a non-finite one, does not trap")
    func countdownSaturates() {
        _ = Countdown.text(until: Date(timeIntervalSince1970: 1e30), now: Self.now)
        _ = Countdown.text(until: Date(timeIntervalSince1970: .infinity), now: Self.now)
        _ = Countdown.text(until: Date(timeIntervalSince1970: .nan), now: Self.now)
        #expect(Countdown.text(until: Self.now.addingTimeInterval(90 * 60), now: Self.now) == "1:30")
    }

    @Test("a saved window with an absurd percent is clamped as it is read, so averaging cannot overflow")
    func combinedWindows() throws {
        let fair = Window(kind: .weekly, usedPercent: 50, resetsAt: Self.now, length: .seconds(604_800))
        let saved = String(decoding: try JSONEncoder().encode(fair), as: UTF8.self)
            .replacingOccurrences(of: #""usedPercent":50"#, with: #""usedPercent":9223372036854775807"#)
        let window = try JSONDecoder().decode(Window.self, from: Data(saved.utf8))
        #expect(window.usedPercent == 100)
        let combined = try #require(Window.combined([window, window]))
        #expect(combined.usedPercent == 100)
    }

    // MARK: - Intervals

    @Test("a poll interval or machine read interval past a day is held to a day")
    func intervalsBounded() throws {
        let text = #"{"seats":[],"pollMinutes":9223372036854775807,"machineSeconds":9223372036854775807}"#
        let config = try ConfigLoader.decode(Data(text.utf8))
        #expect(config.pollMinutes == Config.longestPollMinutes)
        #expect(config.machineSeconds == Config.longestMachineSeconds)
        #expect(Config(seats: [], pollMinutes: .max).pollMinutes == Config.longestPollMinutes)
        #expect(Config(seats: [], pollMinutes: .min).pollMinutes == 1)
    }

    @Test("ordinary intervals are unchanged")
    func intervalsOrdinary() throws {
        let config = try ConfigLoader.decode(Data(#"{"seats":[],"pollMinutes":7,"machineSeconds":9}"#.utf8))
        #expect(config.pollMinutes == 7)
        #expect(config.machineSeconds == 9)
    }
}

/// Sol's proofs from the review of ceab0a7 on PR 89.
@Suite struct SolPR89ProofTests {
    @Test("Sol proof, criterion 1: a finite idle percentage past 0 to 100 is no reading",
          arguments: ["cpu CPU usage: 0% user, " + String(repeating: "9", count: 100) + "% idle",
                      "cpu CPU usage: 0% user, 101.0% idle", "cpu CPU usage: 0% user, -20.0% idle"])
    func finiteIdle(_ line: String) {
        #expect(MachineProbe.parse(CheckedNumbersTests.probe("cpu", line), at: CheckedNumbersTests.now) == nil)
    }

    @Test("Sol proof, criterion 1: an idle figure that is not a plain number of its own is no reading",
          arguments: ["cpu CPU usage: 0% user, -1e1% idle", "cpu CPU usage: 0% user, 1e100% idle",
                      "cpu CPU usage: 0% user,x5.0% idle", "cpu 50.0% idle"])
    func scientificIdle(_ line: String) {
        #expect(MachineProbe.parse(CheckedNumbersTests.probe("cpu", line), at: CheckedNumbersTests.now) == nil)
    }

    @Test("Sol proof, criterion 1: a disk of under one block is no reading, so its percent cannot be infinite")
    func smallBlocks() {
        #expect(MachineProbe.parse(CheckedNumbersTests.probe("disk", "disk dev 1e-300 0 1000000000"),
                                   at: CheckedNumbersTests.now) == nil)
    }

    @Test("Sol proof, criterion 2: a count no Double holds makes the rollout line unreadable",
          arguments: ["1e400", "-1e400"])
    func codexHugeCount(_ count: String) throws {
        let reading = try CheckedNumbersTests.rollout(#"{"input_tokens":\#(count),"output_tokens":1,"total_tokens":1}"#)
        #expect(reading.cells.isEmpty)
        #expect(reading.skipped == 1)
    }

    @Test("Sol proof, criterion 2: a transcript count no Double holds makes the line unreadable")
    func claudeHugeCount() {
        var seen: Set<String> = []
        let line = CheckedNumbersTests.assistant(id: "huge", output: "1e400")
        let reading = ClaudeCollector.read(data: Data(line.utf8), primer: URL(fileURLWithPath: "/nowhere/primer"), seen: &seen)
        #expect(reading.responses.isEmpty)
        #expect(reading.skipped == 1)
    }

    @Test("Sol proof, criterion 6: a log.json row whose counts sum past Int.max totals without trapping")
    func savedLogTotal() throws {
        let row = #"{"input":9223372036854775807,"output":9223372036854775807,"responses":1,"thinking":0,"cacheRead":0,"cacheWrite5m":0,"cacheWrite1h":0}"#
        let tokens = try JSONDecoder().decode(TokenCounts.self, from: Data(row.utf8))
        #expect(tokens.total == .max)
    }
}
