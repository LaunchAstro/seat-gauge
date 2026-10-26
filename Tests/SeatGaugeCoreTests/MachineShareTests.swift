import Foundation
import Testing

import SeatGaugeCore
import SeatGaugeTestSupport

/// The copy of `machines.json` each other listed machine gets, so an agent
/// there reads the same file at the same path.
@Suite struct MachineShareTests {
    static let file = Data(#"{ "machines" : [ { "id" : "studio", "label" : "Studio's \"$(x)\" `y`" } ], "updated" : "now" }"#.utf8)
    static let studio = Machine(id: "studio", label: "Studio", ssh: "studio.local")

    /// Runs the copy script in a real `/bin/sh -s` with `home` as its home,
    /// the way ssh runs it at the far end, and returns what it printed.
    static func run(_ data: Data, home: URL, identifier: String = AppPaths.bundleID,
                    cut: Int = 0) async throws -> [String] {
        let session = try RealProcessRunner().launch(ProcessSpec(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-s"],
            environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"], timeout: .seconds(10)))
        for line in MachineShare.script(data, identifier: identifier).dropLast(cut) { try session.send(line) }
        session.closeInput()
        var printed: [String] = []
        for try await line in session.stdoutLines { printed.append(line) }
        return printed
    }

    static func scratch() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    static func mode(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
    }

    @Test("the script writes the exact bytes to Seat Gauge's folder there, readable by its owner alone")
    func writes() async throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try await Self.run(Self.file, home: home) == ["copied"])
        let folder = home.appendingPathComponent("Library/Application Support/com.launchastro.seatgauge")
        let copy = folder.appendingPathComponent("machines.json")
        #expect(try Data(contentsOf: copy) == Self.file)
        #expect(try Self.mode(copy) == 0o600)
        #expect(try Self.mode(folder) == 0o700)
        // Nothing else is left in the folder: no temporary file.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["machines.json"])

        // A second copy replaces the first whole.
        let newer = Data(#"{ "machines" : [], "updated" : "later" }"#.utf8)
        #expect(try await Self.run(newer, home: home) == ["copied"])
        #expect(try Data(contentsOf: copy) == newer)
    }

    @Test("a machine with its own seats.json runs its own app, so its own file is never overwritten")
    func keepsOwn() async throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent("Library/Application Support/com.launchastro.seatgauge")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("seats.json"))
        try Data("its own".utf8).write(to: folder.appendingPathComponent("machines.json"))
        #expect(try await Self.run(Self.file, home: home) == ["kept"])
        #expect(try String(contentsOf: folder.appendingPathComponent("machines.json"), encoding: .utf8) == "its own")
    }

    @Test("a link where the copy goes is replaced, never written through")
    func link() async throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent("Library/Application Support/com.launchastro.seatgauge")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let elsewhere = home.appendingPathComponent("elsewhere.txt")
        try Data("untouched".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("machines.json"),
                                                   withDestinationURL: elsewhere)
        #expect(try await Self.run(Self.file, home: home) == ["copied"])
        #expect(try String(contentsOf: elsewhere, encoding: .utf8) == "untouched")
        #expect(try Data(contentsOf: folder.appendingPathComponent("machines.json")) == Self.file)

        // A link to a folder: the link is replaced, and nothing lands inside.
        let elsewhereFolder = home.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhereFolder, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("machines.json"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("machines.json"),
                                                   withDestinationURL: elsewhereFolder)
        #expect(try await Self.run(Self.file, home: home) == ["copied"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhereFolder.path) == [])
        let kind = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("machines.json").path)[.type]
        #expect(kind as? FileAttributeType == .typeRegular)
        #expect(try Data(contentsOf: folder.appendingPathComponent("machines.json")) == Self.file)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["machines.json"])
    }

    @Test("a folder where the copy goes is left alone, and nothing lands inside it")
    func folderInTheWay() async throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let target = home.appendingPathComponent("Library/Application Support/com.launchastro.seatgauge/machines.json")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        #expect(try await Self.run(Self.file, home: home) == [])
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == [])
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path) == ["machines.json"])
    }

    @Test("the dev build copies into its own folder there; an identifier that is not ours copies into the app's")
    func identifier() async throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try await Self.run(Self.file, home: home, identifier: AppPaths.bundleID + ".dev") == ["copied"])
        let support = home.appendingPathComponent("Library/Application Support")
        #expect(FileManager.default.fileExists(atPath: support.appendingPathComponent("com.launchastro.seatgauge.dev/machines.json").path))
        #expect(try await Self.run(Self.file, home: home, identifier: "x\"; touch \"$HOME/owned") == ["copied"])
        #expect(try await Self.run(Self.file, home: home,
                                   identifier: AppPaths.bundleID + ".dev\"; touch \"$HOME/owned") == ["copied"])
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("owned").path))
        #expect(FileManager.default.fileExists(atPath: support.appendingPathComponent("com.launchastro.seatgauge/machines.json").path))
    }

    @Test("a copy cut off on the way runs nothing there and leaves no file behind")
    func cutOff() async throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent("Library/Application Support/com.launchastro.seatgauge")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("before".utf8).write(to: folder.appendingPathComponent("machines.json"))
        for cut in [1, 2, 4] { #expect(try await Self.run(Self.file, home: home, cut: cut) == []) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["machines.json"])
        #expect(try String(contentsOf: folder.appendingPathComponent("machines.json"), encoding: .utf8) == "before")
    }

    @Test("the copy rides the probe's kept-open ssh connection and runs only sh there")
    func spec() {
        let spec = MachineShare.spec(Self.studio, environment: [:])
        let probe = MachineProber.spec(Self.studio, environment: [:])
        #expect(spec.executable.path == "/usr/bin/ssh")
        #expect(spec.arguments == probe.arguments)
        #expect(spec.timeout <= .seconds(10))
    }

    @Test("each reachable machine over ssh gets a copy at most once a minute; this Mac and a silent machine get none")
    func monitor() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("machines-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let silent = Machine(id: "gone", label: "Gone", ssh: "gone.local")
        let config = Config(seats: [], pollMinutes: 5, machines: [.here, Self.studio, silent])
        let runner = HostRunner(answering: ["": MachineLoadTests.printed, "studio.local": MachineLoadTests.printed])
        let clock = ShareClock(MachineLoadTests.now)
        let monitor = MachineMonitor(prober: MachineProber(runner: runner, environment: [:]), file: file,
                                     share: MachineShare(runner: runner, environment: [:]),
                                     now: { clock.now }, config: { config })
        await monitor.read()
        await monitor.settle()
        #expect(runner.copies == ["studio.local"])
        let copied = try #require(runner.copied.first)
        #expect(copied == (try Data(contentsOf: file)))

        clock.now = MachineLoadTests.now.addingTimeInterval(30)
        await monitor.read()
        await monitor.settle()
        #expect(runner.copies == ["studio.local"])

        clock.now = MachineLoadTests.now.addingTimeInterval(61)
        await monitor.read()
        await monitor.settle()
        #expect(runner.copies == ["studio.local", "studio.local"])
    }

    @Test("a copy that stalls never holds up the read")
    func stalled() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("machines-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let runner = HostRunner(answering: ["studio.local": MachineLoadTests.printed], stalling: true)
        let config = Config(seats: [], pollMinutes: 5, machines: [Self.studio])
        let monitor = MachineMonitor(prober: MachineProber(runner: runner, environment: [:]), file: file,
                                     share: MachineShare(runner: runner, environment: [:]), config: { config })
        let done = ShareClock(.distantPast)
        let reading = Task {
            _ = await monitor.read()
            done.now = .distantFuture
        }
        // Five seconds at most, then the copy is let go either way, so a
        // read that waits on it fails here rather than hanging the run.
        for _ in 0 ..< 500 where done.now != .distantFuture || runner.copies.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(done.now == .distantFuture)
        #expect(runner.copies == ["studio.local"])

        // The next read, with that copy still held open, comes back too.
        let again = ShareClock(.distantPast)
        let next = Task {
            _ = await monitor.read()
            again.now = .distantFuture
        }
        for _ in 0 ..< 500 where again.now != .distantFuture { try await Task.sleep(for: .milliseconds(10)) }
        #expect(again.now == .distantFuture)
        #expect(runner.probes == ["studio.local", "studio.local"])
        runner.release()
        await reading.value
        await next.value
    }

    @Test("a monitor with no share, as the CLI's one-off read makes, copies nothing")
    func noShare() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("machines-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let runner = HostRunner(answering: ["studio.local": MachineLoadTests.printed])
        let config = Config(seats: [], pollMinutes: 5, machines: [Self.studio])
        await MachineMonitor(prober: MachineProber(runner: runner, environment: [:]), file: file,
                             config: { config }).read()
        #expect(runner.copies == [])
        #expect(runner.probes == ["studio.local"])
    }
}

final class ShareClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Answers each launch by its ssh host ("" for this Mac's `sh`): the probe
/// with that host's lines, a copy with `copied`. A host with no lines is
/// silent, as an unreachable machine is. `stalling` copies never answer
/// until `release`.
final class HostRunner: ProcessRunning, @unchecked Sendable {
    private let answering: [String: [String]]
    let stalling: Bool
    private let lock = NSLock()
    private var log: (probes: [String], copies: [String], copied: [Data]) = ([], [], [])
    private var held: [AsyncThrowingStream<String, Error>.Continuation] = []

    init(answering: [String: [String]], stalling: Bool = false) {
        self.answering = answering
        self.stalling = stalling
    }

    func hold(_ continuation: AsyncThrowingStream<String, Error>.Continuation) {
        lock.withLock { held.append(continuation) }
    }

    func release() { for continuation in lock.withLock({ held }) { continuation.finish() } }

    var probes: [String] { lock.withLock { log.probes } }
    var copies: [String] { lock.withLock { log.copies } }
    var copied: [Data] { lock.withLock { log.copied } }

    func launch(_ spec: ProcessSpec) throws -> any ProcessSession {
        let host = spec.executable.path == "/usr/bin/ssh"
            ? spec.arguments[spec.arguments.firstIndex(of: "--")! + 1] : ""
        return HostSession(runner: self, host: host)
    }

    fileprivate func finished(host: String, sent: [String]) -> [String] {
        lock.withLock {
            if sent == MachineProbe.script {
                log.probes.append(host)
                return answering[host] ?? []
            }
            log.copies.append(host)
            let start = sent.firstIndex { $0.hasSuffix("<<'\(MachineShare.marker)'") }.map { $0 + 1 } ?? sent.endIndex
            let end = sent[start...].firstIndex(of: MachineShare.marker) ?? sent.endIndex
            log.copied.append(Data(base64Encoded: sent[start ..< end].joined()) ?? Data())
            return answering[host] == nil ? [] : ["copied"]
        }
    }
}

private final class HostSession: ProcessSession, @unchecked Sendable {
    private let runner: HostRunner
    private let host: String
    private let lock = NSLock()
    private var sent: [String] = []
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    let stdoutLines: AsyncThrowingStream<String, Error>

    init(runner: HostRunner, host: String) {
        self.runner = runner
        self.host = host
        (stdoutLines, continuation) = AsyncThrowingStream.makeStream()
    }

    func send(_ line: String) throws { lock.withLock { sent.append(line) } }

    func closeInput() {
        let sent = lock.withLock { self.sent }
        let lines = runner.finished(host: host, sent: sent)
        if runner.stalling, sent != MachineProbe.script { return runner.hold(continuation) }
        for line in lines { continuation.yield(line) }
        continuation.finish()
    }

    func terminate() { continuation.finish() }
}
