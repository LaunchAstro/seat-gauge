import Foundation

/// Something the panel cannot do its job without, said in one sentence. The
/// cases are in the order they compete for the title bar's one slot.
public enum PanelProblem: Equatable, Sendable {
    /// `seats.json` would not read; the decoder's or the rule's own words.
    case config(String)
    case spendRecord
    /// The last roll-up found `spend.csv` missing and rebuilt it from logs.
    case spendRebuilt
    case attributionRecord
    /// The system zone differs from the one the attribution record keeps.
    case timeZone

    public var sentence: String {
        switch self {
        case let .config(reason): reason
        case .spendRecord: "spend record unreadable"
        case .spendRebuilt: "spend record was missing, rebuilt from logs"
        case .attributionRecord: "attribution record unreadable"
        case .timeZone: "time zone differs from the attribution record's"
        }
    }

    /// What reading the two records raises, beside the config's own.
    public static func reading(spend: SpendRecord, attribution: AttributionFile.Read,
                               zone: TimeZone = .current, rebuilt: Bool = false) -> [PanelProblem] {
        var problems: [PanelProblem] = spend.isWhole ? (rebuilt ? [.spendRebuilt] : []) : [.spendRecord]
        switch attribution {
        case .missing: break
        case .malformed: problems.append(.attributionRecord)
        case let .record(record) where record.timeZone != zone.identifier: problems.append(.timeZone)
        case .record: break
        }
        return problems
    }

    var rank: Int {
        switch self {
        case .config: 0
        case .spendRecord, .spendRebuilt: 1
        case .attributionRecord: 2
        case .timeZone: 3
        }
    }
}

/// The title bar shows one problem in place of the updated line, and the
/// right-click menu lists every one in full, the shown one first.
public struct ProblemSlot: Equatable, Sendable {
    public let title: String?
    public let menu: [String]

    public init(_ problems: [PanelProblem]) {
        menu = problems.sorted { $0.rank < $1.rank }.map(\.sentence)
        title = menu.first
    }
}
