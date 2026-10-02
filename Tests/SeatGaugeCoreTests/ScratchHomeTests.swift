import Foundation
import Testing

import SeatGaugeCore

/// `scripts/scratch-home.sh` and the dev build's own identifier. Every script
/// case runs the real `scripts/scratch-home.sh`, `Makefile` or
/// `scripts/build-app.sh` against folders this suite makes, with a home that
/// stands in for the developer's. Nothing here reads or writes the installed
/// app's Application Support folder or defaults.
@Suite struct ScratchHomeTests {

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SeatGaugeCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // the repository

    static let helper = root.appendingPathComponent("scripts/scratch-home.sh").path
    static let dev = AppPaths.bundleID + ".dev"
    static let invented = "com.example.seatgauge-sentinel"

    struct Ran {
        let status: Int32
        let out: String
        var lines: [String] { out.split(separator: "\n").map(String.init) }
    }

    static func run(_ executable: String, _ arguments: [String],
                    env: [String: String], in directory: URL? = nil) throws -> Ran {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.environment = env
        if let directory { task.currentDirectoryURL = directory }
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return Ran(status: task.terminationStatus, out: String(decoding: data, as: UTF8.self))
    }

    static func folder(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-scratch-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func env(home: URL, tmp: URL, fixed: Bool = false) -> [String: String] {
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path, "TMPDIR": tmp.path + "/"]
        if fixed { env["CFFIXED_USER_HOME"] = home.path }
        return env
    }

    /// Foundation's own answers, printed by a process the helper starts.
    static let probe = """
        ObjC.import('Foundation');
        var s = $.NSFileManager.defaultManager.URLsForDirectoryInDomains(
            $.NSApplicationSupportDirectory, $.NSUserDomainMask).firstObject.path.js;
        $.NSHomeDirectory().js + '\\n' + s
        """

    /// Writes where the app would keep its state, under the invented identifier,
    /// as Foundation resolves the home and Application Support, after printing
    /// the `HOME` and `CFFIXED_USER_HOME` it was given.
    static let writer = """
        ObjC.import('Foundation');
        var e = ObjC.deepUnwrap($.NSProcessInfo.processInfo.environment);
        var fm = $.NSFileManager.defaultManager;
        var s = fm.URLsForDirectoryInDomains($.NSApplicationSupportDirectory, $.NSUserDomainMask)
            .firstObject.path.js + '/\(invented)';
        var p = $.NSHomeDirectory().js + '/Library/Preferences';
        fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(s, true, $(), $());
        fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(p, true, $(), $());
        var ok = ['state.json', 'seats.json'].every(function (f) {
            return $('overwritten').writeToFileAtomicallyEncodingError(s + '/' + f, true, 4, $());
        }) && $('overwritten').writeToFileAtomicallyEncodingError(p + '/\(invented).plist', true, 4, $());
        e.HOME + '\\n' + e.CFFIXED_USER_HOME + '\\n' + (ok ? 'wrote ' : 'failed ') + s
        """

    static func jxa(_ script: String) -> [String] { ["/usr/bin/osascript", "-l", "JavaScript", "-e", script] }

    /// A copy of what `make app` needs, with `swift` and `codesign` stubbed so
    /// nothing is compiled or signed and the repository's `dist/` is not touched.
    static func scratchTree() throws -> (tree: URL, env: [String: String]) {
        let tree = try Self.folder("tree")
        let fm = FileManager.default
        for path in ["scripts", "Resources", ".build/release", "bin"] {
            try fm.createDirectory(at: tree.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        for path in ["Makefile", "VERSION", "scripts/build-app.sh", "Resources/Fonts", "Resources/AppIcon.icns"] {
            try fm.copyItem(at: root.appendingPathComponent(path), to: tree.appendingPathComponent(path))
        }
        try Data("built".utf8).write(to: tree.appendingPathComponent(".build/release/SeatGauge"))
        try Data("built-cli".utf8).write(to: tree.appendingPathComponent(".build/release/seatgauge-cli"))
        for stub in ["swift", "codesign"] {
            let file = tree.appendingPathComponent("bin/\(stub)")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let env = ["PATH": "\(tree.path)/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": tree.path]
        return (tree, env)
    }

    /// A response the spend roll-up would count, run in `cwd`.
    static func response(cwd: String) -> String {
        #"{"type":"assistant","requestId":"req-scratch","cwd":"\#(cwd)","timestamp":"2026-09-23T01:00:00.000Z","#
            + #""message":{"id":"msg-scratch","model":"claude-opus-5-5","usage":{"input_tokens":5,"output_tokens":5}}}"#
            + "\n"
    }

    static func builtID(_ tree: URL) -> String? {
        let plist = tree.appendingPathComponent("dist/Seat Gauge.app/Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return dict["CFBundleIdentifier"] as? String
    }

    @Test func everySwiftTestRunsUnderAScratchHome() throws {
        let home = try Self.folder("home")
        let tmp = try Self.folder("tmp")
        let ran = try Self.run("/bin/bash", [Self.helper] + Self.jxa(Self.probe), env: Self.env(home: home, tmp: tmp))
        #expect(ran.status == 0, "\(ran.out)")
        let lines = ran.lines
        try #require(lines.count >= 2, "\(ran.out)")
        let scratch = lines[lines.count - 2]
        #expect(scratch != home.path && !scratch.hasPrefix(home.path + "/"))
        #expect(scratch.hasPrefix(tmp.path + "/"), "\(scratch)")
        #expect(lines[lines.count - 1] == scratch + "/Library/Application Support")
        #expect(!FileManager.default.fileExists(atPath: scratch), "the scratch home outlived its run")
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.path).isEmpty)

        // Defaults are not moved by a home; the test process's are its own.
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        #expect(domain != AppPaths.bundleID && !domain.hasPrefix(AppPaths.bundleID + "."), "\(domain)")
    }

    @Test func aDevBuildSharesNothingWithTheInstalledApp() throws {
        #expect(AppPaths.identifier(running: Self.dev) == Self.dev)
        #expect(AppPaths.identifier(running: AppPaths.bundleID) == AppPaths.bundleID)
        #expect(AppPaths.identifier(running: nil) == AppPaths.bundleID)
        #expect(AppPaths.identifier(running: "com.apple.dt.xctest.tool") == AppPaths.bundleID)
        #expect(AppPaths.identifier(running: AppPaths.bundleID + "x") == AppPaths.bundleID)
        #expect(AppPaths.identifier(running: AppPaths.bundleID + ".") == AppPaths.bundleID)
        let dev = AppPaths.support(identifier: Self.dev)
        let real = AppPaths.support(identifier: AppPaths.bundleID)
        #expect(dev.lastPathComponent == Self.dev)
        #expect(dev.deletingLastPathComponent() == real.deletingLastPathComponent())
        #expect(dev != real)

        // Neither build counts the other's polling, whichever primer it was
        // given, and a folder that only starts like a primer is not one.
        let base = try Self.folder("support")
        let primers = [AppPaths.bundleID, Self.dev].map { base.appendingPathComponent("\($0)/primer") }
        let transcript = base.appendingPathComponent("t.jsonl")
        for cwd in primers + [base.appendingPathComponent("\(Self.dev)/primerX")] {
            try Data(Self.response(cwd: cwd.path).utf8).write(to: transcript)
            let counted = primers.map { ClaudeCollector.read(file: transcript, primer: $0).responses.count }
            #expect(counted == (cwd.lastPathComponent == "primer" ? [0, 0] : [1, 1]), "\(cwd.path)")
        }

        // Only exactly 1 opts into the real id; any other value builds nothing.
        let (tree, env) = try Self.scratchTree()
        for value in ["0", "false"] {
            let refused = try Self.run("/usr/bin/make", ["app", "SEATGAUGE_REAL_ID=\(value)"], env: env, in: tree)
            #expect(refused.status != 0, "\(value): \(refused.out)")
            #expect(refused.lines.filter { $0.contains("SEATGAUGE_REAL_ID") }.count == 1, "\(refused.out)")
            #expect(Self.builtID(tree) == nil, "SEATGAUGE_REAL_ID=\(value) built a bundle")
        }
        let empty = try Self.run("/usr/bin/make", ["app", "SEATGAUGE_REAL_ID="], env: env, in: tree)
        #expect(empty.status == 0, "\(empty.out)")
        #expect(Self.builtID(tree) == Self.dev)
        let plain = try Self.run("/usr/bin/make", ["app"], env: env, in: tree)
        #expect(plain.status == 0, "\(plain.out)")
        #expect(Self.builtID(tree) == Self.dev)
        let opted = try Self.run("/usr/bin/make", ["app", "SEATGAUGE_REAL_ID=1"], env: env, in: tree)
        #expect(opted.status == 0, "\(opted.out)")
        #expect(Self.builtID(tree) == AppPaths.bundleID)
        let install = try Self.run("/usr/bin/make", ["-n", "install"], env: env, in: tree)
        // A sandbox's make can print a confstr() diagnostic first; the recipe is the rest.
        let recipe = install.lines.filter { !$0.contains("confstr()") }
        #expect(recipe == ["scripts/build-app.sh", "scripts/install.sh"], "\(install.out)")
    }

    @Test func sentinelsOutsideTheScratchHomeAreByteIdentical() throws {
        let home = try Self.folder("sentinel")
        let tmp = try Self.folder("tmp")
        let support = home.appendingPathComponent("Library/Application Support/\(Self.invented)")
        let prefs = home.appendingPathComponent("Library/Preferences")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
        let seeded: [URL: Data] = [
            support.appendingPathComponent("state.json"):
                Data(#"{"textSize":"sentinel-text","light":false,"alerts":{"sentinel":["one"]}}"#.utf8),
            support.appendingPathComponent("seats.json"):
                Data(#"{"seats":[{"name":"sentinel","provider":"claude","plan":"max20"}]}"#.utf8),
            prefs.appendingPathComponent("\(Self.invented).plist"):
                try PropertyListSerialization.data(fromPropertyList: ["NSWindow Frame Main": "0 0 50 50 sentinel"],
                                                   format: .binary, options: 0),
        ]
        for (url, data) in seeded { try data.write(to: url) }

        let ran = try Self.run("/bin/bash", [Self.helper] + Self.jxa(Self.writer),
                               env: Self.env(home: home, tmp: tmp, fixed: true))
        #expect(ran.status == 0, "\(ran.out)")
        #expect(ran.out.contains("wrote "), "the writer did not write, so it proved nothing: \(ran.out)")
        #expect(!ran.out.contains(home.path), "\(ran.out)")
        // The writer's HOME and CFFIXED_USER_HOME were both the helper's
        // scratch folder, and that folder is gone once the run ends.
        let lines = ran.lines
        try #require(lines.count >= 3, "\(ran.out)")
        let scratch = tmp.path + "/seat-gauge-home."
        #expect(lines[lines.count - 3].hasPrefix(scratch), "HOME was \(lines[lines.count - 3])")
        #expect(lines[lines.count - 2].hasPrefix(scratch), "CFFIXED_USER_HOME was \(lines[lines.count - 2])")
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.path).isEmpty, "the scratch home outlived its run")
        for (url, data) in seeded {
            #expect((try? Data(contentsOf: url)) == data, "\(url.path) changed")
        }
    }

    @Test func failsClosedWhenTheGateCannotIsolate() throws {
        let home = try Self.folder("home")
        let tmp = try Self.folder("tmp")
        let marker = home.appendingPathComponent("ran")

        let bare = try Self.run("/bin/bash", [Self.helper], env: Self.env(home: home, tmp: tmp))
        #expect(bare.status != 0)

        let nowhere = tmp.appendingPathComponent("missing/deeper")
        var env = Self.env(home: home, tmp: tmp)
        env["TMPDIR"] = nowhere.path
        let stuck = try Self.run("/bin/bash", [Self.helper, "/usr/bin/touch", marker.path], env: env)
        #expect(stuck.status != 0)
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the command ran with no scratch home")

        let failing = try Self.run("/bin/bash", [Self.helper, "/usr/bin/false"], env: Self.env(home: home, tmp: tmp))
        #expect(failing.status == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.path).isEmpty)

        let (tree, treeEnv) = try Self.scratchTree()
        let other = try Self.run("/bin/bash", ["scripts/build-app.sh", "com.example.other"], env: treeEnv, in: tree)
        #expect(other.status != 0)
        #expect(!FileManager.default.fileExists(atPath: tree.appendingPathComponent("dist").path))
    }
}
