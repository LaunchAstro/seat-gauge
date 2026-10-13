import Foundation
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// A card whose seat has an `open` command: the header offers the click, the
/// click runs the command once, and a failure lands in the title bar's slot
/// after any config problem.
@Suite @MainActor struct SeatOpenPanelTests {

    static let now = Date(timeIntervalSince1970: 1_758_500_100)

    static func seat(_ id: String, open: [String]?) -> Seat {
        Seat(id: SeatID(rawValue: id), label: id.capitalized, kind: .codex, open: open)
    }

    /// A mirror with its own card store, holding `seats`, each read live.
    static func mirror(_ seats: [Seat], in folder: URL) -> GaugeMirror {
        let mirror = GaugeMirror()
        mirror.readCards(StateStore(file: folder.appendingPathComponent("state.json")))
        let window = SeatGaugeCore.Window(kind: .weekly, usedPercent: 20, resetsAt: now.addingTimeInterval(3600),
                                          length: .seconds(7 * 86_400))
        let states = Dictionary(uniqueKeysWithValues: seats.map {
            ($0.id, SeatState.live(Reading(seat: $0.id, windows: [window], takenAt: now, plan: nil)))
        })
        mirror.apply(Snapshot(states: states, order: seats.map(\.id)), seats: seats)
        return mirror
    }

    static func folder() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-open-panel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func onlyACardWhoseSeatHasAnOpenCommandOffersTheClick() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mirror = Self.mirror([Self.seat("work", open: ["/usr/bin/true"]), Self.seat("codex", open: nil)], in: folder)
        let cards = mirror.model(at: Self.now).cards
        #expect(cards.map(\.opens) == [true, false])
        #expect(cards.first?.openLabel == "Open Work")
    }

    @Test func aClickRunsTheCommandOnceEvenWhenClickedAgainDuringTheStartCheck() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("ran")
        let script = folder.appendingPathComponent("open-seat")
        try "#!/bin/sh\necho ran >> \"\(log.path)\"\nsleep 1\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let mirror = Self.mirror([Self.seat("work", open: [script.path])], in: folder)

        let first = mirror.open(SeatID(rawValue: "work"))
        #expect(mirror.open(SeatID(rawValue: "work")) == nil, "a second click during the start check ran again")
        await first?.value
        #expect(try String(contentsOf: log, encoding: .utf8) == "ran\n")
        #expect(mirror.problems.isEmpty)
        // A seat with no command, or none at all, runs nothing.
        #expect(mirror.open(SeatID(rawValue: "codex")) == nil)
    }

    @Test func aFailedOpenShowsOneLineAfterAnyConfigProblem() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mirror = Self.mirror([Self.seat("work", open: ["/usr/bin/false"])], in: folder)
        await mirror.open(SeatID(rawValue: "work"))?.value
        #expect(mirror.problems == ["Open Work: false exited with status 1"])

        mirror.configProblem = "seats.json: the id \"Work\" is not lowercase."
        #expect(mirror.problems == ["seats.json: the id \"Work\" is not lowercase.",
                                    "Open Work: false exited with status 1"])
    }
}
