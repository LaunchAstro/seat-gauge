import Foundation
import Testing

import SeatGaugeCore

/// `state.json` has one writer per process and loses nothing across two.
/// Every case works on a `state.json` in a folder of its own.
@Suite struct StateWriterTests {

    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func folder() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `seatgauge-cli state --file <file> <key> <value>`, as a process of its own.
    static func cli(_ file: URL, _ key: String, _ value: String) throws -> Process {
        let task = Process()
        task.executableURL = repository.appendingPathComponent(".build/debug/seatgauge-cli")
        task.arguments = ["state", "--file", file.path, key, value]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        return task
    }

    // MARK: - The range and the measure are remembered

    @Test func theRangeAndTheMeasureAreRemembered() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(file: root.appendingPathComponent("state.json"))
        #expect(store.load().historyRange == .week)
        #expect(store.load().measure == .tokens)
        #expect(HistoryRange.allCases.map(\.rawValue) == ["W", "M", "6M", "Y"])
        #expect(Measure.allCases.map(\.rawValue) == ["tokens", "usd"])
        for range in HistoryRange.allCases {
            for measure in Measure.allCases {
                try store.update { $0.historyRange = range; $0.measure = measure }
                #expect(StateStore(file: store.file).load().historyRange == range)
                #expect(StateStore(file: store.file).load().measure == measure)
            }
        }
        for text in [#"{"textSizeStep": 2}"#, #"{"textSizeStep": 2, "historyRange": 7, "measure": true}"#,
                     #"{"textSizeStep": 2, "historyRange": "D", "measure": "euros"}"#] {
            let state = try JSONDecoder().decode(AppState.self, from: Data(text.utf8))
            #expect(state.historyRange == .week, "\(text)")
            #expect(state.measure == .tokens, "\(text)")
            #expect(state.textSizeStep == 2, "\(text)")
        }
    }

    // MARK: - One serial writer per file in a process

    @Test func handlesInOneProcessShareOneWriter() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("state.json")
        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<4 {
                group.addTask {
                    let store = StateStore(file: file)
                    for n in 0..<50 {
                        _ = try? store.update { state in
                            state.sessionCosts["w\(writer)-\(n)"] = Double(n)
                            switch writer {
                            case 0: state.textSizeStep = n % 2 == 0 ? 1 : 2
                            case 1: state.lightAppearance = n % 2 == 0
                            case 2: state.historyRange = n == 49 ? .year : .month
                            default: state.measure = n == 49 ? .usd : .tokens
                            }
                        }
                    }
                }
            }
        }
        let state = StateStore(file: file).load()
        #expect(state.sessionCosts.count == 200)
        #expect(state.textSizeStep == 2)
        #expect(state.lightAppearance == false)
        #expect(state.historyRange == .year)
        #expect(state.measure == .usd)
    }

    // MARK: - The app and seatgauge-cli cannot race it

    @Test func twoProcessesLoseNothing() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("state.json")
        try StateStore(file: file).update { $0.textSizeStep = 3 }

        let processes = Task.detached {
            for round in 0..<10 {
                let last = round == 9
                let one = try Self.cli(file, "range", last ? "6M" : "M")
                let two = try Self.cli(file, "measure", last ? "usd" : "tokens")
                // Bounded: `waitUntilExit` from a task can miss the exit .
                let deadline = Date(timeIntervalSinceNow: 30)
                while one.isRunning || two.isRunning, Date() < deadline { usleep(20_000) }
                guard !one.isRunning, !two.isRunning else { one.terminate(); two.terminate(); return false }
                guard one.terminationStatus == 0, two.terminationStatus == 0 else { return false }
            }
            return true
        }
        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<4 {
                group.addTask {
                    let store = StateStore(file: file)
                    for n in 0..<40 { _ = try? store.update { $0.sessionCosts["p\(writer)-\(n)"] = 1 } }
                }
            }
        }
        #expect(try await processes.value, "a seatgauge-cli state run failed")
        let state = StateStore(file: file).load()
        #expect(state.sessionCosts.count == 160)
        #expect(state.historyRange == .halfYear)
        #expect(state.measure == .usd)
        #expect(state.textSizeStep == 3)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("state.json.lock").path))
    }

    // MARK: - Fails closed

    @Test func failsClosedWhenTheLockIsHeld() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("state.json")
        try StateStore(file: file).update { $0.textSizeStep = 4; $0.historyRange = .month }
        let before = try Data(contentsOf: file)

        let lock = open(root.appendingPathComponent("state.json.lock").path, O_CREAT | O_RDWR, 0o644)
        #expect(lock >= 0)
        #expect(flock(lock, LOCK_EX | LOCK_NB) == 0)
        let started = Date()
        #expect(throws: (any Error).self) {
            try StateStore(file: file, lockTimeout: .milliseconds(300)).update { $0.textSizeStep = 1 }
        }
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(try Data(contentsOf: file) == before)
        flock(lock, LOCK_UN)
        close(lock)
        try StateStore(file: file, lockTimeout: .milliseconds(300)).update { $0.textSizeStep = 1 }
        #expect(StateStore(file: file).load().textSizeStep == 1)

        try Data("{ not json".utf8).write(to: file)
        #expect(StateStore(file: file).load() == AppState(timeZone: StateStore(file: file).load().timeZone))
    }
}
