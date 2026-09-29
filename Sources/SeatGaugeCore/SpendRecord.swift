import Foundation

/// What reading `spend.csv` met. Only a record read whole is
/// available or empty; a record with bad lines is partial, and one that cannot
/// be read at all is unavailable, so damage is never drawn as no history.
public enum SpendRecord: Equatable, Sendable {
    case available([SpendRow])
    /// Read cleanly and holds no rows, or is missing before the first roll-up.
    case empty
    case partial([SpendRow], String)
    case unavailable(String)

    public var rows: [SpendRow] {
        switch self {
        case let .available(rows), let .partial(rows, _): rows
        case .empty, .unavailable: []
        }
    }

    public var reason: String? {
        switch self {
        case let .partial(_, reason), let .unavailable(reason): reason
        case .available, .empty: nil
        }
    }

    /// Whether every line was read, which is what a writer needs to know.
    public var isWhole: Bool { reason == nil }
}

/// A roll-up refused because the record on disk did not read whole: it
/// collected nothing and wrote nothing.
public struct SpendRecordUnreadable: Error, CustomStringConvertible {
    public let reason: String
    public var description: String { "\(reason), so this run writes nothing" }
}

extension SpendCSV {
    /// The record and what reading it met. A missing file is empty only on a
    /// machine that has never rolled up: `state.json` is missing, or reads
    /// with no `rolledUpAt`. After a roll-up, or when the state will not
    /// decode, a missing file is history lost, not history never made.
    public static func read(_ file: URL = SpendCSV.defaultFile, state: URL) -> SpendRecord {
        let name = file.lastPathComponent
        guard FileManager.default.fileExists(atPath: file.path) else {
            if firstRun(state) { return .empty }
            return rolledUp(state) ? .unavailable("\(name) is missing after a roll-up")
                : .unavailable("\(name) is missing and \(state.lastPathComponent) could not be read")
        }
        guard let data = FileManager.default.contents(atPath: file.path),
              let text = String(data: data, encoding: .utf8)
        else { return .unavailable("\(name) could not be read") }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.first == Substring(header) else { return .unavailable("\(name) has the wrong header") }
        let body = lines.dropFirst()
        let parsed = rows(body.joined(separator: "\n"))
        let skipped = body.count - parsed.count
        if skipped == 0 { return parsed.isEmpty ? .empty : .available(parsed) }
        if parsed.isEmpty { return .unavailable("\(name) has no line that reads") }
        return .partial(parsed, "\(name): \(skipped) line\(skipped == 1 ? "" : "s") could not be read")
    }

    /// Whether `state.json` decodes and records a roll-up.
    static func rolledUp(_ state: URL) -> Bool {
        guard let data = FileManager.default.contents(atPath: state.path),
              let decoded = try? JSONDecoder().decode(AppState.self, from: data) else { return false }
        return decoded.rolledUpAt != nil
    }

    static func firstRun(_ state: URL) -> Bool {
        guard let data = FileManager.default.contents(atPath: state.path) else {
            return !FileManager.default.fileExists(atPath: state.path)
        }
        guard let decoded = try? JSONDecoder().decode(AppState.self, from: data) else { return false }
        return decoded.rolledUpAt == nil
    }
}
