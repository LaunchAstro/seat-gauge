import Foundation
import Testing

import SeatGaugeCore
import SeatGaugeTestSupport

/// The folders `machines.json` names beside `free_gb` as safe to clear: a
/// fixed list, sized now and then at background priority, never deleted.
@Suite struct ClearableFoldersTests {
    static func scratch() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("clearable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    static func fill(_ folder: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: folder.appendingPathComponent("blob"))
    }

    /// Runs the size script in a real `/bin/sh -s` with `home` as its home,
    /// as ssh runs it at the far end, and returns what it printed.
    static func run(home: URL, limit: Int = ClearableFolders.limit, remote: Bool = false,
                    path: String = "/usr/bin:/bin:/usr/sbin:/sbin") async throws -> [String] {
        let session = try RealProcessRunner().launch(ProcessSpec(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-s"],
            environment: ["HOME": home.path, "PATH": path], timeout: .seconds(30)))
        for line in ClearableFolders.script(limit: limit, remote: remote) { try session.send(line) }
        session.closeInput()
        var printed: [String] = []
        for try await line in session.stdoutLines { printed.append(line) }
        return printed
    }

    @Test("the script sizes each listed folder that is there, and only those, largest first")
    func sizes() async throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.fill(home.appendingPathComponent("Library/Caches/Homebrew"), bytes: 3_000_000)
        try Self.fill(home.appendingPathComponent(".npm/_cacache"), bytes: 1_000_000)
        // Not on the list, so never sized or named.
        try Self.fill(home.appendingPathComponent("Documents/work"), bytes: 5_000_000)
        // A listed name that is a link, or sits under one, is passed over:
        // it may point anywhere, another disk included.
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".cache"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".cache/uv"),
                                                   withDestinationURL: home.appendingPathComponent("Documents"))
        try Self.fill(home.appendingPathComponent("elsewhere/registry"), bytes: 4_000_000)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".cargo"),
                                                   withDestinationURL: home.appendingPathComponent("elsewhere"))
        let printed = try await Self.run(home: home)
        #expect(printed.last == "end")
        let folders = try #require(ClearableFolders.parse(printed, atLeast: 1))
        #expect(folders.map(\.path) == ["~/Library/Caches/Homebrew", "~/.npm/_cacache"])
        #expect((2_900_000 ... 3_200_000).contains(folders[0].bytes))
        #expect(folders[0].clear == "delete what is inside; it holds Homebrew's downloads only")
        // Nothing was removed.
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Caches/Homebrew/blob").path))
    }

    @Test("a home with none of the folders sizes nothing and still ends")
    func none() async throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let printed = try await Self.run(home: home)
        #expect(printed == ["end"])
        #expect(ClearableFolders.parse(printed) == [])
    }

    @Test("a size pass past its time limit is stopped there, keeping the folders it finished and leaving no du running")
    func limit() async throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.fill(home.appendingPathComponent("Library/Caches/Homebrew"), bytes: 1_000)
        try Self.fill(home.appendingPathComponent("Library/Caches/pip"), bytes: 1_000)
        try Self.fill(home.appendingPathComponent(".npm/_cacache"), bytes: 1_000)
        // The real du for the first folder, noting the priority it runs at;
        // the second hangs, noting its process, until it is killed.
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let du = bin.appendingPathComponent("du")
        try """
            #!/bin/sh
            case "$2" in Library/Caches/Homebrew) ps -o ni=,pri= -p $$ > "$HOME/priority"; exec /usr/bin/du "$@" ;; esac
            echo $$ > "$HOME/hung"
            exec sleep 60
            """.write(to: du, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: du.path)
        let started = ContinuousClock.now
        let printed = try await Self.run(home: home, limit: 8, path: bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(ContinuousClock.now - started < .seconds(30))
        #expect(Array(printed.suffix(2)) == ["cut", "end"])
        let folders = try #require(ClearableFolders.parse(printed, atLeast: 1))
        #expect(folders.map(\.path) == ["~/Library/Caches/Homebrew"])
        // The stopped du is gone, not left running on the machine.
        let hung = try #require(Int32(String(contentsOf: home.appendingPathComponent("hung"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(hung, 0) != 0)
        // nice 20, and background priority (4) from taskpolicy -b.
        let priority = try String(contentsOf: home.appendingPathComponent("priority"), encoding: .utf8)
            .split(whereSeparator: \.isWhitespace)
        #expect(priority == ["20", "4"])
    }

    @Test("a folder on another disk than the home is passed over, and odd file names inside a folder change nothing")
    func otherDisk() async throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let brew = home.appendingPathComponent("Library/Caches/Homebrew")
        try Self.fill(brew, bytes: 1_000)
        try Data().write(to: brew.appendingPathComponent("a\n999999\tYarn\n$(touch x)"))
        try Self.fill(home.appendingPathComponent("Library/Caches/pip"), bytes: 1_000)
        // A stat that puts pip on a disk of its own.
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let stat = bin.appendingPathComponent("stat")
        try """
            #!/bin/sh
            case "$3" in Library/Caches/pip) echo 2 ;; *) echo 1 ;; esac
            """.write(to: stat, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stat.path)
        let printed = try await Self.run(home: home, path: bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(ClearableFolders.parse(printed, atLeast: 1)?.map(\.path) == ["~/Library/Caches/Homebrew"])
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("x").path))
        #expect(!FileManager.default.fileExists(atPath: brew.appendingPathComponent("x").path))
    }

    @Test("elsewhere, a machine whose own Seat Gauge has a seats.json sizes itself, so nothing is sized from here")
    func own() async throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.fill(home.appendingPathComponent("Library/Caches/Homebrew"), bytes: 1_000_000)
        let folder = home.appendingPathComponent("Library/Application Support/com.launchastro.seatgauge")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("seats.json"))
        let there = try await Self.run(home: home, remote: true)
        #expect(there == ["own"])
        #expect(ClearableFolders.parse(there) == nil)
        // This Mac is always sized: its seats.json is this app's own.
        #expect(ClearableFolders.parse(try await Self.run(home: home), atLeast: 1)?.count == 1)
    }

    @Test("du runs at background priority, lowest nice, on one disk, and the script deletes nothing")
    func gentle() {
        let script = ClearableFolders.script().joined(separator: "\n")
        #expect(script.contains("taskpolicy -b"))
        #expect(script.contains("nice -n 20"))
        #expect(script.contains("du -skx"))
        for word in ["rm ", "rmdir", "unlink", "mv ", "> ", "find "] { #expect(!script.contains(word)) }
    }

    @Test("an answer is read only as far as the list goes: unknown paths, odd sizes and a cut-off answer")
    func parse() {
        let big = "200000"
        #expect(ClearableFolders.parse(["\(big)\tLibrary/Caches/Homebrew"]) == nil)
        #expect(ClearableFolders.parse(["\(big)\tDocuments", "\(big)\t../Library/Caches/Homebrew",
                                        "x\tLibrary/Caches/pip", "-5\t.cache/uv", "end"]) == [])
        let read = ClearableFolders.parse(["100000\tLibrary/Caches/pip", "\(big)\tLibrary/Caches/Homebrew",
                                           "50000\t.cache/uv", "end"])
        // Under a tenth of a gigabyte is not worth naming.
        #expect(read?.map(\.path) == ["~/Library/Caches/Homebrew", "~/Library/Caches/pip"])
        #expect(read?.first?.bytes == Int64(200_000) * 1024)
    }

    @Test("machines.json names the folders beside free_gb, with when they were sized, or null before")
    func file() throws {
        let reading = MachineReading(takenAt: MachineLoadTests.now, cpuUsed: 10, load: [1, 1, 1], cores: 10, ramUsed: 20,
                                     ramBytes: 1 << 34, diskUsed: 50, diskFreeBytes: 100_000_000_000, agents: nil)
        let folders = [ClearableFolder(path: "~/Library/Caches/Homebrew", bytes: 2_345_000_000, clear: "brew cleanup --prune=all")]
        let written = MachinesFile(machines: [.here, Machine(id: "studio", label: "Studio", ssh: "studio.local")],
                                   states: [Machine.here.id: .live(reading), "studio": .live(reading)],
                                   clearable: [Machine.here.id: ClearableReport(sizedAt: MachineLoadTests.now, folders: folders)],
                                   seconds: 5, now: MachineLoadTests.now, timeZone: TimeZone(identifier: "UTC")!)
        let json = try JSONSerialization.jsonObject(with: written.data()) as! [String: Any]
        let rows = json["machines"] as! [[String: Any]]
        let disk = rows[0]["disk"] as! [String: Any]
        let first = (disk["clearable"] as! [[String: Any]])[0]
        #expect(first["path"] as? String == "~/Library/Caches/Homebrew")
        #expect(first["gb"] as? Double == 2.3)
        #expect(first["clear"] as? String == "brew cleanup --prune=all")
        #expect(disk["clearable_at"] as? String == "2026-09-21T14:13:20Z")
        let unsized = rows[1]["disk"] as! [String: Any]
        #expect(unsized["clearable"] is NSNull)
        #expect(unsized["clearable_at"] is NSNull)
    }

    @Test("each live machine is sized at its first read, then not again for 15 minutes, off the read loop")
    func schedule() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("machines-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let studio = Machine(id: "studio", label: "Studio", ssh: "studio.local")
        let gone = Machine(id: "gone", label: "Gone", ssh: "gone.local")
        let config = Config(seats: [], pollMinutes: 5, machines: [.here, studio, gone])
        let runner = SizeRunner(answering: ["": MachineLoadTests.printed, "studio.local": MachineLoadTests.printed],
                                sized: ["1000000\tLibrary/Caches/Homebrew", "end"])
        let clock = ShareClock(MachineLoadTests.now)
        let monitor = MachineMonitor(prober: MachineProber(runner: runner, environment: [:]), file: file,
                                     sizer: ClearableSizer(runner: runner, environment: [:]),
                                     now: { clock.now }, config: { config })
        await monitor.read()
        await monitor.settle()
        #expect(runner.sizes.sorted() == ["", "studio.local"])
        // The sizes land in the next write.
        clock.now = MachineLoadTests.now.addingTimeInterval(5)
        await monitor.read()
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let disk = (json["machines"] as! [[String: Any]])[0]["disk"] as! [String: Any]
        #expect((disk["clearable"] as? [[String: Any]])?.first?["path"] as? String == "~/Library/Caches/Homebrew")

        clock.now = MachineLoadTests.now.addingTimeInterval(14 * 60)
        await monitor.read()
        await monitor.settle()
        #expect(runner.sizes.count == 2)
        clock.now = MachineLoadTests.now.addingTimeInterval(15 * 60)
        await monitor.read()
        await monitor.settle()
        #expect(runner.sizes.count == 4)
    }

    @Test("a size pass that hangs never holds up the read, and is not started twice")
    func stalled() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("machines-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let config = Config(seats: [], pollMinutes: 5, machines: [.here])
        let runner = SizeRunner(answering: ["": MachineLoadTests.printed], sized: nil)
        let clock = ShareClock(MachineLoadTests.now)
        let monitor = MachineMonitor(prober: MachineProber(runner: runner, environment: [:]), file: file,
                                     sizer: ClearableSizer(runner: runner, environment: [:]),
                                     now: { clock.now }, config: { config })
        let done = ShareClock(.distantPast)
        let reading = Task {
            _ = await monitor.read()
            clock.now = MachineLoadTests.now.addingTimeInterval(16 * 60)
            _ = await monitor.read()
            done.now = .distantFuture
        }
        for _ in 0 ..< 500 where done.now != .distantFuture { try await Task.sleep(for: .milliseconds(10)) }
        #expect(done.now == .distantFuture)
        #expect(runner.sizes == [""])
        runner.release()
        await reading.value
    }

    @Test("a monitor with no sizer, as the CLI's one-off read makes, sizes nothing")
    func noSizer() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("machines-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let runner = SizeRunner(answering: ["": MachineLoadTests.printed], sized: [])
        await MachineMonitor(prober: MachineProber(runner: runner, environment: [:]), file: file,
                             config: { Config(seats: [], pollMinutes: 5, machines: [.here]) }).read()
        #expect(runner.sizes == [])
    }

    @Test("the size pass rides the probe's ssh connection, with a deadline past the script's own limit")
    func spec() {
        let studio = Machine(id: "studio", label: "Studio", ssh: "studio.local")
        #expect(ClearableSizer.spec(studio, environment: [:]).arguments == MachineProber.spec(studio, environment: [:]).arguments)
        #expect(ClearableSizer.spec(.here, environment: [:]).executable.path == "/bin/sh")
        #expect(ClearableSizer.timeout > .seconds(ClearableFolders.limit))
    }
}

/// Answers the load probe with each host's lines and the size script with
/// `sized`; nil `sized` never answers until `release`.
final class SizeRunner: ProcessRunning, @unchecked Sendable {
    private let answering: [String: [String]]
    private let sized: [String]?
    private let lock = NSLock()
    private var log: [String] = []
    private var held: [AsyncThrowingStream<String, Error>.Continuation] = []

    init(answering: [String: [String]], sized: [String]?) {
        self.answering = answering
        self.sized = sized
    }

    var sizes: [String] { lock.withLock { log } }

    func release() { for continuation in lock.withLock({ held }) { continuation.finish() } }

    func launch(_ spec: ProcessSpec) throws -> any ProcessSession {
        let host = spec.executable.path == "/usr/bin/ssh"
            ? spec.arguments[spec.arguments.firstIndex(of: "--")! + 1] : ""
        return SizeSession(runner: self, host: host)
    }

    fileprivate func finished(host: String, sent: [String],
                              _ continuation: AsyncThrowingStream<String, Error>.Continuation) {
        if sent == MachineProbe.script {
            for line in answering[host] ?? [] { continuation.yield(line) }
            return continuation.finish()
        }
        lock.withLock { log.append(host) }
        guard let sized else { return lock.withLock { held.append(continuation) } }
        for line in sized { continuation.yield(line) }
        continuation.finish()
    }
}

private final class SizeSession: ProcessSession, @unchecked Sendable {
    private let runner: SizeRunner
    private let host: String
    private let lock = NSLock()
    private var sent: [String] = []
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    let stdoutLines: AsyncThrowingStream<String, Error>

    init(runner: SizeRunner, host: String) {
        self.runner = runner
        self.host = host
        (stdoutLines, continuation) = AsyncThrowingStream.makeStream()
    }

    func send(_ line: String) throws { lock.withLock { sent.append(line) } }
    func closeInput() { runner.finished(host: host, sent: lock.withLock { sent }, continuation) }
    func terminate() { continuation.finish() }
}
