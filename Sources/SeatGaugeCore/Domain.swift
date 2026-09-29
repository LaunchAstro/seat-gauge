import Foundation

/// A seat as the config file names it: "personal", "codex".
public struct SeatID: Hashable, RawRepresentable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Which CLI reads the seat. A Claude seat always has its own profile
/// directory: `seats.json` refuses one without.
public enum SeatKind: Equatable, Sendable {
    case claude(profileDir: URL)
    case codex

    /// The provider whose CLI this is. A Claude seat is Claude whatever its
    /// profile directory, so the directory plays no part.
    public var provider: Provider {
        switch self {
        case .claude: .claude
        case .codex: .codex
        }
    }
}

/// Whose CLI a seat is read through, as a card names it and draws its mark.
public enum Provider: String, CaseIterable, Sendable {
    case claude, codex

    /// The name the card's header draws.
    public var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    /// The site whose own icon is the provider's mark (`MarkCache`).
    public var site: URL {
        switch self {
        case .claude: URL(string: "https://claude.ai/")!
        case .codex: URL(string: "https://chatgpt.com/")!
        }
    }
}

public struct Seat: Identifiable, Equatable, Sendable {
    public let id: SeatID
    public let label: String
    public let kind: SeatKind
    /// Where this seat's OAuth token is read from, when it has one. The path
    /// only: the value is read at the moment of the fetch and never held.
    public let tokenFile: URL?
    /// Whose account this seat is, in the user's words. No wire gives an
    /// address for any seat, so this is declared or it is nothing: the app
    /// never guesses one.
    public let account: String?
    /// What the user says the seat pays for, e.g. "Max 20x". A login's tier
    /// beats it, because a declaration goes stale when the user switches
    /// plans; it beats the wire's `max`, which cannot tell 5x from 20x.
    public let plan: String?

    public init(id: SeatID, label: String, kind: SeatKind, tokenFile: URL? = nil,
                account: String? = nil, plan: String? = nil) {
        self.id = id
        self.label = label
        self.kind = kind
        self.tokenFile = tokenFile
        self.account = account
        self.plan = plan
    }
}

extension Seat {
    /// A Claude token seat reports its windows only during a model turn,
    /// which the seat pays for. An own login answers with no turn.
    public var readsByTurn: Bool {
        guard case .claude = kind else { return false }
        return tokenFile != nil
    }

    /// A seat read by a paid turn is read when the user asks, never on the timer.
    public var pollsAutomatically: Bool { !readsByTurn }
}

/// Which plan a card says: the tier the login file
/// names, then the user's declaration, then the wire's word, then nothing.
/// The file is exact and follows a plan switch, so it wins outright. The
/// wire's `max` cannot tell 5x from 20x, so a declaration is more exact than it.
/// A seat that reported no plan has not reported one, which is not a fact about
/// the account and is never drawn as "Free": reading `null` as free would hide a
/// seat that is fine. Blank is nothing too, so a key the user left empty does not
/// draw an empty line.
public enum PlanText {
    /// The three steps in order, each skipped when it is blank.
    public static func resolve(tier: String?, declared: String?, wire: String?) -> String? {
        said(tier) ?? said(declared) ?? said(wire)
    }

    /// The plan a seat is shown with, from its reading or the last one held.
    /// It is what `seatgauge-cli read` prints and the card draws.
    public static func shown(for seat: Seat, state: SeatState) -> String? {
        switch state {
        case let .live(reading), let .unreadable(_, reading?):
            return resolve(tier: reading.tier, declared: seat.plan, wire: reading.plan)
        default:
            return resolve(tier: nil, declared: seat.plan, wire: nil)
        }
    }

    /// `text` padded with spaces to at least `width`, and never cut, so a
    /// long plan such as "enterprise max" prints whole. `read` lines up its
    /// columns with it.
    public static func column(_ text: String, width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - text.count))
    }

    /// Text with something in it, trimmed, or nil.
    public static func said(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// Display order, which is also the order a reading's windows are sorted in.
public enum WindowKind: Int, CaseIterable, Sendable, Comparable, Codable {
    case fiveHour, weekly, fable

    public static func < (a: WindowKind, b: WindowKind) -> Bool { a.rawValue < b.rawValue }
}

/// One usage window. The percentage counts up and is clamped, and the reset
/// instant is always there: a row without one is dropped where the transport
/// is known rather than carried into the panel as a zero.
public struct Window: Equatable, Sendable, Codable {
    public let kind: WindowKind
    public let usedPercent: Int
    public let resetsAt: Date
    public let length: Duration

    public var headroom: Int { 100 - usedPercent }

    public init(kind: WindowKind, usedPercent: Int, resetsAt: Date, length: Duration) {
        self.kind = kind
        self.usedPercent = min(100, max(0, usedPercent))
        self.resetsAt = resetsAt
        self.length = length
    }
}

/// One seat read once. `windows` is non-empty and in `WindowKind` order.
public struct Reading: Equatable, Sendable, Codable {
    public let seat: SeatID
    public let windows: [Window]
    public let takenAt: Date
    /// The wire's word, which for Claude is the coarse `max`.
    public let plan: String?
    /// The exact tier the account itself names, absent in a reading
    /// saved before it, which decodes as nil.
    public let tier: String?

    public init(seat: SeatID, windows: [Window], takenAt: Date, plan: String?, tier: String? = nil) {
        self.seat = seat
        self.windows = windows
        self.takenAt = takenAt
        self.plan = plan
        self.tier = tier
    }

    /// The tightest window, which is what the best-seat rule ranks on.
    public var headroom: Int { windows.map(\.headroom).min() ?? 0 }
}

public enum SeatState: Equatable, Sendable {
    case dormant(reason: String)
    case unreadable(reason: String, last: Reading?)
    case live(Reading)
}

/// What the panel draws: every seat's state, in config order.
public struct Snapshot: Sendable {
    public let states: [SeatID: SeatState]
    public let order: [SeatID]
    /// A dormant seat's last reading, which its card draws when the user
    /// shows it. `GaugeStore` keeps it in `reported.json`, not beside the
    /// readings, so a dormant seat is never restored as a stale card.
    public let reported: [SeatID: Reading]

    public init(states: [SeatID: SeatState], order: [SeatID], reported: [SeatID: Reading] = [:]) {
        self.states = states
        self.order = order
        self.reported = reported
    }

    /// Live seats, and stale ones that still have a last reading to dim.
    public var visible: [SeatID] {
        order.filter { id in
            switch states[id] {
            case .live: return true
            case .unreadable(_, let last): return last != nil
            default: return false
            }
        }
    }

    /// The most headroom in its tightest window, among live seats only. The
    /// comparison is strict, so a tie goes to the first seat in config order.
    public var best: SeatID? {
        var winner: SeatID?
        var most = Int.min
        for id in order {
            guard case let .live(reading) = states[id] else { continue }
            if reading.headroom > most {
                most = reading.headroom
                winner = id
            }
        }
        return winner
    }
}

/// What a boundary parser hands back: a reading's windows, a seat that is not
/// logged in, or a reason the capture could not be read.
public enum FetchOutcome: Equatable, Sendable {
    case live(windows: [Window], plan: String?)
    case dormant(reason: String)
    case unreadable(reason: String)
}

extension Duration {
    /// Seconds as a Double, for the pace arithmetic in `TimeInterval`.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// Where the user has put the cards: an order, the seats taken off the window
/// and the seats put on it though they have no reading to draw. It is read
/// against the config every time, so a seat new to `seats.json` lands at the
/// end and one gone from it drops out. The app keeps it in `state.json` and
/// never writes `seats.json`.
public struct CardArrangement: Equatable, Sendable {
    public var order: [SeatID]
    public var hidden: Set<SeatID>
    public var shown: Set<SeatID>

    public init(order: [SeatID] = [], hidden: Set<SeatID> = [], shown: Set<SeatID> = []) {
        self.order = order
        self.hidden = hidden
        self.shown = shown
    }

    /// The configured seats: the saved order first, then the rest in config order.
    public func arranged(_ configured: [SeatID]) -> [SeatID] {
        let known = Set(configured)
        var placed = Set<SeatID>()
        let saved = order.filter { known.contains($0) && placed.insert($0).inserted }
        return saved + configured.filter { !placed.contains($0) }
    }

    /// `id` dropped where `target` is, the cards between them shifting one place.
    public func moving(_ id: SeatID, to target: SeatID, configured: [SeatID]) -> CardArrangement {
        var ids = arranged(configured)
        guard id != target, let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target) else {
            return self
        }
        ids.insert(ids.remove(at: from), at: to)
        return CardArrangement(order: ids, hidden: hidden, shown: shown)
    }

    public func hiding(_ id: SeatID) -> CardArrangement {
        CardArrangement(order: order, hidden: hidden.union([id]), shown: shown.subtracting([id]))
    }

    public func showing(_ id: SeatID) -> CardArrangement {
        CardArrangement(order: order, hidden: hidden.subtracting([id]), shown: shown.union([id]))
    }

    /// What is worth saving: the order and both sets over configured seats
    /// only, so a seat removed and added again lands at the end.
    public func kept(_ configured: [SeatID]) -> CardArrangement {
        let known = Set(configured)
        return CardArrangement(order: order.filter(known.contains), hidden: hidden.intersection(known),
                               shown: shown.intersection(known))
    }
}
