import Foundation
import Testing

@testable import SeatGaugeCore

/// A missing
/// `spend.csv` is rebuilt only when `state.json` decodes and records a roll-up.
/// A state that will not decode proves no roll-up, so the run refuses and
/// writes nothing, and the state stays byte for byte as it was.
@Suite struct SpendRebuildTests {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("seat-gauge-rebuild-\(UUID().uuidString)", isDirectory: true)
    var csv: URL { folder.appendingPathComponent("spend.csv") }
    var state: URL { folder.appendingPathComponent("state.json") }
    let now = ISO8601DateFormatter().date(from: "2026-09-25T00:00:00Z")!

    func coordinator() throws -> SpendCoordinator {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return SpendCoordinator(csv: csv, state: state, primer: folder, codex: nil, log: { _ in })
    }

    func bytes(_ file: URL) -> Data? { FileManager.default.contents(atPath: file.path) }

    @Test func aMissingRecordBesideAStateThatWillNotDecodeIsRefused() async throws {
        let coordinator = try coordinator()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("{ not json".utf8).write(to: state)
        let before = bytes(state)

        await #expect(throws: SpendRecordUnreadable.self) {
            _ = try await coordinator.run(profiles: [], rates: .bundled, now: now)
        }
        #expect(!FileManager.default.fileExists(atPath: csv.path))
        #expect(bytes(state) == before)
        guard case let .unavailable(reason) = SpendCSV.read(csv, state: state) else {
            Issue.record("a missing record beside an unreadable state is unavailable"); return
        }
        #expect(reason.contains("state.json"))
    }

    @Test func onlyARecordedRollUpLicensesARebuild() async throws {
        let coordinator = try coordinator()
        defer { try? FileManager.default.removeItem(at: folder) }

        // No roll-up recorded: a first run, which is not a rebuild.
        try Data(#"{"timeZone":"UTC"}"#.utf8).write(to: state)
        _ = try await coordinator.run(profiles: [], rates: .bundled, now: now)
        #expect(StateStore(file: state).load().spendRebuiltAt == nil)

        // A roll-up recorded and the record gone: rebuilt, and said so.
        try FileManager.default.removeItem(at: csv)
        let later = now.addingTimeInterval(3600)
        _ = try await coordinator.run(profiles: [], rates: .bundled, now: later)
        #expect(FileManager.default.fileExists(atPath: csv.path))
        #expect(StateStore(file: state).load().spendRebuiltAt == later)
    }
}
