import Foundation
import Testing

import SeatGaugeCore

/// The Codex rollout parser: hourly cells from token counts, per session.
/// Every rollout is written by hand, in the shape the survey observed, with
/// made-up session ids.
@Suite struct CodexRolloutTests {

    // MARK: - Writing rollouts

    /// One usage figure, with only the fields a case names. An absent field is
    /// left out of the JSON, which is not the same as a zero.
    static func usage(input: Int? = nil, cached: Int? = nil, write: Int? = nil, output: Int? = nil,
                      reasoning: Int? = nil, total: Int? = nil) -> [String: Int] {
        var out: [String: Int] = [:]
        out["input_tokens"] = input
        out["cached_input_tokens"] = cached
        out["cache_write_input_tokens"] = write
        out["output_tokens"] = output
        out["reasoning_output_tokens"] = reasoning
        out["total_tokens"] = total
        return out
    }

    static func line(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func meta(_ id: String, at: String, parent: String? = nil, forkedFrom: String? = nil) -> String {
        var payload: [String: Any] = ["id": id, "session_id": id, "timestamp": at,
                                      "cwd": "/work/project", "originator": "codex_cli"]
        payload["source"] = parent.map { ["subagent": ["thread_spawn": ["parent_thread_id": $0]]] } ?? "cli"
        payload["forked_from_id"] = forkedFrom
        return line(["timestamp": at, "type": "session_meta", "payload": payload])
    }

    static func context(_ model: String, at: String) -> String {
        line(["timestamp": at, "type": "turn_context",
              "payload": ["model": model, "cwd": "/work/project", "turn_id": "turn"]])
    }

    /// A `token_count` event. With neither figure, `info` is null, which is the
    /// shape a token event with no usage has.
    static func tokens(at: String?, total: [String: Int]? = nil, last: [String: Int]? = nil) -> String {
        var info: [String: Any] = ["model_context_window": 258_400]
        info["total_token_usage"] = total
        info["last_token_usage"] = last
        var payload: [String: Any] = ["type": "token_count", "rate_limits": [:] as [String: Any]]
        payload["info"] = (total == nil && last == nil) ? NSNull() : info
        var object: [String: Any] = ["type": "event_msg", "payload": payload]
        object["timestamp"] = at
        return line(object)
    }

    /// A scratch directory of rollout files, removed when the case is done.
    final class Scratch {
        let directory: URL

        init() throws {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("seat-gauge-codex-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        @discardableResult
        func file(_ name: String, _ lines: [String]) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
            return url
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    static var utc: Calendar { calendar("UTC") }

    static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    /// Every cell of one model, added up, for a case that asserts a session's
    /// whole contribution rather than its hours.
    static func sum(_ reading: CodexReading, model: String) -> TokenCounts {
        reading.cells.filter { $0.key.model == model }.values.reduce(TokenCounts(), +)
    }

    // MARK: - Cases

    @Test func cellsAreHourlyAndLocalUnderCodex() throws {
        let scratch = try Scratch()
        let file = try scratch.file("rollout-one.jsonl", [
            Self.meta("session-one", at: "2026-09-20T10:00:00.000Z"),
            Self.context("gpt-6-sol", at: "2026-09-20T10:00:01.000Z"),
            Self.tokens(at: "2026-09-20T10:15:00.000Z", total: Self.usage(input: 1000, output: 100, total: 1100),
                        last: Self.usage(input: 1000, output: 100, total: 1100)),
            Self.tokens(at: "2026-09-20T11:05:00.000Z", total: Self.usage(input: 1500, output: 200, total: 1700),
                        last: Self.usage(input: 500, output: 100, total: 600)),
        ])
        let reading = CodexRollout.read(files: [file], calendar: Self.calendar("Etc/GMT-10"))
        let first = SpendCell(seat: "codex", day: "2026-09-20", hour: "20", model: "gpt-6-sol")
        let second = SpendCell(seat: "codex", day: "2026-09-20", hour: "21", model: "gpt-6-sol")
        #expect(Set(reading.cells.keys) == [first, second])
        #expect(reading.cells[first] == TokenCounts(responses: 1, input: 1000, output: 100))
        #expect(reading.cells[second] == TokenCounts(responses: 1, input: 500, output: 100))
        #expect(reading.rows.map(\.cell) == [first, second])
        #expect(reading.rows.allSatisfy { $0.usd == nil && !$0.sealed && $0.seat == "codex" })
    }

    @Test func modelComesFromTheLatestTurnContext() throws {
        let scratch = try Scratch()
        let file = try scratch.file("rollout-models.jsonl", [
            Self.meta("session-models", at: "2026-09-20T10:00:00Z"),
            Self.tokens(at: "2026-09-20T10:01:00Z", total: Self.usage(input: 100, output: 10, total: 110),
                        last: Self.usage(input: 100, output: 10, total: 110)),
            Self.context("model-a", at: "2026-09-20T10:02:00Z"),
            Self.tokens(at: "2026-09-20T10:03:00Z", total: Self.usage(input: 300, output: 30, total: 330),
                        last: Self.usage(input: 200, output: 20, total: 220)),
            Self.context("model-b", at: "2026-09-20T10:04:00Z"),
            Self.tokens(at: "2026-09-20T10:05:00Z", total: Self.usage(input: 700, output: 70, total: 770),
                        last: Self.usage(input: 400, output: 40, total: 440)),
        ])
        let reading = CodexRollout.read(files: [file], calendar: Self.utc)
        #expect(Set(reading.cells.keys.map(\.model)) == ["unknown", "model-a", "model-b"])
        #expect(Self.sum(reading, model: "unknown") == TokenCounts(responses: 1, input: 100, output: 10))
        #expect(Self.sum(reading, model: "model-a") == TokenCounts(responses: 1, input: 200, output: 20))
        #expect(Self.sum(reading, model: "model-b") == TokenCounts(responses: 1, input: 400, output: 40))
    }

    @Test func firstEventContributesItsLastUsageElseItsTotal() throws {
        let scratch = try Scratch()
        let withLast = try scratch.file("rollout-with-last.jsonl", [
            Self.meta("session-with-last", at: "2026-09-20T10:00:00Z"),
            Self.context("model-last", at: "2026-09-20T10:00:01Z"),
            Self.tokens(at: "2026-09-20T10:01:00Z",
                        total: Self.usage(input: 5000, cached: 1000, output: 600, reasoning: 100, total: 5600),
                        last: Self.usage(input: 800, cached: 200, output: 90, reasoning: 10, total: 890)),
        ])
        let without = try scratch.file("rollout-without-last.jsonl", [
            Self.meta("session-without-last", at: "2026-09-20T10:00:00Z"),
            Self.context("model-total", at: "2026-09-20T10:00:01Z"),
            Self.tokens(at: "2026-09-20T10:01:00Z", total: Self.usage(input: 300, output: 30, total: 330)),
        ])
        let reading = CodexRollout.read(files: [withLast, without], calendar: Self.utc)
        #expect(Self.sum(reading, model: "model-last")
            == TokenCounts(responses: 1, input: 600, output: 90, thinking: 10, cacheRead: 200))
        #expect(Self.sum(reading, model: "model-total") == TokenCounts(responses: 1, input: 300, output: 30))
    }

    @Test func laterEventsContributeDifferencesAndRepeatsNothing() throws {
        let scratch = try Scratch()
        let first = Self.usage(input: 100, output: 10, total: 110)
        let later = Self.usage(input: 250, output: 40, total: 290)
        let file = try scratch.file("rollout-deltas.jsonl", [
            Self.meta("session-deltas", at: "2026-09-20T10:00:00Z"),
            Self.context("model-d", at: "2026-09-20T10:00:01Z"),
            Self.tokens(at: "2026-09-20T10:01:00Z", total: first, last: first),
            Self.tokens(at: "2026-09-20T10:02:00Z", total: first, last: first),
            Self.tokens(at: "2026-09-20T10:03:00Z", total: later, last: Self.usage(input: 150, output: 30, total: 180)),
            Self.tokens(at: "2026-09-20T10:04:00Z", total: later, last: Self.usage(input: 150, output: 30, total: 180)),
        ])
        let reading = CodexRollout.read(files: [file], calendar: Self.utc)
        #expect(Self.sum(reading, model: "model-d") == TokenCounts(responses: 2, input: 250, output: 40))
    }

    @Test func resetContributesItsLastUsageAndBecomesTheBaseline() throws {
        let scratch = try Scratch()
        let byTotal = try scratch.file("rollout-reset-total.jsonl", [
            Self.meta("session-reset-total", at: "2026-09-20T10:00:00Z"),
            Self.context("model-reset", at: "2026-09-20T10:00:01Z"),
            Self.tokens(at: "2026-09-20T10:01:00Z", total: Self.usage(input: 1000, output: 100, total: 1100),
                        last: Self.usage(input: 1000, output: 100, total: 1100)),
            Self.tokens(at: "2026-09-20T10:02:00Z", total: Self.usage(input: 1500, output: 150, total: 1650),
                        last: Self.usage(input: 500, output: 50, total: 550)),
            // Falls: a reset with a per-event figure, which is what it adds.
            Self.tokens(at: "2026-09-20T10:03:00Z", total: Self.usage(input: 200, output: 20, total: 220),
                        last: Self.usage(input: 120, output: 12, total: 132)),
            // Measured from the reset's total, not from the one before it.
            Self.tokens(at: "2026-09-20T10:04:00Z", total: Self.usage(input: 260, output: 30, total: 290),
                        last: Self.usage(input: 60, output: 10, total: 70)),
            // Falls again, with no per-event figure: its own total is added.
            Self.tokens(at: "2026-09-20T10:05:00Z", total: Self.usage(input: 50, output: 5, total: 55)),
        ])
        let bySum = try scratch.file("rollout-reset-sum.jsonl", [
            Self.meta("session-reset-sum", at: "2026-09-20T10:00:00Z"),
            Self.context("model-sum", at: "2026-09-20T10:00:01Z"),
            Self.tokens(at: "2026-09-20T10:01:00Z", total: Self.usage(input: 400, output: 40)),
            Self.tokens(at: "2026-09-20T10:02:00Z", total: Self.usage(input: 100, output: 10)),
            Self.tokens(at: "2026-09-20T10:03:00Z", total: Self.usage(input: 150, output: 10)),
        ])
        let reading = CodexRollout.read(files: [byTotal, bySum], calendar: Self.utc)
        #expect(Self.sum(reading, model: "model-reset") == TokenCounts(responses: 5, input: 1730, output: 177))
        #expect(Self.sum(reading, model: "model-sum") == TokenCounts(responses: 3, input: 550, output: 50))
    }

    @Test func missingUsageIsSkippedAndAbsentFieldsAddNothing() throws {
        let scratch = try Scratch()
        let file = try scratch.file("rollout-absent.jsonl", [
            Self.meta("session-absent", at: "2026-09-20T10:00:00Z"),
            Self.context("model-absent", at: "2026-09-20T10:00:01Z"),
            Self.tokens(at: "2026-09-20T10:01:00Z", total: Self.usage(input: 100, cached: 20, output: 10, total: 110),
                        last: Self.usage(input: 100, cached: 20, output: 10, total: 110)),
            Self.tokens(at: "2026-09-20T10:02:00Z"),
            // Cached input is absent here: it adds nothing, and is not a fall to zero.
            Self.tokens(at: "2026-09-20T10:03:00Z", total: Self.usage(input: 300, output: 30, total: 330)),
            // So cached input is measured against the last total that carried it.
            Self.tokens(at: "2026-09-20T10:04:00Z", total: Self.usage(input: 400, cached: 50, output: 40, total: 440)),
            // Input and the total are absent: the fields both carry still rise, so no reset.
            Self.tokens(at: "2026-09-20T10:05:00Z", total: Self.usage(cached: 50, output: 45)),
        ])
        let reading = CodexRollout.read(files: [file], calendar: Self.utc)
        #expect(Self.sum(reading, model: "model-absent")
            == TokenCounts(responses: 4, input: 350, output: 45, cacheRead: 50))
    }

    @Test func columnsFollowTheSpecArithmetic() throws {
        let scratch = try Scratch()
        let file = try scratch.file("rollout-columns.jsonl", [
            Self.meta("session-columns", at: "2026-09-20T10:00:00Z"),
            Self.context("model-c", at: "2026-09-20T10:00:01Z"),
            Self.tokens(at: "2026-09-20T10:01:00Z",
                        total: Self.usage(input: 1000, cached: 300, write: 200, output: 400, reasoning: 150, total: 1400),
                        last: Self.usage(input: 1000, cached: 300, write: 200, output: 400, reasoning: 150, total: 1400)),
            // More cached than input in one step: fresh input stops at zero.
            Self.tokens(at: "2026-09-20T10:02:00Z",
                        total: Self.usage(input: 1100, cached: 500, write: 200, output: 450, reasoning: 150, total: 1550),
                        last: Self.usage(input: 100, cached: 200, output: 50, total: 150)),
        ])
        let reading = CodexRollout.read(files: [file], calendar: Self.utc)
        #expect(Self.sum(reading, model: "model-c") == TokenCounts(
            responses: 2, input: 500, output: 450, thinking: 150, cacheRead: 500, cacheWrite5m: 200, cacheWrite1h: 0))
    }

    @Test func resumedSessionContinuesItsBaseline() throws {
        let scratch = try Scratch()
        let opened = Self.usage(input: 1000, output: 100, total: 1100)
        // Named to sort first, but it starts later, so it is read second.
        let later = try scratch.file("rollout-a.jsonl", [
            Self.meta("session-resumed", at: "2026-09-20T12:00:00Z"),
            Self.context("model-r", at: "2026-09-20T12:00:01Z"),
            Self.tokens(at: "2026-09-20T12:01:00Z", total: opened, last: opened),
            Self.tokens(at: "2026-09-20T12:02:00Z", total: Self.usage(input: 1600, output: 160, total: 1760),
                        last: Self.usage(input: 600, output: 60, total: 660)),
        ])
        let earlier = try scratch.file("rollout-b.jsonl", [
            Self.meta("session-resumed", at: "2026-09-20T10:00:00Z"),
            Self.context("model-r", at: "2026-09-20T10:00:01Z"),
            Self.tokens(at: "2026-09-20T10:01:00Z", total: opened, last: opened),
        ])
        let reading = CodexRollout.read(files: [later, earlier], calendar: Self.utc)
        let ten = SpendCell(seat: "codex", day: "2026-09-20", hour: "10", model: "model-r")
        let noon = SpendCell(seat: "codex", day: "2026-09-20", hour: "12", model: "model-r")
        #expect(reading.cells[ten] == TokenCounts(responses: 1, input: 1000, output: 100))
        #expect(reading.cells[noon] == TokenCounts(responses: 1, input: 600, output: 60))

        // A resume can open with the session's original meta line, so the
        // first line's time says nothing about order: the first token event's
        // does. Read by first line, the resumed total would count whole as a
        // first event, and the earlier one would then read as a reset and be
        // counted again.
        let resumed = try scratch.file("rollout-c.jsonl", [
            Self.meta("session-reopened", at: "2026-09-21T09:00:00Z"),
            Self.context("model-s", at: "2026-09-21T13:00:00Z"),
            Self.tokens(at: "2026-09-21T13:01:00Z", total: Self.usage(input: 1600, output: 160, total: 1760)),
        ])
        let first = try scratch.file("rollout-d.jsonl", [
            Self.meta("session-reopened", at: "2026-09-21T10:00:00Z"),
            Self.context("model-s", at: "2026-09-21T10:00:01Z"),
            Self.tokens(at: "2026-09-21T10:01:00Z", total: opened, last: opened),
        ])
        let quiet = try scratch.file("rollout-0.jsonl", [
            Self.meta("session-reopened", at: "2026-09-21T08:00:00Z"),
            Self.context("model-s", at: "2026-09-21T08:00:01Z"),
        ])
        for files in [[resumed, first, quiet], [quiet, first, resumed]] {
            let reopened = CodexRollout.read(files: files, calendar: Self.utc)
            #expect(Self.sum(reopened, model: "model-s") == TokenCounts(responses: 2, input: 1600, output: 160))
        }

        // A token event with no usage is still the file's first token event.
        // Here it puts the file whose usage comes later first; ordered by its
        // first usage instead, the smaller total would read as a reset and be
        // counted again.
        let early = try scratch.file("rollout-e.jsonl", [
            Self.meta("session-usage-less", at: "2026-09-22T09:00:00Z"),
            Self.context("model-u", at: "2026-09-22T09:00:01Z"),
            Self.tokens(at: "2026-09-22T09:30:00Z"),
            Self.tokens(at: "2026-09-22T11:00:00Z", total: opened),
        ])
        let late = try scratch.file("rollout-f.jsonl", [
            Self.meta("session-usage-less", at: "2026-09-22T10:00:00Z"),
            Self.context("model-u", at: "2026-09-22T10:00:01Z"),
            Self.tokens(at: "2026-09-22T10:01:00Z", total: Self.usage(input: 1600, output: 160, total: 1760)),
        ])
        for files in [[early, late], [late, early]] {
            let read = CodexRollout.read(files: files, calendar: Self.utc)
            #expect(Self.sum(read, model: "model-u") == TokenCounts(responses: 2, input: 1600, output: 160))
        }
    }

    @Test func subagentIsItsOwnSessionAndItsForkBaselineIsNotRecounted() throws {
        let scratch = try Scratch()
        let parent = try scratch.file("rollout-parent.jsonl", [
            Self.meta("session-parent", at: "2026-09-20T10:00:00Z"),
            Self.context("model-parent", at: "2026-09-20T10:00:01Z"),
            Self.tokens(at: "2026-09-20T10:01:00Z", total: Self.usage(input: 2000, output: 200, total: 2200),
                        last: Self.usage(input: 2000, output: 200, total: 2200)),
        ])
        let child = try scratch.file("rollout-child.jsonl", [
            Self.meta("session-child", at: "2026-09-20T10:02:00Z", parent: "session-parent",
                      forkedFrom: "session-parent"),
            // The fork's copy of its parent's meta, after its own.
            Self.meta("session-parent", at: "2026-09-20T10:00:00Z"),
            Self.context("model-child", at: "2026-09-20T10:02:01Z"),
            // 1,800 in and 180 out are inherited from the fork; only the last figure is its own.
            Self.tokens(at: "2026-09-20T10:03:00Z", total: Self.usage(input: 2100, output: 210, total: 2310),
                        last: Self.usage(input: 300, output: 30, total: 330)),
            Self.tokens(at: "2026-09-20T10:04:00Z", total: Self.usage(input: 2300, output: 230, total: 2530),
                        last: Self.usage(input: 200, output: 20, total: 220)),
        ])
        let reading = CodexRollout.read(files: [parent, child], calendar: Self.utc)
        #expect(Self.sum(reading, model: "model-parent") == TokenCounts(responses: 1, input: 2000, output: 200))
        #expect(Self.sum(reading, model: "model-child") == TokenCounts(responses: 2, input: 500, output: 50))
    }

    @Test func secondReadIsByteIdentical() throws {
        let scratch = try Scratch()
        var files: [URL] = []
        for (index, model) in ["model-x", "model-y", "model-z"].enumerated() {
            files.append(try scratch.file("rollout-\(index).jsonl", [
                Self.meta("session-\(index)", at: "2026-09-2\(index)T10:00:00Z"),
                Self.context(model, at: "2026-09-2\(index)T10:00:01Z"),
                Self.tokens(at: "2026-09-2\(index)T10:01:00Z", total: Self.usage(input: 100, output: 10, total: 110),
                            last: Self.usage(input: 100, output: 10, total: 110)),
                Self.context("model-w", at: "2026-09-2\(index)T11:00:00Z"),
                Self.tokens(at: "2026-09-2\(index)T11:01:00Z", total: Self.usage(input: 300, output: 30, total: 330),
                            last: Self.usage(input: 200, output: 20, total: 220)),
            ]))
        }
        let once = SpendCSV.text(CodexRollout.read(files: files, calendar: Self.utc).rows)
        let again = SpendCSV.text(CodexRollout.read(files: files, calendar: Self.utc).rows)
        let reversed = SpendCSV.text(CodexRollout.read(files: files.reversed(), calendar: Self.utc).rows)
        #expect(once.split(separator: "\n").count == 7)
        #expect(Data(once.utf8) == Data(again.utf8))
        #expect(Data(once.utf8) == Data(reversed.utf8))
    }

    @Test func failsClosedOnUnreadableInput() throws {
        let scratch = try Scratch()
        let damaged = try scratch.file("rollout-damaged.jsonl", [
            Self.meta("session-damaged", at: "2026-09-20T10:00:00Z"),
            Self.context("model-f", at: "2026-09-20T10:00:01Z"),
            Self.tokens(at: "2026-09-20T10:01:00Z", total: Self.usage(input: 100, output: 10, total: 110),
                        last: Self.usage(input: 100, output: 10, total: 110)),
            #"{"timestamp":"2026-09-20T10:02:00Z","type":"event_msg","payload":{"type":"tok"#,
            // No readable time: skipped, and its tokens land with the next dated event.
            Self.tokens(at: "not a time", total: Self.usage(input: 200, output: 20, total: 220),
                        last: Self.usage(input: 100, output: 10, total: 110)),
            Self.tokens(at: "2026-09-20T10:03:00Z", total: Self.usage(input: 300, output: 30, total: 330),
                        last: Self.usage(input: 100, output: 10, total: 110)),
        ])
        let unkeyed = try scratch.file("rollout-unkeyed.jsonl", [
            Self.context("model-g", at: "2026-09-20T10:00:01Z"),
            Self.tokens(at: "2026-09-20T10:01:00Z", total: Self.usage(input: 900, output: 90, total: 990),
                        last: Self.usage(input: 900, output: 90, total: 990)),
        ])
        let missing = scratch.directory.appendingPathComponent("rollout-gone.jsonl")
        let reading = CodexRollout.read(files: [damaged, unkeyed, missing], calendar: Self.utc)
        #expect(Self.sum(reading, model: "model-f") == TokenCounts(responses: 2, input: 300, output: 30))
        #expect(Self.sum(reading, model: "model-g") == TokenCounts())
        #expect(reading.skipped == 2)
        #expect(reading.unkeyed == 1)
    }
}
