import Foundation

/// What the panel draws, and the copy of it in `readings.json`, so a launch
/// has cards up before the first fetch returns. Only readings are kept: a
/// dormant seat is a fact about now rather than a reading, and a restored one
/// is drawn dimmed, because its numbers are from before the last quit.
/// Beside it goes `headroom.json`, the same snapshot as an agent reads it.
public actor GaugeStore {
    public private(set) var snapshot: Snapshot
    /// What the last write could not do, said the way the config's problem is:
    /// an unwritable folder is reported on every poll rather than leaving
    /// `readings.json` quietly stale.
    public private(set) var problem: String?
    private let file: URL

    public init(file: URL = GaugeStore.defaultFile, order: [SeatID] = []) {
        let restored = Self.read(file)
        let states = restored.reduce(into: [SeatID: SeatState]()) { states, reading in
            states[reading.seat] = .unreadable(reason: "stale, not polled yet", last: reading)
        }
        self.file = file
        let reported = Self.read(file.deletingLastPathComponent().appendingPathComponent("reported.json"))
        snapshot = Snapshot(states: states, order: order.isEmpty ? restored.map(\.seat) : order,
                            reported: Dictionary(reported.map { ($0.seat, $0) }, uniquingKeysWith: { first, _ in first }))
    }

    /// `reported.json`: a dormant seat's last reading, kept apart from
    /// `readings.json` so a relaunch never draws a dormant seat as stale.
    nonisolated var reportedFile: URL { file.deletingLastPathComponent().appendingPathComponent("reported.json") }

    public static var defaultFile: URL { AppPaths.support.appendingPathComponent("readings.json") }

    /// `headroom.json`, beside the readings file.
    public nonisolated var headroomFile: URL { file.deletingLastPathComponent().appendingPathComponent("headroom.json") }

    /// The poll's answer becomes the snapshot, and the snapshot goes to disk:
    /// the readings, and the headroom of `seats` read against `pollMinutes`.
    public func apply(states: [SeatID: SeatState], order: [SeatID], seats: [Seat] = [],
                      pollMinutes: Int = 5, now: Date = Date()) -> Snapshot {
        let reported = order.compactMap { id -> (SeatID, Reading)? in
            guard case .dormant = states[id],
                  let last = RefreshService.last(snapshot.states[id]) ?? snapshot.reported[id] else { return nil }
            return (id, last)
        }
        snapshot = Snapshot(states: states, order: order,
                            reported: Dictionary(reported, uniquingKeysWith: { first, _ in first }))
        let headroom = Headroom(snapshot: snapshot, seats: seats, pollMinutes: pollMinutes, now: now)
        let kept = order.compactMap { RefreshService.last(states[$0]) }
        let readings = write(file) { try JSONEncoder().encode(kept) }
        // Only while a dormant seat has something to show, so an ordinary
        // folder holds no more files than it did.
        var dormant: String?
        if reported.isEmpty { try? FileManager.default.removeItem(at: reportedFile) }
        else { dormant = write(reportedFile) { try JSONEncoder().encode(reported.map(\.1)) } }
        let agents = write(headroomFile) { try headroom.data() }
        problem = readings ?? dormant ?? agents
        return snapshot
    }

    static func read(_ file: URL) -> [Reading] {
        guard let data = FileManager.default.contents(atPath: file.path) else { return [] }
        return (try? JSONDecoder().decode([Reading].self, from: data)) ?? []
    }

    /// Writes one file atomically, or says why it could not.
    private func write(_ file: URL, _ encode: () throws -> Data) -> String? {
        do {
            let data = try encode()
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return nil
        } catch {
            return "\(file.lastPathComponent): \(error.localizedDescription)"
        }
    }
}
