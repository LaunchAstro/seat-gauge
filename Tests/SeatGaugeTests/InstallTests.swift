import Foundation
import ServiceManagement
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// `scripts/install.sh`, the login item and process teardown. Every script
/// case runs the real `scripts/install.sh` against a fake applications root
/// and a fake bin folder for `seatgauge-cli`, with `mdfind`, `mdutil`,
/// `pkill`, `open` and (unless a case needs the real one) `codesign` stubbed
/// ahead of it on `PATH`, so nothing here touches `/Applications`, the real
/// `PATH`, Spotlight, or a copy of the app that is running.
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
        let bin: URL

        var installed: URL { applications.appendingPathComponent("Seat Gauge.app") }
        var link: URL { bin.appendingPathComponent("seatgauge-cli") }
        var helper: URL { installed.appendingPathComponent("Contents/Helpers/seatgauge-cli") }
        var source: URL { dist.appendingPathComponent("Seat Gauge.app") }
    }

    /// A fake machine: an applications root, a `dist/` with a bundle in it, a
    /// second copy somewhere else that the stub `mdfind` reports only when
    /// `other` is set, and stubs for everything that would otherwise reach the
    /// real one. `indexing` is the status line the stub `mdutil` prints.
    /// `iCloud` builds a bundle the real `codesign` signs, then tags it with
    /// the metadata an iCloud-synced folder adds. `cli` is what sits at the
    /// CLI's destination beforehand, and `onPath` puts that folder on `PATH`.
    /// `folder` is what the CLI's folder, or the path above it, is to start with.
    @discardableResult
    static func install(indexing: String = "Indexing enabled.", signed: Bool = true,
                        bundle: Bool = true, helper: Bool = true, other: Bool = false,
                        iCloud: Bool = false, cli: Planted = .nothing,
                        onPath: Bool = true, folder: Folder = .usable) throws -> Ran {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-install-\(UUID().uuidString)", isDirectory: true)
        let applications = base.appendingPathComponent("Applications", isDirectory: true)
        let dist = base.appendingPathComponent("dist", isDirectory: true)
        let planted = base.appendingPathComponent("old/Seat Gauge.app", isDirectory: true)
        let bin = base.appendingPathComponent("bin", isDirectory: true)
        let cliBin = base.appendingPathComponent("local/bin", isDirectory: true)
        let trace = base.appendingPathComponent("trace.txt")
        for directory in [applications, dist, planted, bin, cliBin] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("old".utf8).write(to: planted.appendingPathComponent("marker"))
        if bundle {
            let app = dist.appendingPathComponent("Seat Gauge.app/Contents/MacOS", isDirectory: true)
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try Data("built".utf8).write(to: app.appendingPathComponent("SeatGauge"))
            if helper {
                let helpers = dist.appendingPathComponent("Seat Gauge.app/Contents/Helpers", isDirectory: true)
                try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
                try Data("built-cli".utf8).write(to: helpers.appendingPathComponent("seatgauge-cli"))
            }
        }
        if iCloud { try signAndTag(dist.appendingPathComponent("Seat Gauge.app")) }
        switch folder {
        case .usable: break
        case .readOnly:
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: cliBin.path)
        case .file:
            try FileManager.default.removeItem(at: cliBin)
            try Data("a file".utf8).write(to: cliBin)
        case .fileAbove:
            let above = cliBin.deletingLastPathComponent()
            try FileManager.default.removeItem(at: above)
            try Data("a file".utf8).write(to: above)
        }
        let link = cliBin.appendingPathComponent("seatgauge-cli")
        switch cli {
        case .nothing: break
        case .file: try Data("someone else's".utf8).write(to: link)
        case .link(let target):
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        case .ours:
            try FileManager.default.createSymbolicLink(
                atPath: link.path,
                withDestinationPath: applications.appendingPathComponent("Seat Gauge.app/Contents/Helpers/seatgauge-cli").path)
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
        if !iCloud { try stub("codesign", "exit \(signed ? 0 : 1)") }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [root.appendingPathComponent("scripts/install.sh").path]
        task.environment = [
            "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin" + (onPath ? ":\(cliBin.path)/" : ""),
            "SEATGAUGE_APPLICATIONS": applications.path,
            "SEATGAUGE_DIST": dist.path,
            "SEATGAUGE_BIN": cliBin.path,
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
                   applications: applications, dist: dist, planted: planted, bin: cliBin)
    }

    enum Planted { case nothing, file, link(String), ours }
    enum Folder { case usable, readOnly, file, fileAbove }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// A real ad hoc signature on a bundle whose executables are copies of
    /// `/usr/bin/true`, then the two attributes iCloud Drive adds to it.
    static func signAndTag(_ app: URL) throws {
        for path in ["Contents/MacOS/SeatGauge", "Contents/Helpers/seatgauge-cli"] {
            let file = app.appendingPathComponent(path)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: file.path)
        }
        try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
              <key>CFBundleExecutable</key><string>SeatGauge</string>
              <key>CFBundleIdentifier</key><string>com.launchastro.seatgauge</string>
            </dict></plist>
            """.utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        #expect(run("/usr/bin/codesign", "--force", "--sign", "-", "--identifier", "seatgauge-cli",
                    app.appendingPathComponent("Contents/Helpers/seatgauge-cli").path).status == 0)
        #expect(run("/usr/bin/codesign", "--force", "--sign", "-", "--identifier",
                    "com.launchastro.seatgauge", app.path).status == 0)
        // Finder flags with a bit set, as iCloud writes them. All zeros would
        // pass a strict check.
        #expect(run("/usr/bin/xattr", "-wx", "com.apple.FinderInfo",
                    String(repeating: "00", count: 8) + "04" + String(repeating: "00", count: 23),
                    app.path).status == 0)
        #expect(run("/usr/bin/xattr", "-w", "com.apple.fileprovider.fpfs#P", "1", app.path).status == 0)
        // The tagged copy is the one the old script refused.
        #expect(run("/usr/bin/codesign", "--verify", "--strict", app.path).status != 0)
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: String...) -> (status: Int32, out: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        guard (try? task.run()) != nil else { return (-1, "") }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()
        return (task.terminationStatus, out)
    }

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

    // MARK: - A checkout in iCloud

    @Test("a bundle iCloud has tagged installs, and the installed copy passes a strict signature check")
    func iCloudTaggedBundleInstalls() throws {
        let ran = try Self.install(iCloud: true)
        defer { try? FileManager.default.removeItem(at: ran.applications.deletingLastPathComponent()) }
        #expect(ran.status == 0, "\(ran.out)")
        let verify = Self.run("/usr/bin/codesign", "--verify", "--strict", ran.installed.path)
        #expect(verify.status == 0, "\(verify.out)")
        let attributes = Self.run("/usr/bin/xattr", ran.installed.path).out
        #expect(!attributes.contains("com.apple.FinderInfo"))
        #expect(!attributes.contains("com.apple.fileprovider"))
        #expect(!Self.exists(ran.source))
    }

    @Test("the install says the next step is the first launch")
    func saysTheNextStep() throws {
        let ran = try Self.install()
        defer { try? FileManager.default.removeItem(at: ran.applications.deletingLastPathComponent()) }
        #expect(ran.status == 0, "\(ran.out)")
        #expect(ran.out.contains("Next: the first launch"))
    }

    // MARK: - The CLI

    @Test("build-app.sh puts seatgauge-cli in the bundle, where install.sh links it from")
    @MainActor func theBundleCarriesTheCLI() throws {
        let built = try AppIconTests.buildApp()
        defer { try? FileManager.default.removeItem(at: built.app.deletingLastPathComponent().deletingLastPathComponent()) }
        #expect(built.status == 0, "\(built.out)")
        let helper = built.app.appendingPathComponent("Contents/Helpers/seatgauge-cli")
        #expect(try String(contentsOf: helper, encoding: .utf8) == "built-cli")
    }

    @Test("seatgauge-cli is linked into the bin folder, pointing at the installed copy")
    func linksTheCLI() throws {
        let ran = try Self.install()
        defer { try? FileManager.default.removeItem(at: ran.applications.deletingLastPathComponent()) }
        #expect(ran.status == 0, "\(ran.out)")
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: ran.link.path)
        #expect(target == ran.helper.path)
        #expect(try String(contentsOf: ran.link, encoding: .utf8) == "built-cli")
        #expect(!ran.out.contains("not on your PATH"))
    }

    @Test("a link this script made before is kept, and the install goes ahead")
    func keepsItsOwnLink() throws {
        let ran = try Self.install(cli: .ours)
        defer { try? FileManager.default.removeItem(at: ran.applications.deletingLastPathComponent()) }
        #expect(ran.status == 0, "\(ran.out)")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: ran.link.path) == ran.helper.path)
        #expect(try String(contentsOf: ran.link, encoding: .utf8) == "built-cli")
    }

    @Test("a seatgauge-cli the script did not put there is a refusal, and nothing is removed or installed")
    func foreignCLIIsARefusal() throws {
        let file = try Self.install(cli: .file)
        defer { try? FileManager.default.removeItem(at: file.applications.deletingLastPathComponent()) }
        #expect(file.status != 0)
        #expect(file.out.contains(file.link.path))
        #expect(try String(contentsOf: file.link, encoding: .utf8) == "someone else's")
        #expect(!Self.exists(file.installed))
        #expect(Self.exists(file.source))
        #expect(!file.trace.contains("pkill"))

        // A link to somewhere else is someone else's too, even a dangling one.
        let elsewhere = try Self.install(cli: .link("/nowhere/seatgauge-cli"))
        defer { try? FileManager.default.removeItem(at: elsewhere.applications.deletingLastPathComponent()) }
        #expect(elsewhere.status != 0)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: elsewhere.link.path)
                == "/nowhere/seatgauge-cli")
        #expect(!Self.exists(elsewhere.installed))
        #expect(!elsewhere.trace.contains("pkill"))
    }

    @Test("a bin folder that is not on PATH is said plainly, and the CLI is still linked")
    func saysWhenTheBinFolderIsNotOnPath() throws {
        let ran = try Self.install(onPath: false)
        defer { try? FileManager.default.removeItem(at: ran.applications.deletingLastPathComponent()) }
        #expect(ran.status == 0, "\(ran.out)")
        #expect(ran.out.contains("\(ran.bin.path) is not on your PATH"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: ran.link.path) == ran.helper.path)
    }

    @Test("a CLI folder the script cannot write to is a refusal before anything is removed or installed",
          arguments: [Folder.readOnly, .file, .fileAbove])
    func unusableBinFolderIsARefusal(folder: Folder) throws {
        let ran = try Self.install(folder: folder)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ran.bin.path)
            try? FileManager.default.removeItem(at: ran.applications.deletingLastPathComponent())
        }
        #expect(ran.status != 0)
        #expect(ran.out.contains(ran.bin.path), "\(ran.out)")
        #expect(ran.out.contains("Nothing has been removed"), "\(ran.out)")
        #expect(Self.exists(ran.planted))
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

        // A bundle built without the CLI would leave a link to nothing.
        let noCLI = try Self.install(helper: false)
        defer { try? FileManager.default.removeItem(at: noCLI.applications.deletingLastPathComponent()) }
        #expect(noCLI.status != 0)
        #expect(!Self.exists(noCLI.installed))
        #expect(!Self.exists(noCLI.link))
        #expect(!noCLI.trace.contains("pkill"))
    }
}
