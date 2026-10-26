import Foundation

/// A folder on a machine that its own tool rebuilds or downloads again when
/// it is needed, and how much clearing it would give back. Seat Gauge only
/// names it; clearing it is the reader's call, by `clear`.
public struct ClearableFolder: Equatable, Sendable, Encodable {
    /// From the machine's home, as `~/...`, so it reads the same on every machine.
    public let path: String
    public let bytes: Int64
    /// How to clear it safely: the tool's own command where it has one.
    public let clear: String

    public init(path: String, bytes: Int64, clear: String) {
        self.path = path
        self.bytes = bytes
        self.clear = clear
    }

    enum CodingKeys: String, CodingKey { case path, gb, clear }
    public func encode(to encoder: Encoder) throws {
        var keys = encoder.container(keyedBy: CodingKeys.self)
        try keys.encode(path, forKey: .path)
        try keys.encode((Double(bytes) / 1e8).rounded() / 10, forKey: .gb)
        try keys.encode(clear, forKey: .clear)
    }
}

/// One machine's last size pass.
public struct ClearableReport: Equatable, Sendable {
    public let sizedAt: Date
    public let folders: [ClearableFolder]

    public init(sizedAt: Date, folders: [ClearableFolder]) {
        self.sizedAt = sizedAt
        self.folders = folders
    }
}

/// The fixed list of folders worth clearing when a machine runs short of
/// disk, and the shell text that sizes them. Each is a cache or build output
/// its tool makes again on demand. A lane's working copy is not on the list:
/// whether one is left over depends on which lanes are live, which Seat Gauge
/// cannot know.
public enum ClearableFolders {
    public struct Candidate: Equatable, Sendable {
        /// From the home folder.
        public let path: String
        public let clear: String
    }

    public static let candidates: [Candidate] = [
        Candidate(path: "Library/Developer/Xcode/DerivedData", clear: "delete what is inside; Xcode builds it again"),
        Candidate(path: "Library/Developer/CoreSimulator/Caches", clear: "delete what is inside"),
        Candidate(path: "Library/Caches/Homebrew", clear: "delete what is inside; it holds Homebrew's downloads only"),
        Candidate(path: "Library/Caches/pip", clear: "pip cache purge"),
        Candidate(path: ".cache/pip", clear: "pip cache purge"),
        Candidate(path: ".cache/uv", clear: "uv cache clean"),
        Candidate(path: ".npm/_cacache", clear: "npm cache clean --force"),
        Candidate(path: "Library/Caches/pnpm", clear: "delete what is inside"),
        Candidate(path: "Library/pnpm/store", clear: "pnpm store prune"),
        Candidate(path: "Library/Caches/Yarn", clear: "yarn cache clean"),
        Candidate(path: ".bun/install/cache", clear: "bun pm cache rm"),
        Candidate(path: "Library/Caches/node-gyp", clear: "delete what is inside"),
        Candidate(path: "Library/Caches/ms-playwright",
                  clear: "delete browsers no project uses; npx playwright install brings one back"),
        Candidate(path: "Library/Caches/org.swift.swiftpm", clear: "delete what is inside"),
        Candidate(path: "Library/Caches/go-build", clear: "go clean -cache"),
        Candidate(path: "go/pkg/mod", clear: "go clean -modcache"),
        Candidate(path: ".cargo/registry", clear: "delete registry/cache and registry/src; cargo fetches again"),
        Candidate(path: ".gradle/caches", clear: "delete what is inside while no Gradle build runs"),
        Candidate(path: ".cache/huggingface", clear: "hf cache delete, for models no project uses"),
        Candidate(path: "Library/Containers/com.docker.docker/Data/vms",
                  clear: "docker builder prune, then docker image prune (without -a, which also removes images no registry has); never delete the folder, it holds Docker's volumes"),
    ]

    /// How often a machine is sized. Sizing big folders takes seconds of disk
    /// work, and caches grow over hours, not seconds.
    public static let every: TimeInterval = 15 * 60
    /// The seconds a pass may run on the machine before it is stopped there.
    public static let limit = 60
    /// Under a tenth of a gigabyte is not worth naming.
    public static let smallest: Int64 = 100_000_000

    /// The lines `sh -s` runs, here or at the far end of ssh. One `du` per
    /// listed folder, so each size is printed as soon as it is known: `du`
    /// holds its lines until it exits, so one `du` stopped over many folders
    /// would lose them all. Each runs at background priority (`taskpolicy -b`
    /// by its full path lowers its CPU and disk, `nice` its CPU) on one disk.
    /// A folder is passed over when it is a link, sits under one, or is on
    /// another disk than the home, since clearing it would free nothing
    /// there. The whole pass stops at `limit` seconds, the `du` then running
    /// killed by a watch that wakes once a second, and says `cut`. Elsewhere
    /// (`remote`), a machine whose own Seat Gauge has a `seats.json` sizes
    /// itself, so it says `own` and sizes nothing. It reads sizes only:
    /// nothing in it can change a file.
    public static func script(limit: Int = limit, remote: Bool = false) -> [String] {
        (remote ? [#"if [ -e "$HOME/Library/Application Support/\#(AppPaths.bundleID)/seats.json" ]; then echo own; exit 0; fi"#] : []) + [
            #"cd "$HOME" || exit 1"#,
            "home=$(pwd -P); disk=$(stat -f %d .)",
            "b=; [ -x /usr/sbin/taskpolicy ] && b='/usr/sbin/taskpolicy -b'",
            "end=$(( $(date +%s) + \(max(1, limit)) ))",
            "for d in " + candidates.map { "'\($0.path)'" }.joined(separator: " ") + "; do",
            #"  [ -d "$d" ] && [ ! -L "$d" ] || continue"#,
            #"  [ "$(cd -P "$d" 2>/dev/null && pwd -P)" = "$home/$d" ] || continue"#,
            #"  [ "$(stat -f %d "$d")" = "$disk" ] || continue"#,
            "  left=$(( end - $(date +%s) ))",
            "  if [ $left -le 0 ]; then echo cut; break; fi",
            #"  $b nice -n 20 du -skx "$d" 2>/dev/null &"#,
            "  p=$!",
            "  ( i=0; while [ $i -lt $left ] && kill -0 $p 2>/dev/null; do sleep 1; i=$((i+1)); done; kill $p 2>/dev/null ) >/dev/null 2>&1 &",
            "  wait $p; r=$?",
            "  if [ $r -gt 128 ]; then echo cut; break; fi",
            "done",
            "echo end",
        ]
    }

    /// Nil unless the answer ends, so a pass cut off on the way changes
    /// nothing; nil too for a machine that sizes itself (`own`). A pass that
    /// reached its time limit keeps the folders it finished. Only a listed
    /// folder, by its exact path, is read; anything else in the answer is
    /// passed over. Largest first.
    public static func parse(_ lines: [String], atLeast: Int64 = smallest) -> [ClearableFolder]? {
        guard lines.last == "end", !lines.contains("own") else { return nil }
        var folders: [ClearableFolder] = []
        for line in lines.dropLast() {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let kilobytes = Int64(parts[0]), kilobytes >= 0,
                  let candidate = candidates.first(where: { $0.path == parts[1] }) else { continue }
            let (bytes, overflow) = kilobytes.multipliedReportingOverflow(by: 1024)
            guard !overflow, bytes >= atLeast else { continue }
            folders.append(ClearableFolder(path: "~/" + candidate.path, bytes: bytes, clear: candidate.clear))
        }
        return folders.sorted { $0.bytes > $1.bytes }
    }
}

/// Runs the size script on one machine, the way the load probe runs: `sh`
/// here, the probe's own kept-open ssh connection elsewhere.
public struct ClearableSizer: Sendable {
    let runner: any ProcessRunning
    let environment: [String: String]
    /// Past the script's own limit, so the far end stops `du` itself first.
    public static let timeout: Duration = .seconds(ClearableFolders.limit + 30)

    public init(runner: any ProcessRunning,
                environment: [String: String] = ChildEnvironment.make(
                    from: ProcessInfo.processInfo.environment, keeping: ["SSH_AUTH_SOCK"])) {
        self.runner = runner
        self.environment = environment
    }

    public static func spec(_ machine: Machine, environment: [String: String]) -> ProcessSpec {
        let probe = MachineProber.spec(machine, environment: environment)
        return ProcessSpec(executable: probe.executable, arguments: probe.arguments,
                           environment: environment, timeout: timeout)
    }

    /// Nil when the pass failed or was cut off.
    public func size(_ machine: Machine) async -> [ClearableFolder]? {
        var lines: [String] = []
        do {
            let session = try runner.launch(Self.spec(machine, environment: environment))
            for line in ClearableFolders.script(remote: machine.ssh != nil) { try session.send(line) }
            session.closeInput()
            for try await line in session.stdoutLines { lines.append(line) }
        } catch {
            return nil
        }
        return ClearableFolders.parse(lines)
    }
}
