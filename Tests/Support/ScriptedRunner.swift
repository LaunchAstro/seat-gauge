import Foundation
import SeatGaugeCore

/// The runner the tests use: it answers each `send` with a batch of recorded
/// lines and spawns nothing, so `swift test` never reaches a real CLI.
///
/// It also records what it was asked to launch and what was written to it, so
/// a case can read the recipe itself rather than only its result.
public final class ScriptedRunner: ProcessRunning, @unchecked Sendable {
    private let replies: [[String]]
    private let endsWithScript: Bool
    private let launchFailure: String?
    private let lock = NSLock()
    private var log: (launched: [ProcessSpec], sent: [String], closedAfter: Int?) = ([], [], nil)

    /// `replies[i]` is what the seat says after the i-th `send`. A send past
    /// the end of the script is answered with silence, which is what a seat
    /// that has stopped talking looks like.
    /// `endsWithScript` is a CLI that exits once it has said its last line,
    /// which is what a seat looks like when it stops mid recipe.
    public init(replies: [[String]] = [], endsWithScript: Bool = false,
                launchFailure: String? = nil) {
        self.replies = replies
        self.endsWithScript = endsWithScript
        self.launchFailure = launchFailure
    }

    public var launched: [ProcessSpec] { lock.withLock { log.launched } }
    public var sent: [String] { lock.withLock { log.sent } }
    /// How many sends had happened when stdin was closed, or nil if it was not.
    public var closedInputAfter: Int? { lock.withLock { log.closedAfter } }

    public func launch(_ spec: ProcessSpec) throws -> any ProcessSession {
        if let launchFailure { throw ProcessFailure(launchFailure) }
        lock.withLock { log.launched.append(spec) }
        return ScriptedSession(runner: self, timeout: spec.timeout)
    }

    /// The batch this send is answered with, and whether the seat then exits.
    fileprivate func record(sent line: String) -> (lines: [String], last: Bool) {
        lock.withLock {
            log.sent.append(line)
            let at = log.sent.count - 1
            guard at < replies.count else { return ([], false) }
            return (replies[at], endsWithScript && at == replies.count - 1)
        }
    }

    fileprivate func recordClosedInput() {
        lock.withLock { if log.closedAfter == nil { log.closedAfter = log.sent.count } }
    }
}

private final class ScriptedSession: ProcessSession, @unchecked Sendable {
    private let runner: ScriptedRunner
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    let stdoutLines: AsyncThrowingStream<String, Error>

    init(runner: ScriptedRunner, timeout: Duration) {
        self.runner = runner
        (stdoutLines, continuation) = AsyncThrowingStream.makeStream()
        // The same deadline the real runner keeps, so a silent seat reads the
        // same way under test as it does on the machine.
        let continuation = self.continuation
        Task {
            try? await Task.sleep(for: timeout)
            continuation.finish(throwing: ProcessFailure.timedOut(after: timeout))
        }
    }

    func send(_ line: String) throws {
        let answer = runner.record(sent: line)
        for reply in answer.lines { continuation.yield(reply) }
        if answer.last { continuation.finish() }
    }

    func closeInput() { runner.recordClosedInput() }
    func terminate() { continuation.finish() }
}
