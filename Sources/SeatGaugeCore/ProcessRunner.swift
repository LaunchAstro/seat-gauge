import Foundation

/// One child process as a fetcher asks for it.
public struct ProcessSpec: Sendable, Equatable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let currentDirectory: URL?
    public let timeout: Duration
    /// The most standard output a child may print, in bytes, before it is
    /// stopped. Its lines are kept until the reader takes them, and a child,
    /// a local CLI or a machine at the far end of ssh, can print without end
    /// well inside its timeout.
    public let outputLimit: Int

    /// 16 MB by default. The largest protocol is the Log probe's reply, which
    /// `log.json`'s own cap holds near 3 MB; a seat's reply and a machine's
    /// load read are kilobytes.
    public static let outputLimit = 16 << 20

    public init(executable: URL, arguments: [String], environment: [String: String],
                currentDirectory: URL? = nil, timeout: Duration = .seconds(60), outputLimit: Int = Self.outputLimit) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.timeout = timeout
        self.outputLimit = outputLimit
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
        return LiveSession(process: process, input: input, output: output, timeout: spec.timeout,
                           limit: spec.outputLimit)
    }
}

/// `readabilityHandler` and `terminationHandler` run in an undefined context,
/// so everything they touch is behind the lock, and nothing else here guards
/// shared state.
final class LiveSession: ProcessSession, @unchecked Sendable {
    private let process: Process
    private let input: Pipe
    private let lock = NSLock()
    private let outputLock = NSLock()
    private var rest = Data()
    private var printed = 0
    private let limit: Int
    private var finished = false
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    let stdoutLines: AsyncThrowingStream<String, Error>

    init(process: Process, input: Pipe, output: Pipe, timeout: Duration, limit: Int) {
        self.process = process
        self.input = input
        self.limit = limit
        (stdoutLines, continuation) = AsyncThrowingStream.makeStream()

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            self.outputLock.withLock { self.take(handle.availableData) }
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            output.fileHandleForReading.readabilityHandler = nil
            self.outputLock.withLock {
                // No more than the limit leaves, so a child that left the
                // pipe to a writer of its own cannot grow this read either.
                let left = (try? output.fileHandleForReading.read(upToCount: limit + 1)) ?? nil
                self.take(left ?? Data())
                self.finish(nil)
            }
        }
        let deadline = DispatchTime.now() + max(0, timeout.seconds)
        DispatchQueue.global().asyncAfter(deadline: deadline) { [weak self] in
            guard let self, !self.isFinished else { return }
            self.terminate()
            self.finish(ProcessFailure.timedOut(after: timeout))
        }
    }

    private var isFinished: Bool { lock.withLock { finished } }

    /// Whole lines only. A read can land mid line, so the tail is kept. Past
    /// the limit the child is stopped and the read fails, whether the bytes
    /// came as lines or as one line that never ends.
    private func take(_ data: Data) {
        let over: Bool = lock.withLock {
            guard !finished else { return false }
            printed += data.count
            return printed > limit
        }
        if over {
            terminate()
            lock.withLock { rest = Data() }
            let megabytes = max(1, limit >> 20)
            finish(ProcessFailure("the reply ran past \(megabytes) MB, so it was stopped"))
            return
        }
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
