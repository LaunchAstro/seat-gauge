import Foundation

/// One child process as a fetcher asks for it.
public struct ProcessSpec: Sendable, Equatable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let currentDirectory: URL?
    public let timeout: Duration

    public init(executable: URL, arguments: [String], environment: [String: String],
                currentDirectory: URL? = nil, timeout: Duration = .seconds(60)) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.timeout = timeout
    }
}

/// A process that would not start, or one that ran past its timeout. The
/// reason is shown in the panel's menu, so it is a sentence a person reads.
public struct ProcessFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var description: String { reason }

    /// The one wording both runners use, so a seat that ran long reads the
    /// same however it was driven.
    public static func timedOut(after timeout: Duration) -> ProcessFailure {
        let seconds = Int(timeout.seconds.rounded())
        return ProcessFailure(seconds >= 1 ? "the seat timed out after \(seconds) s"
                                           : "the seat timed out")
    }
}

/// A running child. `stdoutLines` finishes when the process does, and throws
/// `ProcessFailure` when the spec's timeout runs out first.
public protocol ProcessSession: Sendable {
    var stdoutLines: AsyncThrowingStream<String, Error> { get }
    func send(_ line: String) throws
    func closeInput()
    func terminate()
}

public protocol ProcessRunning: Sendable {
    func launch(_ spec: ProcessSpec) throws -> any ProcessSession
}

/// The runner that spawns the real CLI.
///
/// `SIGPIPE` is ignored, because a CLI that exits while a request is being
/// written would otherwise kill this process instead of the write. `PATH` is
/// extended from `SearchPath`, because an app launched at login has a bare
/// environment and neither `claude` nor `codex` sits in it. Only a runner
/// handed `SearchPath.loginShell` runs the user's profile.
public struct RealProcessRunner: ProcessRunning {
    let searchPath: SearchPath

    public init(searchPath: SearchPath = .installs) {
        self.searchPath = searchPath
        signal(SIGPIPE, SIG_IGN)
    }

    public func launch(_ spec: ProcessSpec) throws -> any ProcessSession {
        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.currentDirectoryURL = spec.currentDirectory
        var environment = spec.environment
        environment["PATH"] = searchPath.joined(after: environment["PATH"])
        process.environment = environment

        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // Discarded rather than piped: a pipe nobody reads fills and then
        // blocks the child on its next write.
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            throw ProcessFailure("\(spec.arguments.first ?? "the CLI") would not start: "
                                 + error.localizedDescription)
        }
        return LiveSession(process: process, input: input, output: output, timeout: spec.timeout)
    }
}

/// The lock is the whole of the concurrency story here: `readabilityHandler`
/// and `terminationHandler` run in an undefined context, so everything they
/// touch is behind it.
final class LiveSession: ProcessSession, @unchecked Sendable {
    private let process: Process
    private let input: Pipe
    private let lock = NSLock()
    private var rest = Data()
    private var finished = false
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    let stdoutLines: AsyncThrowingStream<String, Error>

    init(process: Process, input: Pipe, output: Pipe, timeout: Duration) {
        self.process = process
        self.input = input
        (stdoutLines, continuation) = AsyncThrowingStream.makeStream()

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.take(handle.availableData)
        }
        process.terminationHandler = { [weak self] _ in
            self?.finish(nil)
        }
        let deadline = DispatchTime.now() + max(0, timeout.seconds)
        DispatchQueue.global().asyncAfter(deadline: deadline) { [weak self] in
            guard let self, !self.isFinished else { return }
            self.terminate()
            self.finish(ProcessFailure.timedOut(after: timeout))
        }
    }

    private var isFinished: Bool { lock.withLock { finished } }

    /// Whole lines only. A read can land mid line, so the tail is kept.
    private func take(_ data: Data) {
        let lines: [String] = lock.withLock {
            guard !finished else { return [] }
            rest.append(data)
            var out: [String] = []
            while let at = rest.firstIndex(of: 0x0a) {
                out.append(String(decoding: rest[rest.startIndex..<at], as: UTF8.self))
                rest = rest[rest.index(after: at)...]
            }
            return out
        }
        for line in lines where !line.isEmpty { continuation.yield(line) }
    }

    private func finish(_ error: (any Error)?) {
        let already: Bool = lock.withLock {
            if finished { return true }
            finished = true
            return false
        }
        guard !already else { return }
        continuation.finish(throwing: error)
    }

    func send(_ line: String) throws {
        guard !isFinished else { throw ProcessFailure("the seat closed before the request was sent") }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func closeInput() { try? input.fileHandleForWriting.close() }

    /// Stdin first, so a CLI waiting on it leaves of its own accord, then
    /// SIGTERM, then SIGKILL once the grace has run out. The kill is guarded on
    /// `isRunning` so a recycled pid is never the one that gets it.
    func terminate() {
        closeInput()
        guard process.isRunning else { return }
        process.terminate()
        let process = self.process
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
