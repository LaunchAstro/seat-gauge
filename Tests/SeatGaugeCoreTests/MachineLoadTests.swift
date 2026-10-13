import Foundation
import Testing

import SeatGaugeCore
import SeatGaugeTestSupport

@Suite struct MachineLoadTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// What the probe prints on a Mac with herdr, in round numbers.
    static let printed = [
        "cores 10",
        "memsize 34359738368",
        "memfree 70",
        "load { 4.00 3.00 2.00 }",
        "disk /dev/disk3s5   1000000000 800000000 200000000    80% 100 200 1%   /System/Volumes/Data",
        "cpu CPU usage: 30.0% user, 10.0% sys, 60.0% idle ",
        #"agents {"id":"cli:agent:list","result":{"agents":[{"agent_status":"working"},{"agent_status":"idle"},{"agent_status":"done"},{"agent_status":"blocked"}]}}"#,
        "end",
    ]

    @Test("a full answer reads every figure and counts herdr's agents by state")
    func parse() throws {
        let reading = try #require(MachineProbe.parse(Self.printed, at: Self.now))
        #expect(reading.cores == 10)
        #expect(reading.cpuUsed == 40)
        #expect(reading.load == [4, 3, 2])
        #expect(reading.ramUsed == 30)
        #expect(reading.ramBytes == 34_359_738_368)
        #expect(reading.diskUsed == 80)
        #expect(reading.diskFreeBytes == 200_000_000 * 1024)
        #expect(reading.agents == AgentCount(working: 1, blocked: 1, idle: 2))
        #expect(reading.room == .free)
    }

    @Test("no herdr is no count, and a cut-off answer is no reading")
    func partial() {
        let withoutHerdr = Self.printed.filter { !$0.hasPrefix("agents") }
        #expect(MachineProbe.parse(withoutHerdr, at: Self.now)?.agents == nil)
        #expect(MachineProbe.parse(withoutHerdr, at: Self.now) != nil)
        #expect(MachineProbe.parse(Array(Self.printed.prefix(5)), at: Self.now) == nil)
        #expect(MachineProbe.parse(Self.printed.filter { $0 != "end" }, at: Self.now) == nil)
    }

    @Test("room turns busy at 60 percent and full at 85, or when the disk runs low")
    func room() {
        func reading(cpu: Int = 10, ram: Int = 10, freeGB: Double = 500) -> MachineReading {
            MachineReading(takenAt: Self.now, cpuUsed: cpu, load: [1, 1, 1], cores: 8, ramUsed: ram,
                           ramBytes: 1, diskUsed: 50, diskFreeBytes: Int64(freeGB * 1e9), agents: nil)
        }
        #expect(reading().room == .free)
        #expect(reading(cpu: 60).room == .busy)
        #expect(reading(ram: 85).room == .full)
        #expect(reading(freeGB: 20).room == .busy)
        #expect(reading(freeGB: 5).room == .full)
    }

    @Test("this Mac runs the probe in sh; another runs it over ssh in batch mode")
    func spec() {
        let here = MachineProber.spec(.here, environment: [:])
        #expect(here.executable.path == "/bin/sh")
        let there = MachineProber.spec(Machine(id: "studio", label: "Studio", ssh: "studio.local"), environment: [:])
        #expect(there.executable.path == "/usr/bin/ssh")
        #expect(there.arguments.contains("BatchMode=yes"))
        #expect(Array(there.arguments.suffix(4)) == ["--", "studio.local", "/bin/sh", "-s"])
    }

    @Test("a read sends the probe, and a silent machine is unreachable with its last figures kept")
    func monitor() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("machines-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let config = Config(seats: [], pollMinutes: 5, machines: [.here])
        let answering = ScriptedRunner(replies: [[]] + Array(repeating: [], count: MachineProbe.script.count - 2)
                                       + [Self.printed], endsWithScript: true)
        let first = await MachineMonitor(prober: MachineProber(runner: answering, environment: [:]),
                                         file: scratch, config: { config }).read()
        #expect(answering.sent == MachineProbe.script)
        #expect(first[Machine.here.id]?.reading?.cpuUsed == 40)
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: scratch)) as! [String: Any]
        let row = (written["machines"] as! [[String: Any]])[0]
        #expect(row["room"] as? String == "free")
        #expect((row["agents"] as? [String: Any])?["total"] as? Int == 4)
        #expect(row["reachable"] as? Bool == true)

        let silent = ScriptedRunner(replies: [], endsWithScript: false, launchFailure: "ssh would not start")
        let monitor = MachineMonitor(prober: MachineProber(runner: silent, environment: [:]), file: scratch,
                                     config: { config })
        let gone = await monitor.read()
        guard case let .unreachable(reason, last) = gone[Machine.here.id] else { Issue.record("not unreachable"); return }
        #expect(reason == "ssh would not start")
        #expect(last == nil)
    }

    @Test("seats.json lists machines, this Mac alone when it names none, and refuses an ssh that reads as an option")
    func config() throws {
        let none = try ConfigLoader.decode(Data(#"{ "seats": [] }"#.utf8))
        #expect(none.machines == [.here])
        #expect(none.machineSeconds == 30)
        let two = try ConfigLoader.decode(Data(#"""
            { "seats": [], "machineSeconds": 3,
              "machines": [{ "id": "here", "label": "Laptop" }, { "id": "studio", "label": "Studio", "ssh": "studio.local" }] }
            """#.utf8))
        #expect(two.machines == [Machine(id: "here", label: "Laptop"),
                                 Machine(id: "studio", label: "Studio", ssh: "studio.local")])
        #expect(two.machineSeconds == 10)
        #expect(throws: ConfigProblem.self) {
            try ConfigLoader.decode(Data(#"{ "seats": [], "machines": [{ "id": "x", "label": "X", "ssh": "-oProxyCommand=boom" }] }"#.utf8))
        }
        #expect(throws: ConfigProblem.self) {
            try ConfigLoader.decode(Data(#"{ "seats": [], "machines": [{ "id": "x", "label": "X" }, { "id": "x", "label": "Y" }] }"#.utf8))
        }
    }
}
