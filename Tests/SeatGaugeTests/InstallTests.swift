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
    /// `busy` is what `mdutil` says before it says `indexing`, as it can
    /// straight after a build. `gone` has `mdfind` also list a copy that is no
    /// longer on disk. `prior` is what sits at the destination beforehand.
    /// `copyFails` fails the copy into the applications root, `asideFails` the
    /// rename that moves the installed copy aside, `swapFails` the rename that
    /// puts the new copy in place, and `raced` has another install put its
    /// copy at the destination straight after the old one is moved aside.
    /// `swapped` puts another app, or a relative link, at the destination after
    /// it was checked and before it is moved aside, from the stub `pkill`,
    /// which runs between. `late` swaps a foreign app in for the moved-aside
    /// copy at the moment it is deleted: as the deleting `perl` starts, or as
    /// the emptied folder's `rmdir` runs.
    @discardableResult
    static func install(indexing: String = "Indexing enabled.", busy: String? = nil, signed: Bool = true,
                        bundle: Bool = true, helper: Bool = true, other: Bool = false, gone: Bool = false,
                        iCloud: Bool = false, cli: Planted = .nothing,
                        onPath: Bool = true, folder: Folder = .usable, prior: Prior = .nothing,
                        copyFails: Bool = false, asideFails: Bool = false, swapFails: Bool = false,
                        raced: Bool = false, swapped: Swapped = .nothing, late: Late = .nothing) throws -> Ran {
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
        let dest = applications.appendingPathComponent("Seat Gauge.app", isDirectory: true)
        switch prior {
        case .nothing: break
        case .ours, .foreign, .bare:
            try FileManager.default.createDirectory(at: dest.appendingPathComponent("Contents"),
                                                    withIntermediateDirectories: true)
            try Data("before".utf8).write(to: dest.appendingPathComponent("marker"))
            if prior != .bare {
                let id = prior == .ours ? "com.launchastro.seatgauge" : "com.example.other"
                try Data("""
                    <?xml version="1.0" encoding="UTF-8"?>
                    <plist version="1.0"><dict>
                      <key>CFBundleIdentifier</key><string>\(id)</string>
                    </dict></plist>
                    """.utf8).write(to: dest.appendingPathComponent("Contents/Info.plist"))
            }
        case .link:
            try FileManager.default.createSymbolicLink(at: dest, withDestinationURL: planted)
        }
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
        let asked = base.appendingPathComponent("mdutil-asked").path
        if let busy {
            try stub("mdutil", """
                if [ -e '\(asked)' ]; then printf '/:\\n\\t%s\\n' '\(indexing)'
                else : > '\(asked)'; printf '/:\\n\\t%s\\n' '\(busy)'; fi
                """)
        } else {
            try stub("mdutil", "printf '/:\\n\\t%s\\n' '\(indexing)'")
        }
        let found = other ? planted.path : applications.appendingPathComponent("Seat Gauge.app").path
        let deleted = base.appendingPathComponent("deleted/Seat Gauge.app").path
        try stub("mdfind", "printf '%s\\n' '\(found)'" + (gone ? "; printf '%s\\n' '\(deleted)'" : ""))
        let swap: String
        switch swapped {
        case .nothing: swap = ""
        case .relativeLink:
            swap = "; rm -rf '\(dest.path)'; mkdir -p '\(applications.path)/other-app'; printf kept > '\(applications.path)/other-app/marker-other'; ln -s other-app '\(dest.path)'"
        case .foreign, .ours:
            let id = swapped == .ours ? "com.launchastro.seatgauge" : "com.example.other"
            swap = """
                ; rm -rf '\(dest.path)'; mkdir -p '\(dest.path)/Contents'; printf swapped > '\(dest.path)/marker-swapped'
                printf '<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>\(id)</string></dict></plist>' > '\(dest.path)/Contents/Info.plist'
                """
        }
        try stub("pkill", "printf '%s\\n' \"$@\" > '\(base.appendingPathComponent("pkill-args").path)'" + swap)
        try stub("open", "exit 0")
        // The retries' pauses, so a case does not wait them out.
        try stub("sleep", "exit 0")
        if copyFails {
            try stub("ditto", """
                for a in "$@"; do case "$a" in */.seat-gauge-install.*) exit 1 ;; esac; done
                exec /usr/bin/ditto "$@"
                """)
        }
        // The script's renames go through perl, so the stub fails the one a
        // case names and passes every other to the real one.
        if asideFails || swapFails || raced {
            try stub("perl", """
                from="$3"; to="$4"
                case "$to" in */old/'Seat Gauge.app') \(asideFails ? "exit 1" : ":") ;; esac
                case "$from" in */old/*) ;; */.seat-gauge-install.*/'Seat Gauge.app') \(swapFails ? "exit 1" : ":") ;; esac
                /usr/bin/perl "$@" || exit 1
                case "$to" in */old/'Seat Gauge.app') \(raced ? "mkdir -p \"$from/Contents\"; printf other > \"$from/marker-other\"" : ":") ;; esac
                """)
        }
        // A foreign app put in place of `$1`, the moved-aside copy, which itself
        // goes beside it, so the case can tell which one survived.
        let foreign = """
            mv "$target" "$target-moved"; mkdir -p "$target/Contents"; printf swapped > "$target/marker-swapped"
            printf '<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.other</string></dict></plist>' > "$target/Contents/Info.plist"
            """
        switch late {
        case .nothing: break
        case .atDelete:
            try stub("perl", """
                case "$1" in -MFile::Path*) target="$4"
                \(foreign) ;; esac
                exec /usr/bin/perl "$@"
                """)
        case .atRmdir:
            try stub("rmdir", """
                case "$1" in */old/'Seat Gauge.app') target="$1"
                \(foreign) ;; esac
                exec /bin/rmdir "$@"
                """)
        }
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
    enum Prior { case nothing, ours, foreign, bare, link }
    enum Swapped { case nothing, foreign, ours, relativeLink }
    enum Late { case nothing, atDelete, atRmdir }

    /// A staging folder the script left in the applications root.
    static func staged(_ ran: Ran) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: ran.applications.path)) ?? [])
            .filter { $0.hasPrefix(".seat-gauge-install.") }
    }
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

    // MARK: - The first run after a build (#20)

    @Test("proof: an index that answers oddly for a moment after a build still installs on the first run")
    func aBusyIndexInstallsOnTheFirstRun() throws {
        let ran = try Self.install(busy: "Error: unknown indexing state.")
        defer { try? FileManager.default.removeItem(at: ran.applications.deletingLastPathComponent()) }
        #expect(ran.status == 0, "\(ran.out)")
        #expect(ran.trace.filter { $0 == "mdutil" }.count == 2)
        #expect(Self.exists(ran.installed.appendingPathComponent("Contents/MacOS/SeatGauge")))
    }

    @Test("proof: a copy the index still lists but that is gone from disk is passed over")
    func aCopyGoneFromDiskIsPassedOver() throws {
        let ran = try Self.install(gone: true)
        defer { try? FileManager.default.removeItem(at: ran.applications.deletingLastPathComponent()) }
        #expect(ran.status == 0, "\(ran.out)")
        #expect(Self.exists(ran.installed.appendingPathComponent("Contents/MacOS/SeatGauge")))

        // A real second copy beside the stale entry is still a refusal.
        let both = try Self.install(other: true, gone: true)
        defer { try? FileManager.default.removeItem(at: both.applications.deletingLastPathComponent()) }
        #expect(both.status != 0)
        #expect(both.out.contains(both.planted.path))
        #expect(!both.out.contains("deleted/Seat Gauge.app"))
        #expect(!Self.exists(both.installed))
    }

    // MARK: - Replacing the installed copy

    @Test("proof: the copy already installed is replaced, and no staging folder is left")
    func replacesTheInstalledCopy() throws {
        let ran = try Self.install(prior: .ours)
        defer { try? FileManager.default.removeItem(at: ran.applications.deletingLastPathComponent()) }
        #expect(ran.status == 0, "\(ran.out)")
        #expect(!Self.exists(ran.installed.appendingPathComponent("marker")))
        #expect(Self.exists(ran.installed.appendingPathComponent("Contents/MacOS/SeatGauge")))
        #expect(Self.staged(ran).isEmpty)
    }

    @Test("proof: anything at the destination that is not Seat Gauge is a refusal, and it is left as it was",
          arguments: [Prior.foreign, .bare, .link])
    func somethingElseAtTheDestinationIsARefusal(prior: Prior) throws {
        let ran = try Self.install(prior: prior)
        defer { try? FileManager.default.removeItem(at: ran.applications.deletingLastPathComponent()) }
        #expect(ran.status != 0)
        #expect(ran.out.contains("is not Seat Gauge"), "\(ran.out)")
        #expect(ran.out.contains("Nothing has been removed"))
        #expect(Self.exists(ran.installed.appendingPathComponent("marker")))
        #expect(Self.exists(ran.source))
        #expect(!ran.trace.contains("pkill"))
        #expect(Self.staged(ran).isEmpty)
    }

    @Test("proof: a copy that fails partway leaves the installed app where it was, still running")
    func aFailedCopyKeepsTheOldApp() throws {
        let ran = try Self.install(prior: .ours, copyFails: true)
        defer { try? FileManager.default.removeItem(at: ran.applications.deletingLastPathComponent()) }
        #expect(ran.status != 0)
        #expect(ran.out.contains("Nothing has been removed"), "\(ran.out)")
        #expect(Self.exists(ran.installed.appendingPathComponent("marker")))
        #expect(Self.exists(ran.source))
        #expect(!ran.trace.contains("pkill"))
        #expect(Self.staged(ran).isEmpty)
    }

    @Test("proof: a new copy that cannot be put in place puts the old one back")
    func aFailedSwapPutsTheOldAppBack() throws {
        let ran = try Self.install(prior: .ours, swapFails: true)
        defer { try? FileManager.default.removeItem(at: ran.applications.deletingLastPathComponent()) }
        #expect(ran.status != 0)
        #expect(ran.out.contains("is back in"), "\(ran.out)")
        #expect(Self.exists(ran.installed.appendingPathComponent("marker")))
        #expect(!ran.trace.contains("open"))
        #expect(Self.staged(ran).isEmpty)
    }

    @Test("proof: an installed copy that cannot be moved aside stays put, and no staged copy is left")
    func aFailedMoveAsideLeavesNoSecondCopy() throws {
        let ran = try Self.install(prior: .ours, asideFails: true)
        defer { try? FileManager.default.removeItem(at: ran.applications.deletingLastPathComponent()) }
        #expect(ran.status != 0)
        #expect(ran.out.contains("could not be moved aside"), "\(ran.out)")
        #expect(Self.exists(ran.installed.appendingPathComponent("marker")))
        #expect(Self.staged(ran).isEmpty)
    }

    @Test("proof: a copy another install put in place meanwhile is never nested into, and only the old copy is kept aside")
    func aRacedDestinationIsNotNestedInto() throws {
        let ran = try Self.install(prior: .ours, raced: true)
        defer { try? FileManager.default.removeItem(at: ran.applications.deletingLastPathComponent()) }
        #expect(ran.status != 0)
        #expect(!Self.exists(ran.installed.appendingPathComponent("Seat Gauge.app")))
        #expect(Self.exists(ran.installed.appendingPathComponent("marker-other")))
        // The old copy is kept and said where; the new staged one is gone.
        let staged = Self.staged(ran)
        #expect(staged.count == 1)
        let stage = ran.applications.appendingPathComponent(staged.first ?? "")
        #expect(Self.exists(stage.appendingPathComponent("old/Seat Gauge.app/marker")))
        #expect(!Self.exists(stage.appendingPathComponent("Seat Gauge.app")))
        #expect(ran.out.contains(stage.appendingPathComponent("old/Seat Gauge.app").path), "\(ran.out)")
    }

    @Test("proof: an app put at the destination after the check is never deleted: it is left aside, and said where (#114)",
          arguments: [(Prior.ours, Swapped.foreign), (.ours, .ours), (.nothing, .foreign)])
    func aSwappedInAppIsLeftAside(prior: Prior, swapped: Swapped) throws {
        let ran = try Self.install(prior: prior, swapped: swapped)
        defer { try? FileManager.default.removeItem(at: ran.applications.deletingLastPathComponent()) }
        #expect(ran.status == 0, "\(ran.out)")
        #expect(Self.exists(ran.installed.appendingPathComponent("Contents/MacOS/SeatGauge")))
        let staged = Self.staged(ran)
        #expect(staged.count == 1)
        let aside = ran.applications.appendingPathComponent(staged.first ?? "").appendingPathComponent("old/Seat Gauge.app")
        #expect(Self.exists(aside.appendingPathComponent("marker-swapped")))
        #expect(ran.out.contains("left at \(aside.path)"), "\(ran.out)")
    }

    @Test("Sol proof, criterion 2: a relative link swapped in, dangling once moved aside, is kept and named, and its target is untouched")
    func aSwappedInRelativeLinkIsKept() throws {
        let ran = try Self.install(prior: .ours, swapped: .relativeLink)
        defer { try? FileManager.default.removeItem(at: ran.applications.deletingLastPathComponent()) }
        #expect(ran.status == 0, "\(ran.out)")
        let staged = Self.staged(ran)
        #expect(staged.count == 1)
        let aside = ran.applications.appendingPathComponent(staged.first ?? "").appendingPathComponent("old/Seat Gauge.app")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: aside.path)) == "other-app")
        #expect(ran.out.contains("left at \(aside.path)"), "\(ran.out)")
        #expect(Self.exists(ran.applications.appendingPathComponent("other-app/marker-other")))
    }

    @Test("Sol proof, criterion 1: a foreign app swapped in for the moved-aside copy at the moment it is deleted is kept and named",
          arguments: [Late.atDelete, .atRmdir])
    func aSwapAtTheDeleteIsKept(late: Late) throws {
        let ran = try Self.install(prior: .ours, late: late)
        defer { try? FileManager.default.removeItem(at: ran.applications.deletingLastPathComponent()) }
        #expect(ran.status == 0, "\(ran.out)")
        #expect(Self.exists(ran.installed.appendingPathComponent("Contents/MacOS/SeatGauge")))
        let staged = Self.staged(ran)
        #expect(staged.count == 1)
        let aside = ran.applications.appendingPathComponent(staged.first ?? "").appendingPathComponent("old/Seat Gauge.app")
        #expect(Self.exists(aside.appendingPathComponent("marker-swapped")))
        #expect(ran.out.contains("left at \(aside.path)"), "\(ran.out)")
    }

    @Test("proof: only the installed copy is quit, never a make run build or a path the pattern only looks like")
    func quitsOnlyTheInstalledCopy() throws {
        let ran = try Self.install()
        let base = ran.applications.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(ran.status == 0, "\(ran.out)")
        let arguments = try String(contentsOf: base.appendingPathComponent("pkill-args"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(arguments.first == "-f")
        let pattern = try #require(arguments.last)

        // Three running processes: the installed copy, a dev build in a
        // checkout, and one whose path matches only if a dot were any letter.
        let installed = ran.installed.appendingPathComponent("Contents/MacOS/SeatGauge")
        let dev = base.appendingPathComponent("checkout/dist/Seat Gauge.app/Contents/MacOS/SeatGauge")
        let lookalike = ran.applications.appendingPathComponent("Seat GaugeXapp/Contents/MacOS/SeatGauge")
        var running: [Process] = []
        defer { for process in running { process.terminate() } }
        for executable in [installed, dev, lookalike] {
            try? FileManager.default.removeItem(at: executable)
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
            let process = Process()
            process.executableURL = executable
            process.arguments = ["30"]
            try process.run()
            running.append(process)
        }
        let matched = Self.run("/usr/bin/pgrep", "-f", pattern).out
            .split(separator: "\n").compactMap { Int32($0) }
        #expect(matched == [running[0].processIdentifier])
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
        // No login shell is asked: the case is about teardown, not lookup.
        let quiet = SearchPath(shell: nil, home: NSTemporaryDirectory())
        let session = try RealProcessRunner(searchPath: quiet).launch(ProcessSpec(
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
