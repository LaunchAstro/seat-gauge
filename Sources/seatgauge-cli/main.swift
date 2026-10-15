import Foundation
import SeatGaugeCore

// The app's core, headless. `read` prints every seat's outcome, `record`
// writes one seat's raw reply to a fixture, `watch` runs the panel's own poll
// loop with nothing drawn, and `spend` runs the roll-up once over the real
// transcripts and says what it found. `login` signs one seat in. `machines`
// reads each machine's load once.

/// The seats when there is no `seats.json` to follow: the template's, so the
/// CLI never reads a seat without its own profile.
let templateSeats: [Seat] = (try? ConfigLoader.decode(Data(ConfigLoader.template.utf8)).seats) ?? []

/// One window as the panel will read it: the kind, the count-up percentage and
/// how long until it resets. Seconds are never shown.
func describe(_ window: Window, now: Date) -> String {
    let name = switch window.kind {
    case .fiveHour: "5h"
    case .weekly: "week"
    case .fable: "fable"
    }
    return "\(name) \(window.usedPercent)% resets in \(Countdown.text(until: window.resetsAt, now: now))"
}

func describe(_ state: SeatState, now: Date) -> String {
    switch state {
    case let .live(reading):
        let windows = reading.windows.map { describe($0, now: now) }.joined(separator: ", ")
        return "live    \(windows)"
    case let .dormant(reason):
        return "dormant \(reason)"
    case let .unreadable(reason, last):
        return "stale   \(reason)" + (last == nil ? "" : ", last read held")
    }
}

/// The primer directory has to be there before `claude` is asked to run in it.
func makePrimer() throws {
    try FileManager.default.createDirectory(at: AppPaths.primer, withIntermediateDirectories: true)
}

/// The seats `read`, `record` and `spend` work on: the named file, else the
/// panel's own `seats.json`, else the template's. A file that will not parse is said,
/// not skipped, since a login it declares would silently go unread.
func readSeats(_ path: String?) throws -> [Seat] {
    let file = path.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
        ?? ConfigLoader.defaultFile
    guard path != nil || FileManager.default.fileExists(atPath: file.path) else { return templateSeats }
    return try ConfigLoader(file: file).load().seats
}

/// A seat's fetcher, with its CLI found wherever the user's login shell would.
@Sendable func liveFetcher(_ seat: Seat) -> any SeatFetching {
    seatFetcher(for: seat, runner: RealProcessRunner(searchPath: .loginShell))
}

/// Each seat's plan beside its name, from its own login first. A seat
/// with none says so, and is never called free.
func read(_ path: String?) async throws {
    try makePrimer()
    let started = Date()
    for seat in try readSeats(path) {
        let outcome = await liveFetcher(seat).fetch(seat, now: Date(), last: nil)
        let now = Date()
        let plan = PlanText.shown(for: seat, state: outcome.state) ?? "no plan"
        print(PlanText.column(seat.id.rawValue, width: 8)
              + PlanText.column(plan, width: 10) + " "
              + "\(describe(outcome.state, now: now))"
              + "  (\(String(format: "%.1f", now.timeIntervalSince(started))) s)")
    }
}

func record(_ name: String, from path: String?) async throws {
    let seats = try readSeats(path)
    guard let seat = seats.first(where: { $0.id.rawValue == name }) else {
        throw ProcessFailure("no seat named \(name). Seats: "
                             + seats.map(\.id.rawValue).joined(separator: ", "))
    }
    try makePrimer()
    let outcome = await liveFetcher(seat).fetch(seat, now: Date(), last: nil)
    guard !outcome.lines.isEmpty else {
        throw ProcessFailure("\(name) printed nothing to record: \(describe(outcome.state, now: Date()))")
    }
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Tests/Fixtures", isDirectory: true)
    let file = try FixtureRecording.write(outcome.lines.map(FixtureRecording.redact),
                                          seat: seat.id, date: Date(), into: directory)
    print("recorded \(outcome.lines.count) line(s) to \(file.path)")
}

/// The same loop the panel runs, with the polls printed as well as logged, so
/// a person can read them going by.
func watch() async throws {
    setvbuf(stdout, nil, _IOLBF, 0)   // a poll a person is watching for, piped or not
    try makePrimer()
    let watcher = try ConfigWatcher()
    let clock = ContinuousClock()
    let say: @Sendable (String) -> Void = { line in
        let at = Date().formatted(date: .omitted, time: .standard)
        print("\(at)  \(line)")
        PollLog.system(line)
    }
    // The same roll-up the panel runs, on the same schedule, so `watch` is the
    // headless twin of a launch rather than a poll loop with a piece missing.
    let roller = SpendCoordinator(log: say)
    let poller = Poller(watcher: watcher, service: RefreshService(clock: clock, fetcher: liveFetcher),
                        store: GaugeStore(), clock: clock,
                        rollup: {
                            let seats = await watcher.config.seats
                            _ = try? await roller.run(profiles: SpendProfile.from(seats: seats),
                                                      rates: RateCard.load(), now: Date())
                        },
                        log: say)
    print("watching \(ConfigLoader.defaultFile.path), logged under \(PollLog.subsystem).")
    await poller.run()
}

/// Every listed machine read once, printed in `machines.json`'s shape.
/// The file itself is the app's to write.
func machines(_ path: String?) async throws {
    let file = path.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
        ?? ConfigLoader.defaultFile
    let config = FileManager.default.fileExists(atPath: file.path)
        ? try ConfigLoader(file: file).load() : Config(seats: [], pollMinutes: 5)
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("machines-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let monitor = MachineMonitor(prober: MachineProber(runner: RealProcessRunner()), file: scratch,
                                 config: { config })
    let states = await monitor.read()
    let printed = MachinesFile(machines: config.machines, states: states, seconds: config.machineSeconds, now: Date())
    print(String(decoding: try printed.data(), as: UTF8.self))
}

/// Another machine onto the LOAD tab: read once over ssh to prove it
/// answers, then added to `seats.json`. Nothing is written when it does not.
func addMachine(_ arguments: ArraySlice<String>) async throws {
    guard let destination = arguments.first else {
        throw ProcessFailure("usage: seatgauge-cli machines add <ssh destination> [label], such as: machines add studio.local Studio")
    }
    let label = arguments.dropFirst().joined(separator: " ")
    let named = label.isEmpty ? String(destination.split(separator: "@").last ?? "").split(separator: ".").first.map(String.init) ?? destination : label
    let machine = Machine(id: MachineList.id(from: named), label: named, ssh: destination)
    let file = ConfigLoader.defaultFile
    guard let text = try? String(contentsOf: file, encoding: .utf8) else {
        throw ProcessFailure("no seats.json at \(file.path) yet; open Seat Gauge once first.")
    }
    _ = try ConfigLoader.decode(Data("{ \"seats\": [], \"machines\": [\(MachineList.entry(machine))] }".utf8))
    print("reading \(destination) over ssh…")
    switch await MachineProber(runner: RealProcessRunner()).read(machine) {
    case let .failure(failure):
        throw ProcessFailure("""
            \(destination) did not answer: \(failure.reason). Nothing was added.
            On that Mac, turn on System Settings > General > Sharing > Remote Login. Then, on this one,
            run `ssh-copy-id \(destination)` so it signs in with a key, and check `ssh \(destination) true`
            returns with no password prompt before trying again.
            """)
    case let .success(reading):
        let hostName = Host.current().localizedName ?? "This Mac"
        let here = Machine(id: MachineList.id(from: hostName), label: hostName)
        let edited = try MachineList.adding(machine, here: here, to: text)
        try Data(edited.utf8).write(to: file, options: .atomic)
        print("added \(machine.label) (\(machine.id)): CPU \(reading.cpuUsed)%, memory \(reading.ramUsed)%, "
              + "\(Int((Double(reading.diskFreeBytes) / 1e9).rounded())) GB disk left, "
              + (reading.agents.map { "\($0.working) agent(s) working" } ?? "no herdr")
              + ". The LOAD tab shows it within a minute.")
    }
}

/// One named transcript's distinct responses, the figure to hold the dedupe
/// to against `jq ... | sort -u | wc -l`.
func spend(file path: String) {
    let file = URL(fileURLWithPath: path)
    let reading = ClaudeCollector.read(file: file, primer: AppPaths.primer)
    print("\(reading.responses.count) distinct response(s) in \(file.lastPathComponent)"
          + (reading.skipped > 0 ? ", \(reading.skipped) line(s) skipped" : ""))
}

/// One roll-up over `~/.claude` and the configured seats' profiles and
/// Codex's session logs, into the files the app uses, timed.
func spend() async throws {
    let profiles = SpendProfile.from(seats: try readSeats(nil))
    guard !profiles.isEmpty else {
        throw ProcessFailure("no projects folder in ~/.claude or in any seat's profile to walk.")
    }
    let rates = RateCard.load(RateCard.defaultFile) { print($0) }
    guard let run = try await SpendCoordinator(log: { print($0) })
        .run(profiles: profiles, rates: rates, now: Date()) else { return }
    print("profiles: " + profiles.map(\.seat).joined(separator: ", "))
    print("responses: \(run.responses) from \(run.files) file(s), \(run.skipped) line(s) skipped")
    print("rows: \(run.rows.count) in \(SpendCSV.defaultFile.path)")
    let priced = run.rows.compactMap(\.usd).reduce(Decimal(0), +)
    let unpriced = run.rows.filter { $0.usd == nil }.reduce(0) { $0 + $1.responses }
    print("value: $\(priced.roundedToCents) at list price, \(unpriced) response(s) unpriced")
    print("took: \(run.took.formattedSeconds) s")
}

/// One seat signed in through `claude auth login` under its own profile: the
/// link printed, the code read from stdin, and `claude auth status` the proof.
func login(_ arguments: ArraySlice<String>) throws {
    let request = try SeatLogin.Request(arguments: Array(arguments))
    let signed = try SeatLogin.signIn(request.seat, email: request.email, seats: try readSeats(request.seatsFile),
                                      searchPath: .loginShell,
                                      code: {
                                          print("code> ", terminator: "")
                                          fflush(stdout)
                                          let code = readLine()
                                          // A person's Return ends the line; a pipe's code does not.
                                          if isatty(STDIN_FILENO) == 0 { print(""); fflush(stdout) }
                                          return code
                                      },
                                      link: { link in
                                          print("Open this link, sign in to the account for \(request.seat), and paste the code it shows:")
                                          print(link)
                                          fflush(stdout)
                                      })
    print(signed.sentence(request.seat))
}

extension Decimal {
    /// Cents, for a figure a person reads rather than one the CSV keeps.
    var roundedToCents: Decimal {
        var value = self
        var out = Decimal()
        NSDecimalRound(&out, &value, 2, .plain)
        return out
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "log-probe":
        let directory = arguments.count == 3 && arguments[1] == "--directory"
            ? URL(fileURLWithPath: arguments[2]) : AppPaths.support.appendingPathComponent("log-private")
        let config = ConfigLoader(file: directory.deletingLastPathComponent().appendingPathComponent("seats.json"))
        let seats = (try? config.load().seats) ?? []
        let log = try await SessionProbe(directory: directory, profiles: SpendProfile.from(seats: seats)).run(rates: RateCard.load())
        print(String(decoding: try SessionLogFile.encoder().encode(log), as: UTF8.self))
    case "log":
        let watcher = try ConfigWatcher()
        let log = await SessionLogMonitor(prober: MachineProber(runner: RealProcessRunner()),
                                         config: { await watcher.config }).read()
        print(String(decoding: try SessionLogFile.encoder().encode(log), as: UTF8.self))
    case "read": try await read(arguments.dropFirst().first)
    case "record": try await record(arguments.dropFirst().first ?? "", from: arguments.dropFirst(2).first)
    case "watch": try await watch()
    case "spend":
        if let path = arguments.dropFirst().first { spend(file: path) } else { try await spend() }
    case "state": try state(arguments.dropFirst())
    case "attribute": await attribute(arguments.dropFirst())
    case "import-codex": try await importCodex()
    case "login": try login(arguments.dropFirst())
    case "machines":
        if arguments.dropFirst().first == "add" { try await addMachine(arguments.dropFirst(2)) }
        else { try await machines(arguments.dropFirst().first) }
    default: print("usage: seatgauge-cli log | log-probe | read [seats.json] | machines [seats.json] | machines add <ssh destination> [label] | record <seat> [seats.json] | watch | spend [file] | state [range <r>] [measure <m>] | attribute --seed <file> | import-codex | login <seat> [--email <address>] [seats.json]")
    }
} catch {
    FileHandle.standardError.write(Data("seatgauge-cli: \(error)\n".utf8))
    exit(1)
}
