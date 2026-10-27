import Foundation
import Testing

import SeatGaugeCore

/// The version is written twice, in `VERSION` for the bundle and in
/// `SeatGaugeVersion` for the code, so these keep the two one value.
@Suite struct VersionTests {

    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func theConstantMatchesTheVersionFile() throws {
        let file = try String(contentsOf: Self.repository.appendingPathComponent("VERSION"), encoding: .utf8)
        #expect(SeatGaugeVersion.current == file.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The release this checkout is (#167). A version bump changes this line too.
    @Test func theVersionIsTheRelease() throws {
        let file = try String(contentsOf: Self.repository.appendingPathComponent("VERSION"), encoding: .utf8)
        #expect(file.trimmingCharacters(in: .whitespacesAndNewlines) == "0.2.0")
    }

    /// Run as the built binary, as `AttributionSeedTests` runs it.
    @Test func theCLIPrintsIt() throws {
        let task = Process()
        task.executableURL = Self.repository.appendingPathComponent(".build/debug/seatgauge-cli")
        task.arguments = ["--version"]
        let out = Pipe()
        task.standardOutput = out
        try task.run()
        // `waitUntilExit` can miss an exit when called from a task, so poll against a deadline.
        let deadline = Date(timeIntervalSinceNow: 30)
        while task.isRunning, Date() < deadline { usleep(20_000) }
        if task.isRunning { task.terminate() }
        #expect(task.terminationStatus == 0)
        #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                == "seatgauge-cli \(SeatGaugeVersion.current)\n")
    }
}
