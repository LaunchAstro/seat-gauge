import Foundation

/// `headroom.json`: what the cards show, as a file an agent reads in one step
/// to see which seats have room, without running a CLI. Only the seat id, its
/// kind, its plan and its windows go in, so the file says nothing the panel
/// does not already show. It names no single seat to use. An agent handed
/// one answer sends every lane there, so the reader spreads the work.
public struct Headroom: Encodable, Equatable, Sendable {
    public let updated: String
    public let seats: [SeatRow]

    public struct SeatRow: Encodable, Equatable, Sendable {
        public let id: String
        public let kind: String
        public let plan: String?
        public let stale: Bool
        /// When the figures below were taken, or nil when there are none.
        public let readAt: String?
        public let fiveHour: WindowRow?
        public let weekly: WindowRow?
        public let fable: WindowRow?

        enum CodingKeys: String, CodingKey {
            case id, kind, plan, stale, readAt = "read_at", fiveHour = "five_hour", weekly, fable
        }

        // Written out so a seat with no plan or reading says `null` rather
        // than leaving the key out; a window it does not have is left out.
        public func encode(to encoder: Encoder) throws {
            var keys = encoder.container(keyedBy: CodingKeys.self)
            try keys.encode(id, forKey: .id)
            try keys.encode(kind, forKey: .kind)
            try keys.encode(plan, forKey: .plan)
            try keys.encode(stale, forKey: .stale)
            try keys.encode(readAt, forKey: .readAt)
            try keys.encodeIfPresent(fiveHour, forKey: .fiveHour)
            try keys.encodeIfPresent(weekly, forKey: .weekly)
            try keys.encodeIfPresent(fable, forKey: .fable)
        }
    }

    public struct WindowRow: Encodable, Equatable, Sendable {
        public let used: Int
        public let left: Int
        public let resets: String
    }

    /// One row per configured seat, in config order. A seat is stale when
    /// its last read failed, when it has never been read, or when its reading
    /// is older than two poll intervals. A dormant or never-read seat has no
    /// windows; a stale one keeps its last, as its dimmed card does.
    public init(snapshot: Snapshot, seats: [Seat], pollMinutes: Int, now: Date,
                timeZone: TimeZone = .current) {
        let dates = ISO8601DateFormatter()
        dates.timeZone = timeZone
        let oldest = now.addingTimeInterval(-2 * 60 * Double(pollMinutes))
        updated = dates.string(from: now)
        self.seats = seats.map { seat in
            let state = snapshot.states[seat.id] ?? .dormant(reason: "never read")
            let reading = RefreshService.last(state)
            var fresh = false
            if case let .live(live) = state { fresh = live.takenAt >= oldest }
            func row(_ kind: WindowKind) -> WindowRow? {
                reading?.windows.first { $0.kind == kind }.map {
                    WindowRow(used: $0.usedPercent, left: $0.headroom, resets: dates.string(from: $0.resetsAt))
                }
            }
            return SeatRow(id: seat.id.rawValue, kind: seat.kind.provider.rawValue,
                           plan: PlanText.shown(for: seat, state: state), stale: !fresh,
                           readAt: reading.map { dates.string(from: $0.takenAt) },
                           fiveHour: row(.fiveHour), weekly: row(.weekly), fable: row(.fable))
        }
    }

    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
