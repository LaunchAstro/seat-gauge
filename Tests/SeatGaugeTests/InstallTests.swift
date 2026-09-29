import Foundation
import ServiceManagement
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// `scripts/install.sh`, the login item and process teardown. Every script
/// case runs the real `scripts/install.sh` against a fake applications root
/// with `mdfind`, `mdutil`, `pkill`, `open` and `codesign` stubbed ahead of it
/// on `PATH`, so nothing here touches `/Applications`, Spotlight, or a copy of
/// the app that is running.
@Suite(.sharedMirror) struct InstallTests {

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SeatGaugeTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // the repository

    struct Ran {
        let status: Int32
        let out: String
        let trace: [String]
        let applications: URL
        let dist: URL
        let planted: URL

        var installed: URL { applications.appendingPathComponent("Seat Gauge.app") }
        var source: URL { dist.appendingPathComponent("Seat Gauge.app") }
    }

    /// A fake machine: an applications root, a `dist/` with a bundle in it, a
    /// second copy somewhere else that the stub `mdfind` reports only when
    /// `other` is set, and stubs for everything that would otherwise reach the
    /// real one. `indexing` is the status line the stub `mdutil` prints.
    @discardableResult
    static func install(indexing: String = "Indexing enabled.", signed: Bool = true,
                        bundle: Bool = true, other: Bool = false) throws -> Ran {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-install-\(UUID().uuidString)", isDirectory: true)
        let applications = base.appendingPathComponent("Applications", isDirectory: true)
        let dist = base.appendingPathComponent("dist", isDirectory: true)
        let planted = base.appendingPathComponent("old/Seat Gauge.app", isDirectory: true)
        let bin = base.appendingPathComponent("bin", isDirectory: true)
        let trace = base.appendingPathComponent("trace.txt")
        for directory in [applications, dist, planted, bin] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("old".utf8).write(to: planted.appendingPathComponent("marker"))
        if bundle {
            let app = dist.appendingPathComponent("Seat Gauge.app/Contents/MacOS", isDirectory: true)
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try Data("built".utf8).write(to: app.appendingPathComponent("SeatGauge"))
        }

        func stub(_ name: String, _ body: String) throws {
            let file = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\nprintf '%s\\n' \(name) >> \"$SEATGAUGE_TRACE\"\n\(body)\n".utf8)
                .write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        try stub("mdutil", "printf '/:\\n\\t%s\\n' '\(indexing)'")
        let found = other ? planted.path : applications.appendingPathComponent("Seat Gauge.app").path
        try stub("mdfind", "printf '%s\\n' '\(found)'")
        try stub("pkill", "exit 0")
        try stub("open", "exit 0")
        try stub("codesign", "exit \(signed ? 0 : 1)")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [root.appendingPathComponent("scripts/install.sh").path]
        task.environment = [
            "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "SEATGAUGE_APPLICATIONS": applications.path,
            "SEATGAUGE_DIST": dist.path,
            "SEATGAUGE_TRACE": trace.path,
            "HOME": NSHomeDirectory(),
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()
        let said = (try? String(contentsOf: trace, encoding: .utf8)) ?? ""
        return Ran(status: task.terminationStatus, out: out,
                   trace: said.split(separator: "\n").map(String.init),
                   applications: applications, dist: dist, planted: planted)
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: - Install order

    @Test("install.sh checks for other copies, quits, replaces its own copy, empties dist and launches, in that order")
    func installsInOrder() throws {
        let ran = try Self.install()
        defer { try? FileManager.default.removeItem(at: ran.applications.deletingLastPathComponent()) }
        #expect(ran.status == 0)

        // The search comes first, so a refusal can happen before the app is
        // quit; the launch comes last.
        let quit = try #require(ran.trace.firstIndex(of: "pkill"))
        let search = try #require(ran.trace.firstIndex(of: "mdfind"))
        let launch = try #require(ran.trace.firstIndex(of: "open"))
        #expect(search < quit)
        #expect(quit < launch)

        // The bundle is in the applications root, the dist copy it was built
        // from is gone, and a copy Spotlight did not report is left alone.
        #expect(Self.exists(ran.planted))
        #expect(Self.exists(ran.installed.appendingPathComponent("Contents/MacOS/SeatGauge")))
        #expect(!Self.exists(ran.source))
    }

    @Test("an index Spotlight reports as read-only still answers mdfind, so it installs")
    func readOnlyIndexInstalls() throws {
        let ran = try Self.install(indexing: "Index is read-only.")
        defer { try? FileManager.default.removeItem(at: ran.applications.deletingLastPathComponent()) }
        #expect(ran.status == 0)
        #expect(ran.trace.contains("mdfind"))
        #expect(Self.exists(ran.installed.appendingPathComponent("Contents/MacOS/SeatGauge")))
    }

    @Test("a disabled index is refused even when the response mentions read-only")
    func disabledIndexMentioningReadOnlyIsRefused() throws {
        let ran = try Self.install(indexing: "Indexing disabled. Index is read-only.")
        defer { try? FileManager.default.removeItem(at: ran.applications.deletingLastPathComponent()) }
        #expect(ran.status != 0)
        #expect(!ran.trace.contains("pkill"))
        #expect(!Self.exists(ran.installed))
        #expect(Self.exists(ran.source))
    }

    @Test("another copy elsewhere is a refusal, and nothing is removed or installed")
    func anotherCopyIsARefusal() throws {
        let ran = try Self.install(other: true)
        defer { try? FileManager.default.removeItem(at: ran.applications.deletingLastPathComponent()) }
        #expect(ran.status != 0)
        #expect(ran.out.contains(ran.planted.path))
        #expect(Self.exists(ran.planted.appendingPathComponent("marker")))
        #expect(!Self.exists(ran.installed))
        #expect(Self.exists(ran.source))
        #expect(!ran.trace.contains("pkill"))
    }

    // MARK: - The login item path

    @Test("the installed copy is the one path the login item will register from")
    @MainActor func installedWhereTheLoginItemCanRegister() throws {
        let ran = try Self.install()
        defer { try? FileManager.default.removeItem(at: ran.applications.deletingLastPathComponent()) }
        #expect(ran.installed.lastPathComponent == "Seat Gauge.app")
        #expect(ran.installed.deletingLastPathComponent().path == ran.applications.path)

        // The rule the destination has to satisfy, read off LoginItem itself.
        let real = LoginItem(service: NeverService(),
                             bundle: URL(fileURLWithPath: "/Applications/Seat Gauge.app"),
                             store: StateStore(file: ran.applications.appendingPathComponent("state.json")))
        #expect(real.isInApplications)
        let copy = LoginItem(service: NeverService(), bundle: ran.source,
                             store: StateStore(file: ran.applications.appendingPathComponent("state.json")))
        #expect(!copy.isInApplications)
    }

    struct NeverService: LoginItemService {
        var status: SMAppService.Status { .notRegistered }
        func register() throws {}
        func unregister() throws {}
    }

    // MARK: - The launched copy

    @Test("the copy that is launched is the installed one")
    func launchesTheInstalledCopy() throws {
        let ran = try Self.install()
        defer { try? FileManager.default.removeItem(at: ran.applications.deletingLastPathComponent()) }
        #expect(ran.trace.last == "open")
        #expect(!Self.exists(ran.source))
    }

    // MARK: - Poll logging

    @Test("every poll logs one line under the app's subsystem, at the config's interval")
    func everyPollLogsUnderTheSubsystem() throws {
        #expect(AppPaths.bundleID == PollLog.subsystem)
        // The shipped interval, so half an hour is six polls.
        let config = try ConfigLoader.decode(Data(ConfigLoader.template.utf8))
        #expect(config.pollMinutes == 5)
        #expect(30 / config.pollMinutes == 6)
    }

    // MARK: - Teardown

    @Test("a fetch that is ended leaves no child behind")
    func endedFetchLeavesNoChild() async throws {
        let marker = "seat-gauge-teardown-\(UUID().uuidString)"
        let session = try RealProcessRunner().launch(ProcessSpec(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; echo up; while :; do sleep 0.2; done # \(marker)"],
            environment: ["PATH": "/usr/bin:/bin"], currentDirectory: nil, timeout: .seconds(10)))
        for try await line in session.stdoutLines where line == "up" { break }
        #expect(Self.running(marker) > 0)

        // SIGTERM is ignored by that shell, so only the kill after the grace
        // can end it.
        session.terminate()
        var left = 1
        for _ in 0 ..< 30 {
            left = Self.running(marker)
            if left == 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(left == 0)
    }

    /// How many processes `pgrep -f` finds carrying the marker.
    static func running(_ marker: String) -> Int {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", marker]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return -1 }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()
        return out.split(separator: "\n").count
    }

    // MARK: - Relaunch

    @Test("a launch from /Applications registers the login item again")
    func everyLaunchRegistersAgain() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-relaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StateStore(file: directory.appendingPathComponent("state.json"))
        let service = CountingService()
        await MainActor.run {
            let item = LoginItem(service: service,
                                 bundle: URL(fileURLWithPath: "/Applications/Seat Gauge.app"),
                                 store: store)
            item.registerAtLaunch()
            // A second launch, as a log out and in makes one.
            LoginItem(service: service, bundle: URL(fileURLWithPath: "/Applications/Seat Gauge.app"),
                      store: store).registerAtLaunch()
        }
        #expect(service.registers == 2)
    }

    final class CountingService: LoginItemService, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var registers: Int { lock.withLock { count } }
        var status: SMAppService.Status { .notRegistered }
        func register() throws { lock.withLock { count += 1 } }
        func unregister() throws {}
    }

    // MARK: - Fails closed

    @Test("Fails closed: no Spotlight, no bundle and no signature are all refusals")
    func failsClosedOnSpotlightAndAnUnsignedBundle() throws {
        let unindexed = try Self.install(indexing: "Indexing disabled.")
        defer { try? FileManager.default.removeItem(at: unindexed.applications.deletingLastPathComponent()) }
        #expect(unindexed.status != 0)
        #expect(unindexed.out.lowercased().contains("spotlight"))
        // Nothing was removed and nothing was installed.
        #expect(Self.exists(unindexed.planted))
        #expect(!Self.exists(unindexed.installed))
        #expect(Self.exists(unindexed.source))

        // A status line the script does not know is a refusal too.
        let unknown = try Self.install(indexing: "Error: unknown indexing state.")
        defer { try? FileManager.default.removeItem(at: unknown.applications.deletingLastPathComponent()) }
        #expect(unknown.status != 0)
        #expect(unknown.out.lowercased().contains("spotlight"))
        #expect(!Self.exists(unknown.installed))
        #expect(Self.exists(unknown.source))

        let unsigned = try Self.install(signed: false)
        defer { try? FileManager.default.removeItem(at: unsigned.applications.deletingLastPathComponent()) }
        #expect(unsigned.status != 0)
        #expect(Self.exists(unsigned.planted))
        #expect(!Self.exists(unsigned.installed))

        let nothing = try Self.install(bundle: false)
        defer { try? FileManager.default.removeItem(at: nothing.applications.deletingLastPathComponent()) }
        #expect(nothing.status != 0)
        #expect(Self.exists(nothing.planted))
        #expect(!Self.exists(nothing.installed))
    }
}
