import Foundation

/// A computer whose load the gauge watches: this Mac, or another Mac reached
/// over ssh. Listed under `machines` in `seats.json`; with none listed, this
/// Mac alone.
public struct Machine: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    /// An ssh destination, such as a host name or an alias in `~/.ssh/config`.
    /// Nil is this Mac, read without ssh.
    public let ssh: String?

    public init(id: String, label: String, ssh: String? = nil) {
        self.id = id
        self.label = label
        self.ssh = ssh
    }

    public static let here = Machine(id: "this-mac", label: "This Mac")

    /// `read` run on every machine at once, so a slow ssh never holds up
    /// another machine's answer, the answers keyed by machine id.
    static func each<T: Sendable>(_ machines: [Machine],
                                  _ read: @escaping @Sendable (Machine) async -> Result<T, ProcessFailure>)
        async -> [String: Result<T, ProcessFailure>] {
        await withTaskGroup(of: (String, Result<T, ProcessFailure>).self) { group in
            for machine in machines { group.addTask { (machine.id, await read(machine)) } }
            var all: [String: Result<T, ProcessFailure>] = [:]
            for await (id, result) in group { all[id] = result }
            return all
        }
    }
}

/// How many agents a machine's herdr has, by what each is doing. An agent
/// running outside herdr is not counted.
public struct AgentCount: Equatable, Sendable, Codable {
    public let working: Int
    /// Stopped on a question or a permission prompt.
    public let blocked: Int
    /// Idle, done or unknown: open but not working.
    public let idle: Int

    public init(working: Int, blocked: Int, idle: Int) {
        self.working = working
        self.blocked = blocked
        self.idle = idle
    }

    public var total: Int { working + blocked + idle }
}

/// Whether a machine can take more work, from its CPU, memory and free disk.
public enum Room: String, Equatable, Sendable, Codable {
    case free, busy, full
}

/// One read of one machine.
public struct MachineReading: Equatable, Sendable, Codable {
    public let takenAt: Date
    /// The share of the CPU busy over a one-second sample, in percent.
    public let cpuUsed: Int
    /// Load averages over 1, 5 and 15 minutes.
    public let load: [Double]
    public let cores: Int
    /// Memory in use by macOS's own pressure measure, in percent.
    public let ramUsed: Int
    public let ramBytes: Int64
    public let diskUsed: Int
    public let diskFreeBytes: Int64
    /// Nil when the machine has no herdr, or herdr did not answer.
    public let agents: AgentCount?

    public init(takenAt: Date, cpuUsed: Int, load: [Double], cores: Int, ramUsed: Int, ramBytes: Int64,
                diskUsed: Int, diskFreeBytes: Int64, agents: AgentCount?) {
        self.takenAt = takenAt
        self.cpuUsed = cpuUsed
        self.load = load
        self.cores = cores
        self.ramUsed = ramUsed
        self.ramBytes = ramBytes
        self.diskUsed = diskUsed
        self.diskFreeBytes = diskFreeBytes
        self.agents = agents
    }

    public var loadPerCore: Double { cores > 0 ? (load.first ?? 0) / Double(cores) : 0 }
}

/// Which way a figure is heading: the last 30 seconds against the 30 before.
public enum Trend: String, Equatable, Sendable, Codable {
    case rising, steady, falling
}

/// A machine as an agent should judge it: CPU and memory averaged over the
/// last 30 seconds, so one busy second does not read as a busy machine,
/// which way each is heading, how fast the disk is filling, and the room
/// verdict with the reasons for it.
public struct MachineSummary: Equatable, Sendable {
    public let cpu: Int
    public let cpuTrend: Trend?
    public let ram: Int
    public let ramTrend: Trend?
    /// Disk space gained (positive) or lost over the chart's ten minutes,
    /// in gigabytes. Nil until there are two reads to compare.
    public let diskChangeGB: Double?
    public let room: Room
    /// Each line that set the room, such as "load 2.1 per core".
    public let why: [String]

    /// How long the average reaches back.
    public static let window: TimeInterval = 30
    /// A trend moves at ten points between one window and the last.
    static let shift = 10.0

    /// `samples` are the machine's chart points, oldest first, the reading's
    /// own among them. With none in the window, the reading alone stands.
    public init(reading: MachineReading, samples: [LoadSample], now: Date) {
        func average(_ value: KeyPath<LoadSample, Int>, from: TimeInterval, to: TimeInterval) -> Double? {
            let inside = samples.filter {
                let age = now.timeIntervalSince($0.at)
                return age >= from && age < to
            }
            guard !inside.isEmpty else { return nil }
            return Double(inside.map { $0[keyPath: value] }.reduce(0, +)) / Double(inside.count)
        }
        func trend(_ value: KeyPath<LoadSample, Int>) -> Trend? {
            guard let last = average(value, from: 0, to: Self.window),
                  let before = average(value, from: Self.window, to: 2 * Self.window) else { return nil }
            return last - before >= Self.shift ? .rising : before - last >= Self.shift ? .falling : .steady
        }
        cpu = average(\.cpu, from: 0, to: Self.window).map { Int($0.rounded()) } ?? reading.cpuUsed
        ram = average(\.ram, from: 0, to: Self.window).map { Int($0.rounded()) } ?? reading.ramUsed
        cpuTrend = trend(\.cpu)
        ramTrend = trend(\.ram)
        if let first = samples.first, first.at < reading.takenAt {
            diskChangeGB = ((Double(reading.diskFreeBytes) - Double(first.diskFree)) / 1e8).rounded() / 10
        } else {
            diskChangeGB = nil
        }
        (room, why) = Self.room(cpu: cpu, ram: ram, loadPerCore: reading.loadPerCore,
                                diskFreeGB: Double(reading.diskFreeBytes) / 1e9)
    }

    /// CPU and memory on the seat meters' lines, `MeterLines`. Load per
    /// core busy from 2 and full from 3, about the 50 on 16 cores the build
    /// method allows. Disk by gigabytes left, since a percent of a big disk
    /// can still be plenty.
    static func room(cpu: Int, ram: Int, loadPerCore: Double, diskFreeGB: Double) -> (Room, [String]) {
        let checks: [(busy: Bool, full: Bool, text: String)] = [
            (cpu >= MeterLines.warning, cpu >= MeterLines.danger, "CPU \(cpu)% over 30 s"),
            (ram >= MeterLines.warning, ram >= MeterLines.danger, "memory \(ram)% over 30 s"),
            (loadPerCore >= 2, loadPerCore >= 3, String(format: "load %.1f per core", loadPerCore)),
            (diskFreeGB < 25, diskFreeGB < 10, "\(Int(diskFreeGB.rounded())) GB disk left"),
        ]
        let full = checks.filter(\.full)
        if !full.isEmpty { return (.full, full.map(\.text)) }
        let busy = checks.filter(\.busy)
        return busy.isEmpty ? (.free, []) : (.busy, busy.map(\.text))
    }
}

/// The shell text one read runs, on this Mac or at the far end of ssh, and
/// the reading of what it prints. Built-in macOS commands only, plus herdr
/// when it is there, so nothing has to be installed on the other machine.
public enum MachineProbe {
    public static let script = [
        #"echo "cores $(sysctl -n hw.ncpu)""#,
        #"echo "memsize $(sysctl -n hw.memsize)""#,
        #"echo "memfree $(sysctl -n kern.memorystatus_level)""#,
        #"echo "load $(sysctl -n vm.loadavg)""#,
        #"d=/System/Volumes/Data; [ -d "$d" ] || d=/"#,
        #"echo "disk $(df -k "$d" | tail -1)""#,
        #"echo "cpu $(top -l 2 -n 0 -s 1 | grep 'CPU usage' | tail -1)""#,
        #"h=$(command -v herdr || echo "$HOME/.local/bin/herdr")"#,
        #"[ -x "$h" ] && echo "agents $("$h" agent list 2>/dev/null | tr -d '\n')""#,
        #"echo end"#,
    ]

    /// Nil unless every figure but the agents is there, so a cut-off read
    /// never draws as an idle machine. Nil too when a figure is outside what
    /// a Mac can report: the answer may come from another machine, and an
    /// absurd number there would otherwise trap in the arithmetic below and
    /// end the app.
    public static func parse(_ lines: [String], at now: Date) -> MachineReading? {
        var fields: [String: String] = [:]
        for line in lines {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard let key = parts.first else { continue }
            fields[String(key)] = parts.count > 1 ? String(parts[1]) : ""
        }
        guard fields["end"] != nil,
              let cores = fields["cores"].flatMap({ Int($0) }), cores > 0,
              let ramBytes = fields["memsize"].flatMap({ Int64($0) }), ramBytes >= 0,
              let memoryFree = fields["memfree"].flatMap({ Int($0) }), (0 ... 100).contains(memoryFree),
              let load = fields["load"].map(loads), load.count == 3,
              load.allSatisfy({ (0 ... highestLoad).contains($0) }),
              let disk = fields["disk"].flatMap(disk),
              let idle = fields["cpu"].flatMap(cpuIdle), (0 ... 100).contains(idle)
        else { return nil }
        return MachineReading(takenAt: now, cpuUsed: clamp(100 - idle), load: load, cores: cores,
                              ramUsed: clamp(100 - Double(memoryFree)), ramBytes: ramBytes,
                              diskUsed: disk.used, diskFreeBytes: disk.free,
                              agents: fields["agents"].flatMap(agents))
    }

    /// A load average no Mac reaches, a thousand times the busiest, and
    /// still small enough that the LOAD tab's whole-number text cannot trap.
    static let highestLoad = 100_000.0

    /// `{ 1.20 2.30 3.40 }`, as `vm.loadavg` prints it.
    static func loads(_ text: String) -> [Double] {
        text.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "}" }).compactMap { Double($0) }
    }

    /// One `df -k` row: the device, then 1K blocks, used and available. The
    /// percent is of the blocks, as `df`'s own capacity column works it.
    static func disk(_ row: String) -> (used: Int, free: Int64)? {
        let columns = row.split(separator: " ")
        guard columns.count >= 4, let blocks = Double(columns[1]), let available = Int64(columns[3]),
              blocks >= 1, blocks.isFinite, available >= 0 else { return nil }
        let (bytes, overflow) = available.multipliedReportingOverflow(by: 1024)
        guard !overflow else { return nil }
        return (clamp(100 - Double(available) / blocks * 100), bytes)
    }

    /// `CPU usage: 12.5% user, 7.5% sys, 80.0% idle`.
    static func cpuIdle(_ line: String) -> Double? {
        guard let idle = line.range(of: "% idle") else { return nil }
        let before = line[..<idle.lowerBound]
        let number = before.reversed().prefix { ("0" ... "9").contains($0) || $0 == "." }
        // The figure is a word of its own, so `-20.0`, `1e100` or `x5` before
        // the `%` is no idle figure rather than the digits at its end.
        guard let start = before.dropLast(number.count).last, start == " " else { return nil }
        return Double(String(number.reversed()))
    }

    /// herdr's `agent list` reply. Anything that is not that reply is no count.
    static func agents(_ json: String) -> AgentCount? {
        guard let reply = JSON.object(json), let result = reply["result"] as? [String: Any],
              let agents = result["agents"] as? [[String: Any]] else { return nil }
        let states = agents.map { JSON.text($0["agent_status"]) ?? "" }
        let working = states.filter { $0 == "working" }.count
        let blocked = states.filter { $0 == "blocked" }.count
        return AgentCount(working: working, blocked: blocked, idle: states.count - working - blocked)
    }

    /// Held to 0 to 100 before it becomes an Int, which traps on anything
    /// past `Int`'s range; a non-finite percent is none.
    static func clamp(_ percent: Double) -> Int {
        percent.isFinite ? Int(min(100, max(0, percent)).rounded()) : 0
    }
}

/// One point on a machine's load chart.
public struct LoadSample: Equatable, Sendable {
    public let at: Date
    public let cpu: Int
    public let ram: Int
    public let diskFree: Int64

    public init(at: Date, cpu: Int, ram: Int, diskFree: Int64 = 0) {
        self.at = at
        self.cpu = cpu
        self.ram = ram
        self.diskFree = diskFree
    }

    /// How far back the chart reaches. Held in memory only, so a relaunch
    /// starts it again.
    public static let span: TimeInterval = 600
}

/// A machine as the gauge last found it.
public enum MachineState: Equatable, Sendable {
    case live(MachineReading)
    /// The last read failed. The reading before it, if any, stays.
    case unreachable(reason: String, last: MachineReading?)

    public var reading: MachineReading? {
        switch self {
        case let .live(reading): reading
        case let .unreachable(_, last): last
        }
    }
}

/// Reads machines through `ProcessRunning`: `/bin/sh` here, `ssh` there,
/// with the probe on standard input either way.
public struct MachineProber: Sendable {
    let runner: any ProcessRunning
    let environment: [String: String]
    public static let timeout: Duration = .seconds(20)

    /// This Mac's home, where the Log probe looks for herdr.
    let home: URL

    public init(runner: any ProcessRunning,
                environment: [String: String] = ChildEnvironment.make(
                    from: ProcessInfo.processInfo.environment, keeping: ["SSH_AUTH_SOCK"]),
                home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.runner = runner
        self.environment = environment
        self.home = home
    }

    /// The command for one machine. Batch mode, so a missing key fails at
    /// once rather than waiting on a password prompt nobody can see. One
    /// connection per machine is kept open between reads, so a read every
    /// few seconds is a new channel on it rather than a new sign-in.
    public static func spec(_ machine: Machine, environment: [String: String]) -> ProcessSpec {
        guard let host = machine.ssh else {
            return ProcessSpec(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-s"],
                               environment: environment, timeout: timeout)
        }
        return ProcessSpec(executable: URL(fileURLWithPath: "/usr/bin/ssh"),
                           arguments: ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                                       "-o", "ControlMaster=auto", "-o", "ControlPath=~/.ssh/seatgauge-%C",
                                       "-o", "ControlPersist=120",
                                       "--", host, "/bin/sh", "-s"],
                           environment: environment, timeout: timeout)
    }

    public func read(_ machine: Machine, now: @Sendable () -> Date = Date.init) async -> Result<MachineReading, ProcessFailure> {
        var lines: [String] = []
        do {
            let session = try runner.launch(Self.spec(machine, environment: environment))
            for line in MachineProbe.script { try session.send(line) }
            session.closeInput()
            for try await line in session.stdoutLines { lines.append(line) }
        } catch let failure as ProcessFailure {
            return .failure(failure.reason.hasPrefix("the seat timed out")
                ? ProcessFailure("no answer within \(Int(Self.timeout.seconds)) s") : failure)
        } catch {
            return .failure(ProcessFailure("\(error)"))
        }
        if let reading = MachineProbe.parse(lines, at: now()) { return .success(reading) }
        return .failure(ProcessFailure(lines.isEmpty
            ? (machine.ssh.map { "could not reach \($0) over ssh" } ?? "the probe printed nothing")
            : "the probe's answer was cut short"))
    }
}

/// Copies `machines.json` to each other listed machine, into the same
/// Seat Gauge folder there, so an agent on that machine reads the file at the
/// same path as one on this Mac. It rides the probe's kept-open ssh
/// connection, runs only `sh` there, and writes that one file and nothing
/// else. A machine with its own `seats.json` runs its own app, which writes
/// its own file, so that file is left alone.
public struct MachineShare: Sendable {
    let runner: any ProcessRunning
    let environment: [String: String]
    let identifier: String

    /// At most one copy a minute to each machine: a five-minute check needs
    /// no more, and the file is rewritten every few seconds.
    public static let every: TimeInterval = 60
    public static let timeout: Duration = .seconds(10)
    /// Ends the copy's base64 text. The underscore is not in base64's
    /// alphabet, so no line of the file can end it early.
    public static let marker = "SEATGAUGE_END"

    /// `identifier` names the folder there, as `AppPaths` names this Mac's,
    /// so a `.dev` build never writes into the installed app's folder.
    public init(runner: any ProcessRunning,
                environment: [String: String] = ChildEnvironment.make(
                    from: ProcessInfo.processInfo.environment, keeping: ["SSH_AUTH_SOCK"]),
                identifier: String = AppPaths.identifier(running: Bundle.main.bundleIdentifier)) {
        self.runner = runner
        self.environment = environment
        self.identifier = identifier
    }

    /// The probe's own ssh command, with a shorter deadline, so a copy never
    /// holds up the next read for long.
    public static func spec(_ machine: Machine, environment: [String: String]) -> ProcessSpec {
        let probe = MachineProber.spec(machine, environment: environment)
        return ProcessSpec(executable: probe.executable, arguments: probe.arguments,
                           environment: environment, timeout: timeout)
    }

    /// The lines `sh -s` runs there, one `{ }` block, so `sh` reads all of it
    /// before it runs any: a copy cut off on the way runs nothing. The file
    /// goes as base64 inside a quoted here-document, so nothing in it is ever
    /// read as shell. It lands in a private temporary file beside the copy,
    /// then one rename replaces the copy, so a reader never sees half a file
    /// and a link in its place, to a file or a folder, is replaced rather than
    /// written through (`mv -h`). A folder of that name is left alone. A
    /// temporary file an earlier copy left, killed between the two, goes
    /// once it is a minute old. An identifier that is not this app's is the
    /// app's own, so nothing outside the folder is ever named.
    public static func script(_ data: Data, identifier: String) -> [String] {
        let ours = AppPaths.identifier(running: identifier) == identifier
            && identifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
        let folder = ours ? identifier : AppPaths.bundleID
        return [
            "{",
            #"d="$HOME/Library/Application Support/\#(folder)""#,
            #"if [ -e "$d/seats.json" ]; then echo kept; exit 0; fi"#,
            #"if [ -d "$d/machines.json" ] && [ ! -L "$d/machines.json" ]; then exit 1; fi"#,
            "umask 077",
            #"mkdir -p "$d" || exit 1"#,
            #"find "$d" -maxdepth 1 -name '.machines.json.*' -mmin +1 -delete 2>/dev/null"#,
            #"t=$(mktemp "$d/.machines.json.XXXXXX") || exit 1"#,
            #"if base64 -D > "$t" <<'\#(marker)'"#,
        ] + data.base64EncodedString(options: .lineLength76Characters).components(separatedBy: "\r\n") + [
            marker,
            #"then mv -f -h "$t" "$d/machines.json" && echo copied; fi"#,
            #"rm -f "$t""#,
            "}",
        ]
    }

    /// One copy to one machine; true when it landed.
    public func copy(_ data: Data, to machine: Machine) async -> Bool {
        guard machine.ssh != nil else { return false }
        var printed: [String] = []
        do {
            let session = try runner.launch(Self.spec(machine, environment: environment))
            for line in Self.script(data, identifier: identifier) { try session.send(line) }
            session.closeInput()
            for try await line in session.stdoutLines { printed.append(line) }
        } catch {
            return false
        }
        return printed.last == "copied"
    }
}

/// `machines.json`: each machine's load and agents as an agent reads them,
/// written after every read. Figures only; which machine to use is the
/// reader's call.
public struct MachinesFile: Encodable, Equatable, Sendable {
    public let updated: String
    public let machines: [Row]

    public struct Row: Encodable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let reachable: Bool
        public let stale: Bool
        public let problem: String?
        public let readAt: String?
        public let room: Room?
        public let why: [String]
        public let cpu: CPU?
        public let ram: Memory?
        public let disk: Disk?
        public let agents: AgentCount?

        enum CodingKeys: String, CodingKey {
            case id, label, reachable, stale, problem, readAt = "read_at", room, why, cpu, ram, disk, agents
        }

        // Every key written, `null` included, so a reader never has to ask
        // whether a missing key means none.
        public func encode(to encoder: Encoder) throws {
            var keys = encoder.container(keyedBy: CodingKeys.self)
            try keys.encode(id, forKey: .id)
            try keys.encode(label, forKey: .label)
            try keys.encode(reachable, forKey: .reachable)
            try keys.encode(stale, forKey: .stale)
            try keys.encode(problem, forKey: .problem)
            try keys.encode(readAt, forKey: .readAt)
            try keys.encode(room, forKey: .room)
            try keys.encode(why, forKey: .why)
            try keys.encode(cpu, forKey: .cpu)
            try keys.encode(ram, forKey: .ram)
            try keys.encode(disk, forKey: .disk)
            try keys.encode(agents.map(Agents.init), forKey: .agents)
        }
    }

    /// `used` is the 30-second average and `now` the last one-second sample.
    public struct CPU: Encodable, Equatable, Sendable {
        public let used: Int
        public let now: Int
        public let trend: Trend?
        public let load: [Double]
        public let cores: Int
        public let loadPerCore: Double
        enum CodingKeys: String, CodingKey { case used, now, trend, load, cores, loadPerCore = "load_per_core" }
        public func encode(to encoder: Encoder) throws {
            var keys = encoder.container(keyedBy: CodingKeys.self)
            try keys.encode(used, forKey: .used)
            try keys.encode(now, forKey: .now)
            try keys.encode(trend, forKey: .trend)
            try keys.encode(load, forKey: .load)
            try keys.encode(cores, forKey: .cores)
            try keys.encode(loadPerCore, forKey: .loadPerCore)
        }
    }

    public struct Memory: Encodable, Equatable, Sendable {
        public let used: Int
        public let now: Int
        public let trend: Trend?
        public let totalGB: Int
        enum CodingKeys: String, CodingKey { case used, now, trend, totalGB = "total_gb" }
        public func encode(to encoder: Encoder) throws {
            var keys = encoder.container(keyedBy: CodingKeys.self)
            try keys.encode(used, forKey: .used)
            try keys.encode(now, forKey: .now)
            try keys.encode(trend, forKey: .trend)
            try keys.encode(totalGB, forKey: .totalGB)
        }
    }

    public struct Disk: Encodable, Equatable, Sendable {
        public let used: Int
        public let freeGB: Int
        /// Gigabytes gained or lost over the last ten minutes; negative is filling.
        public let change10mGB: Double?
        /// The listed folders worth clearing, largest first, as last sized,
        /// and when; nil until the first size pass lands.
        public let clearable: [ClearableFolder]?
        public let clearableAt: String?
        enum CodingKeys: String, CodingKey {
            case used, freeGB = "free_gb", change10mGB = "change_10m_gb", clearable, clearableAt = "clearable_at"
        }
        public func encode(to encoder: Encoder) throws {
            var keys = encoder.container(keyedBy: CodingKeys.self)
            try keys.encode(used, forKey: .used)
            try keys.encode(freeGB, forKey: .freeGB)
            try keys.encode(change10mGB, forKey: .change10mGB)
            try keys.encode(clearable, forKey: .clearable)
            try keys.encode(clearableAt, forKey: .clearableAt)
        }
    }

    struct Agents: Encodable {
        let working, blocked, idle, total: Int
        init(_ count: AgentCount) {
            (working, blocked, idle, total) = (count.working, count.blocked, count.idle, count.total)
        }
    }

    /// A machine is stale when its last read failed or its figures are older
    /// than three read intervals.
    public init(machines: [Machine], states: [String: MachineState], samples: [String: [LoadSample]] = [:],
                clearable: [String: ClearableReport] = [:],
                seconds: Int, now: Date, timeZone: TimeZone = .current) {
        let dates = ISO8601DateFormatter()
        dates.timeZone = timeZone
        updated = dates.string(from: now)
        let oldest = now.addingTimeInterval(-3 * Double(seconds))
        self.machines = machines.map { machine in
            let state = states[machine.id]
            let reading = state?.reading
            var problem: String?
            if case let .unreachable(reason, _) = state { problem = reason }
            let fresh = state.map { if case .live = $0 { true } else { false } } ?? false
            let summary = reading.map { MachineSummary(reading: $0, samples: samples[machine.id] ?? [], now: now) }
            var cpu: CPU?, ram: Memory?, disk: Disk?
            if let reading, let summary {
                cpu = CPU(used: summary.cpu, now: reading.cpuUsed, trend: summary.cpuTrend,
                          load: reading.load.map { ($0 * 10).rounded() / 10 }, cores: reading.cores,
                          loadPerCore: (reading.loadPerCore * 10).rounded() / 10)
                ram = Memory(used: summary.ram, now: reading.ramUsed, trend: summary.ramTrend,
                             totalGB: Int((Double(reading.ramBytes) / 1_073_741_824).rounded()))
                let sized = clearable[machine.id]
                disk = Disk(used: reading.diskUsed, freeGB: Int((Double(reading.diskFreeBytes) / 1e9).rounded()),
                            change10mGB: summary.diskChangeGB, clearable: sized?.folders,
                            clearableAt: sized.map { dates.string(from: $0.sizedAt) })
            }
            return Row(id: machine.id, label: machine.label, reachable: fresh, stale: !fresh || (reading?.takenAt ?? .distantPast) < oldest,
                       problem: problem, readAt: reading.map { dates.string(from: $0.takenAt) },
                       room: summary?.room, why: summary?.why ?? [], cpu: cpu, ram: ram, disk: disk,
                       agents: reading?.agents)
        }
    }

    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static var defaultFile: URL { AppPaths.support.appendingPathComponent("machines.json") }
}

/// The machine loop: every listed machine read at once, the file written,
/// the panel told, then a sleep. Apart from the seat poll, since a machine
/// read is cheap and its figures go old in seconds rather than minutes. It
/// also keeps the last ten minutes of CPU and memory for the hover chart.
public actor MachineMonitor {
    let prober: MachineProber
    let config: @Sendable () async -> Config
    let file: URL
    let activity: PollActivity
    let notify: @Sendable ([Machine], [String: MachineState], [String: [LoadSample]]) -> Void
    let share: MachineShare?
    let sizer: ClearableSizer?
    let now: @Sendable () -> Date
    private var states: [String: MachineState] = [:]
    private var history: [String: [LoadSample]] = [:]
    /// When each machine was last sent a copy, landed or not, so a machine
    /// that refuses one is asked again a minute later rather than every read.
    private var copied: [String: Date] = [:]
    private var copying: Task<Void, Never>?
    /// Each machine's last size pass, when the last one was started, and the
    /// passes still running, so a slow one is never started twice.
    private var clearable: [String: ClearableReport] = [:]
    private var sizeStarted: [String: Date] = [:]
    private var sizing: [String: Task<Void, Never>] = [:]

    /// `share` copies the file to the other machines and `sizer` sizes the
    /// folders worth clearing; nil, as the CLI's one-off read passes, does
    /// neither.
    public init(prober: MachineProber, file: URL = MachinesFile.defaultFile,
                activity: PollActivity = PollActivity(), share: MachineShare? = nil, sizer: ClearableSizer? = nil,
                now: @escaping @Sendable () -> Date = Date.init,
                config: @escaping @Sendable () async -> Config,
                notify: @escaping @Sendable ([Machine], [String: MachineState], [String: [LoadSample]]) -> Void = { _, _, _ in }) {
        self.prober = prober
        self.file = file
        self.activity = activity
        self.share = share
        self.sizer = sizer
        self.now = now
        self.config = config
        self.notify = notify
    }

    public func run() async {
        while !Task.isCancelled {
            let seconds = await config().machineSeconds
            await read()
            try? await Task.sleep(for: .seconds(seconds), tolerance: .seconds(2))
        }
    }

    /// The chart points kept for each machine, oldest first.
    public var samples: [String: [LoadSample]] { history }

    /// One round: each machine in parallel, so a slow ssh never holds up
    /// this Mac's figures.
    @discardableResult
    public func read() async -> [String: MachineState] {
        activity.begin()
        defer { activity.end() }
        let current = await config()
        let prober = self.prober
        let results = await Machine.each(current.machines) { await prober.read($0) }
        var next: [String: MachineState] = [:]
        for machine in current.machines {
            switch results[machine.id] {
            case let .success(reading): next[machine.id] = .live(reading)
            case let .failure(failure):
                next[machine.id] = .unreachable(reason: failure.reason, last: states[machine.id]?.reading)
            case .none: break
            }
        }
        states = next
        let now = self.now()
        var kept: [String: [LoadSample]] = [:]
        for machine in current.machines {
            var samples = (history[machine.id] ?? []).filter { now.timeIntervalSince($0.at) <= LoadSample.span }
            if case let .live(reading) = next[machine.id] {
                samples.append(LoadSample(at: reading.takenAt, cpu: reading.cpuUsed, ram: reading.ramUsed,
                                          diskFree: reading.diskFreeBytes))
            }
            kept[machine.id] = samples
        }
        history = kept
        clearable = clearable.filter { id, _ in current.machines.contains { $0.id == id } }
        let written = MachinesFile(machines: current.machines, states: next, samples: kept, clearable: clearable,
                                   seconds: current.machineSeconds, now: now)
        let data = try? written.data()
        if let data {
            try? PrivateFile.write(data, to: file, makingFolder: true)
        }
        notify(current.machines, next, kept)
        if let share, let data { send(data, share: share, machines: current.machines, states: next, now: now) }
        if let sizer { size(sizer, machines: current.machines, states: next, now: now) }
        return next
    }

    /// Waits for the copies the last read started, and every size pass running.
    public func settle() async {
        await copying?.value
        for task in sizing.values { await task.value }
    }

    /// A size pass on each machine that answered this read and has had none
    /// started for `ClearableFolders.every`, off the read loop. Its folders
    /// land in the write after it ends.
    private func size(_ sizer: ClearableSizer, machines: [Machine], states: [String: MachineState], now: Date) {
        for machine in machines {
            guard case .live = states[machine.id], sizing[machine.id] == nil,
                  sizeStarted[machine.id].map({ now.timeIntervalSince($0) >= ClearableFolders.every }) ?? true
            else { continue }
            sizeStarted[machine.id] = now
            sizing[machine.id] = Task {
                let folders = await sizer.size(machine)
                self.sized(machine.id, folders)
            }
        }
    }

    private func sized(_ id: String, _ folders: [ClearableFolder]?) {
        sizing[id] = nil
        if let folders { clearable[id] = ClearableReport(sizedAt: now(), folders: folders) }
    }

    /// The copy to each machine over ssh that answered this read and has had
    /// none for a minute, all at once, so one slow machine holds up no other,
    /// and off the read loop, so a stalled copy never delays the next read.
    private func send(_ data: Data, share: MachineShare, machines: [Machine], states: [String: MachineState],
                      now: Date) {
        let due = machines.filter { machine in
            guard machine.ssh != nil, case .live = states[machine.id] else { return false }
            return copied[machine.id].map { now.timeIntervalSince($0) >= MachineShare.every } ?? true
        }
        for machine in due { copied[machine.id] = now }
        copied = copied.filter { id, _ in machines.contains { $0.id == id } }
        guard !due.isEmpty else { return }
        copying = Task { _ = await Machine.each(due) { .success(await share.copy(data, to: $0)) } }
    }
}
