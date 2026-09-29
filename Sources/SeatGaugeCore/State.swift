import Foundation

/// `state.json`: the small facts the app keeps between launches that are
/// neither config nor readings. Every field decodes to a
/// default when it is missing, so a file written by an older version is read
/// rather than refused.
public struct AppState: Equatable, Sendable, Codable {
    /// The timezone the day and hour columns of `spend.csv` were bucketed in.
    /// A machine that moves timezone keeps its sealed cells as they were and
    /// buckets from here on in the new one, which is what the record means.
    public var timeZone: String
    /// When the last roll-up ran. The walk measures a transcript against it,
    /// but being untouched since this instant is not on its own licence to
    /// skip the file: it is passed by only when every cell it can feed has
    /// sealed as well (`ClaudeCollector.transcripts`). The roll-up also asks
    /// whether it is there at all, which is how a first run reads all 28 days.
    public var rolledUpAt: Date?
    /// Each session's last `cost-state.totalCostUSD`, kept beside the derived
    /// figure so the gap between the two stays measurable.
    public var sessionCosts: [String: Double]
    /// What the gauge has already said, so a stage fires once a week.
    public var alerts: AlertLedger
    /// Set when the user turns the login item off, so the next launch from
    /// `/Applications` leaves it off rather than registering it again.
    public var loginItemDeclined: Bool
    /// The text size the user last chose, as a `TextScale` step, so the size
    /// survives a quit and a relaunch. A step outside the ladder is
    /// clamped onto it rather than refused: a number nobody supports is not a
    /// reason to launch without a panel.
    public var textSizeStep: Int
    /// The light appearance toggle. Off when the key is missing
    /// or is not a boolean, so an untouched install still opens dark.
    public var lightAppearance: Bool
    /// The card detail's chart range, remembered across hovers and relaunches.
    public var historyRange: HistoryRange
    /// Tokens or list-price dollars, shared by the card detail and Spend.
    public var measure: Measure
    /// When a roll-up last rebuilt a `spend.csv` it found missing after an
    /// earlier roll-up. The title bar says so until a later roll-up reads the
    /// record whole and clears it.
    public var spendRebuiltAt: Date?
    /// The Spend lines the user has clicked off, by key, total included.
    public var hiddenSpendLines: Set<String>
    /// The cards' order and which seats are off or on the window, by seat id,
    /// as `CardArrangement` reads them.
    public var cardOrder: [String]
    public var hiddenCards: Set<String>
    public var shownCards: Set<String>

    public init(timeZone: String = TimeZone.current.identifier, rolledUpAt: Date? = nil,
                sessionCosts: [String: Double] = [:], alerts: AlertLedger = AlertLedger(),
                loginItemDeclined: Bool = false, textSizeStep: Int = TextScale.default.step,
                lightAppearance: Bool = false, historyRange: HistoryRange = .week,
                measure: Measure = .tokens, hiddenSpendLines: Set<String> = [],
                cards: CardArrangement = CardArrangement()) {
        self.timeZone = timeZone
        self.rolledUpAt = rolledUpAt
        self.sessionCosts = sessionCosts
        self.alerts = alerts
        self.loginItemDeclined = loginItemDeclined
        self.textSizeStep = TextScale(step: textSizeStep).step
        self.lightAppearance = lightAppearance
        self.historyRange = historyRange
        self.measure = measure
        self.hiddenSpendLines = hiddenSpendLines
        cardOrder = []
        hiddenCards = []
        shownCards = []
        self.cards = cards
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        timeZone = try values.decodeIfPresent(String.self, forKey: .timeZone)
            ?? TimeZone.current.identifier
        rolledUpAt = try values.decodeIfPresent(Date.self, forKey: .rolledUpAt)
        sessionCosts = try values.decodeIfPresent([String: Double].self, forKey: .sessionCosts) ?? [:]
        alerts = try values.decodeIfPresent(AlertLedger.self, forKey: .alerts) ?? AlertLedger()
        loginItemDeclined = try values.decodeIfPresent(Bool.self, forKey: .loginItemDeclined) ?? false
        // A step that is missing, or is not a number at all, is the default
        // size, and one off the ladder is clamped onto it.
        textSizeStep = TextScale(step: (try? values.decode(Int.self, forKey: .textSizeStep))
            ?? TextScale.default.step).step
        lightAppearance = (try? values.decode(Bool.self, forKey: .lightAppearance)) ?? false
        // Missing, the wrong type or a value nobody writes: W and tokens.
        historyRange = (try? values.decode(HistoryRange.self, forKey: .historyRange)) ?? .week
        measure = (try? values.decode(Measure.self, forKey: .measure)) ?? .tokens
        spendRebuiltAt = try? values.decode(Date.self, forKey: .spendRebuiltAt)
        hiddenSpendLines = (try? values.decode(Set<String>.self, forKey: .hiddenSpendLines)) ?? []
        cardOrder = (try? values.decode([String].self, forKey: .cardOrder)) ?? []
        hiddenCards = (try? values.decode(Set<String>.self, forKey: .hiddenCards)) ?? []
        shownCards = (try? values.decode(Set<String>.self, forKey: .shownCards)) ?? []
    }

    public var cards: CardArrangement {
        get {
            CardArrangement(order: cardOrder.map(SeatID.init(rawValue:)), hidden: Set(hiddenCards.map(SeatID.init(rawValue:))),
                            shown: Set(shownCards.map(SeatID.init(rawValue:))))
        }
        set {
            cardOrder = newValue.order.map(\.rawValue)
            hiddenCards = Set(newValue.hidden.map(\.rawValue))
            shownCards = Set(newValue.shown.map(\.rawValue))
        }
    }
}

/// The card detail's range: 7 days, 30 days, 26 weeks or 12 months.
public enum HistoryRange: String, CaseIterable, Codable, Sendable {
    case week = "W", month = "M", halfYear = "6M", year = "Y"
}

/// Tokens (fresh input, output and cache writes) or list-price dollars.
public enum Measure: String, CaseIterable, Codable, Sendable {
    case tokens, usd
}

/// The one reader and writer of `state.json`. Every handle on the
/// same file in a process shares one serial section, and every update holds an
/// exclusive lock on `state.json.lock` across its read, change and write, so
/// neither another handle nor `seatgauge-cli` can write between the two. A
/// file that cannot be read or decoded is a fresh state rather than an error:
/// nothing in it is worth stopping a launch for.
public struct StateStore: Sendable {
    public let file: URL
    let lockTimeout: Duration

    public init(file: URL = StateStore.defaultFile, lockTimeout: Duration = .seconds(10)) {
        self.file = file
        self.lockTimeout = lockTimeout
    }

    public static var defaultFile: URL { AppPaths.support.appendingPathComponent("state.json") }

    public func load() -> AppState {
        Self.section(for: file).withLock { read() }
    }

    /// Reads, changes and writes under both locks. When another writer holds
    /// the file lock past the timeout it throws `FileLock.Busy` and writes nothing.
    @discardableResult
    public func update(_ change: (inout AppState) -> Void) throws -> AppState {
        let lock = FileLock.file(for: file)
        return try Self.section(for: file).withLock {
            try FileLock.holding(lock, timeout: lockTimeout) {
                var state = read()
                change(&state)
                let writer = JSONEncoder()
                writer.outputFormatting = [.prettyPrinted, .sortedKeys]
                try writer.encode(state).write(to: file, options: .atomic)
                return state
            }
        }
    }

    private func read() -> AppState {
        guard let data = FileManager.default.contents(atPath: file.path),
              let state = try? JSONDecoder().decode(AppState.self, from: data)
        else { return AppState() }
        return state
    }

    /// One lock per file per process, whichever handle asks.
    private static let sections = NSLock()
    nonisolated(unsafe) private static var byPath: [String: NSLock] = [:]
    private static func section(for file: URL) -> NSLock {
        sections.withLock {
            let key = file.standardizedFileURL.path
            if let lock = byPath[key] { return lock }
            let lock = NSLock()
            byPath[key] = lock
            return lock
        }
    }
}
