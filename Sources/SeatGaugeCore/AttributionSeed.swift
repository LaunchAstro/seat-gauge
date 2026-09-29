import Foundation

/// One span of a seed file: the user's evidence of which account a directory's
/// login was, before the gauge could observe it. It never enters the repo.
public struct SeedSpan: Decodable, Sendable {
    public let directory: String?
    public let from: Date
    public let to: Date?
    public let account: String
}

public enum SeedOutcome: Equatable, Sendable {
    case wrote(Int)
    case alreadyThere
    case refused(String)

    /// The one sentence the command prints.
    public var sentence: String {
        switch self {
        case let .wrote(count): "Seeded \(count) span(s) into attribution.json."
        case .alreadyThere: "Every span in the seed is already in attribution.json, so nothing changed."
        case let .refused(reason): "Nothing was written: \(reason)."
        }
    }
}

extension AttributionWriter {
    /// Writes the seed's spans that are not there yet, under the writers' lock,
    /// or nothing at all when any of them overlaps a span already present.
    public func seed(_ seed: [SeedSpan], now: Date) -> SeedOutcome {
        let now = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
        var incoming: [String: [AttributionSpan]] = [:]
        for span in seed.sorted(by: { $0.from < $1.from }) {
            incoming[span.directory ?? SpendAttribution.mainDirectory, default: []].append(
                AttributionSpan(from: span.from, to: span.to, lastSeen: span.to == nil ? now : span.from,
                                account: span.account))
        }
        do {
            try AttributionRecord(timeZone: timeZone.identifier, directories: incoming).validate(as: "the seed")
        } catch {
            return .refused("\(error)")
        }
        let lock = FileLock.file(for: file)
        var outcome = SeedOutcome.refused("attribution.json.lock stayed held by another writer")
        _ = try? FileLock.holding(lock, timeout: lockTimeout) {
            var record: AttributionRecord
            switch AttributionFile.read(file) {
            case .malformed: outcome = .refused("attribution record unreadable"); return
            case .missing: record = AttributionRecord(timeZone: timeZone.identifier)
            case let .record(existing): record = existing
            }
            var added = 0
            for (directory, spans) in incoming {
                var present = record.directories[directory] ?? []
                for span in spans where !present.contains(where: { Self.same(span, $0) }) {
                    if present.contains(where: { span.from < $0.end && $0.from < span.end }) {
                        outcome = .refused("the \(span.account) span from \(span.from.ISO8601Format()) "
                                           + "overlaps a span already in attribution.json")
                        return
                    }
                    present.append(span)
                    added += 1
                }
                record.directories[directory] = present.sorted { $0.from < $1.from }
            }
            guard added > 0 else { outcome = .alreadyThere; return }
            do {
                try record.validate()
                try JSONEncoder.attribution.encode(record).write(to: file, options: .atomic)
                outcome = .wrote(added)
            } catch {
                outcome = .refused("\(error)")
            }
        }
        return outcome
    }

    /// The same span, whatever an observation has since done to `lastSeen`.
    static func same(_ one: AttributionSpan, _ two: AttributionSpan) -> Bool {
        one.from == two.from && one.to == two.to && one.account == two.account
    }
}
