import Foundation

/// What one poll saw of the main login (ADR 0005): the seat whose login it
/// is, no seat's, or not enough to say.
public enum IdentityObservation: Equatable, Sendable {
    case match(String)
    case noMatch
    case incomplete
}

/// A stretch of time a directory's usage belongs to one account, half open:
/// `[from, to)`. An open span (`to` absent) covers `[from, lastSeen)`, since
/// only an observation extends it. `lastSeen` is the latest observation that
/// saw the account, and equals `from` on a span nothing observed.
public struct AttributionSpan: Codable, Equatable, Sendable {
    public var from: Date
    public var to: Date?
    public var lastSeen: Date
    public var account: String

    public init(from: Date, to: Date? = nil, lastSeen: Date, account: String) {
        self.from = from
        self.to = to
        self.lastSeen = lastSeen
        self.account = account
    }

    /// Where the span's cover ends.
    public var end: Date { to ?? lastSeen }
}

/// Why a record cannot be trusted, in words.
public struct AttributionProblem: Error, Equatable, CustomStringConvertible {
    public let reason: String
    public var description: String { reason }
}

/// `attribution.json`: per `spend.csv` directory, the spans that say which
/// seat its usage belongs to, and the zone its local hours are read in, fixed
/// when the file is first written.
public struct AttributionRecord: Codable, Equatable, Sendable {
    public static let unattributed = "unattributed"

    public var timeZone: String
    public var directories: [String: [AttributionSpan]]

    public init(timeZone: String, directories: [String: [AttributionSpan]] = [:]) {
        self.timeZone = timeZone
        self.directories = directories
    }

    /// Ordered, non-overlapping and half open, with at most one open span per
    /// directory and that one last.
    public func validate(as name: String = "attribution.json") throws {
        for (directory, spans) in directories {
            func refuse(_ why: String) -> AttributionProblem {
                AttributionProblem(reason: "\(name): \(directory) \(why)")
            }
            for (index, span) in spans.enumerated() {
                guard !span.account.isEmpty else { throw refuse("has a span with no account") }
                guard span.from <= span.lastSeen else { throw refuse("has a span seen before it starts") }
                if let to = span.to {
                    guard span.from < to else { throw refuse("has an empty span") }
                    guard span.lastSeen <= to else { throw refuse("has a span seen after it ends") }
                } else if index != spans.count - 1 {
                    throw refuse("has an open span that is not its last")
                }
                if index > 0, let before = spans[index - 1].to, before > span.from {
                    throw refuse("has spans out of order or overlapping")
                }
            }
        }
    }
}

extension JSONEncoder {
    /// Instants in ISO 8601, keys sorted, so the file reads and diffs plainly.
    public static var attribution: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    public static var attribution: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Reading `attribution.json`. Only `AttributionWriter` writes it.
public enum AttributionFile {
    public static var defaultFile: URL { AppPaths.support.appendingPathComponent("attribution.json") }

    public enum Read: Equatable, Sendable {
        case missing
        case record(AttributionRecord)
        case malformed(String)
    }

    public static func read(_ file: URL) -> Read {
        guard let data = FileManager.default.contents(atPath: file.path) else {
            return FileManager.default.fileExists(atPath: file.path)
                ? .malformed("attribution.json could not be read") : .missing
        }
        do {
            let record = try JSONDecoder.attribution.decode(AttributionRecord.self, from: data)
            try record.validate()
            return .record(record)
        } catch let problem as AttributionProblem {
            return .malformed(problem.reason)
        } catch {
            return .malformed("attribution.json: \(error)")
        }
    }

    /// The record to read spend through. A missing or malformed file holds no
    /// spans, so every cell reads as unattributed.
    public static func record(at file: URL) -> AttributionRecord {
        if case let .record(record) = read(file) { return record }
        return AttributionRecord(timeZone: TimeZone.current.identifier)
    }
}
