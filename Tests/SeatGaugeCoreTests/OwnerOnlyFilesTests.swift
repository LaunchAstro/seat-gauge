import Foundation
import Testing

import SeatGaugeCore
import SeatGaugeTestSupport

/// The files the app keeps name the user's clients, repositories, sessions
/// and usage, so each is the user's alone: 600 in a 700 folder, whatever the
/// umask, and an older file or folder left wider is narrowed on the next write.
@Suite struct OwnerOnlyFilesTests {
    static func scratch() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-private-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func mode(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// Runs `body` under the umask most Macs have, which leaves new files 644.
    static func underUsualUmask<T>(_ body: () async throws -> T) async rethrows -> T {
        let old = umask(0o022)
        defer { umask(old) }
        return try await body()
    }

    /// A support folder an older build left open: 755, with a 644 file in it.
    static func openSupport(_ root: URL, holding names: [String]) throws -> URL {
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        for name in names {
            let file = support.appendingPathComponent(name)
            try Data().write(to: file)
            chmod(file.path, 0o644)
        }
        return support
    }

    @Test("readings, headroom, spend, state and attribution are 600 in a 700 folder, and older ones are narrowed")
    func theSupportFilesAreTheUsersAlone() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.underUsualUmask {
            // Made fresh, folder and all.
            let fresh = root.appendingPathComponent("fresh", isDirectory: true)
            let store = GaugeStore(file: fresh.appendingPathComponent("readings.json"))
            _ = await store.apply(states: [:], order: [])
            #expect(Self.mode(fresh) == 0o700)
            #expect(Self.mode(fresh.appendingPathComponent("readings.json")) == 0o600)
            #expect(Self.mode(fresh.appendingPathComponent("headroom.json")) == 0o600)
            try SpendCSV.write([], to: fresh.appendingPathComponent("spend.csv"))
            #expect(Self.mode(fresh.appendingPathComponent("spend.csv")) == 0o600)

            // Left open by an older build, then written again.
            let names = ["readings.json", "headroom.json", "spend.csv", "state.json", "attribution.json"]
            let support = try Self.openSupport(root, holding: names)
            try FileManager.default.removeItem(at: support.appendingPathComponent("attribution.json"))
            _ = await GaugeStore(file: support.appendingPathComponent("readings.json")).apply(states: [:], order: [])
            try SpendCSV.write([], to: support.appendingPathComponent("spend.csv"))
            try StateStore(file: support.appendingPathComponent("state.json")).update { $0.rolledUpAt = Date() }
            await AttributionWriter(file: support.appendingPathComponent("attribution.json"))
                .observe(.noMatch, now: Date())
            #expect(Self.mode(support) == 0o700)
            for name in names {
                #expect(Self.mode(support.appendingPathComponent(name)) == 0o600, "\(name)")
            }
        }
    }

    @Test("machines.json and log.json are 600")
    func theLoadAndLogFilesAreTheUsersAlone() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try Self.openSupport(root, holding: ["machines.json", "log.json"])
        let config = Config(seats: [], pollMinutes: 5)
        let prober = MachineProber(runner: ScriptedRunner(replies: [[], [], []], endsWithScript: true))
        try await Self.underUsualUmask {
            _ = await MachineMonitor(prober: prober, file: support.appendingPathComponent("machines.json"),
                                     config: { config }).read()
            _ = await SessionLogMonitor(prober: prober, file: support.appendingPathComponent("log.json"),
                                        config: { config }).read()
        }
        #expect(Self.mode(support) == 0o700)
        #expect(Self.mode(support.appendingPathComponent("machines.json")) == 0o600)
        #expect(Self.mode(support.appendingPathComponent("log.json")) == 0o600)
    }

    @Test("the seats.json first launch writes is 600 in a 700 folder")
    func theSeededConfigIsTheUsersAlone() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let folder = root.appendingPathComponent("support", isDirectory: true)
        let file = folder.appendingPathComponent("seats.json")
        let loader = ConfigLoader(file: file, machine: SeatDiscovery(home: home, codexLogin: root.appendingPathComponent("no-auth.json")))
        _ = try await Self.underUsualUmask { try loader.loadOrCreate() }
        #expect(Self.mode(folder) == 0o700)
        #expect(Self.mode(file) == 0o600)
    }

    @Test("a backup day is 700 with 600 copies, in a 700 backups folder")
    func backupsAreTheUsersAlone() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = try Self.openSupport(root, holding: [])
        try Data("seat,day\n".utf8).write(to: support.appendingPathComponent("spend.csv"))
        try Data("{}".utf8).write(to: support.appendingPathComponent("attribution.json"))
        let day = try await Self.underUsualUmask { try HistoryBackup(support: support).run(now: Date()) }
        let written = try #require(day)
        #expect(Self.mode(support.appendingPathComponent("backups")) == 0o700)
        #expect(Self.mode(written) == 0o700)
        for name in HistoryBackup.names {
            #expect(Self.mode(written.appendingPathComponent(name)) == 0o600, "\(name)")
        }
    }
}
