import Foundation

/// The tokens one response, or one bucket of responses, is made of. The
/// thinking figure is a part of `output` rather than a charge beside it, so it
/// is carried for the record and never priced twice.
public struct TokenCounts: Equatable, Sendable, Codable {
    public var responses, input, output, thinking, cacheRead, cacheWrite5m, cacheWrite1h: Int

    public init(responses: Int = 0, input: Int = 0, output: Int = 0, thinking: Int = 0,
                cacheRead: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0) {
        self.responses = responses
        self.input = input
        self.output = output
        self.thinking = thinking
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
    }

    public static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(responses: a.responses + b.responses, input: a.input + b.input,
                    output: a.output + b.output, thinking: a.thinking + b.thinking,
                    cacheRead: a.cacheRead + b.cacheRead,
                    cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m,
                    cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h)
    }

    public static func - (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(responses: a.responses - b.responses, input: a.input - b.input,
                    output: a.output - b.output, thinking: a.thinking - b.thinking,
                    cacheRead: a.cacheRead - b.cacheRead,
                    cacheWrite5m: a.cacheWrite5m - b.cacheWrite5m,
                    cacheWrite1h: a.cacheWrite1h - b.cacheWrite1h)
    }
}

/// One model's list price, per million tokens. The three cache figures are
/// derived from input when the card does not give them: a tenth for a read,
/// 1.25 times for a 5-minute write and twice for a 1-hour write. `group` is
/// display only, so Fable's two ids can be priced apart and drawn together.
public struct Rate: Equatable, Sendable, Codable {
    public let input, output: Decimal
    public let cacheRead, cacheWrite5m, cacheWrite1h: Decimal?
    public let group: String

    public init(input: Decimal, output: Decimal, cacheRead: Decimal? = nil,
                cacheWrite5m: Decimal? = nil, cacheWrite1h: Decimal? = nil, group: String) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.group = group
    }

    public var readCache: Decimal { cacheRead ?? input * Decimal(string: "0.1")! }
    public var write5m: Decimal { cacheWrite5m ?? input * Decimal(string: "1.25")! }
    public var write1h: Decimal { cacheWrite1h ?? input * 2 }
}

/// The versioned rate table beside the roll-up, keyed on the raw model id. A
/// model the table does not carry is unpriced, which is not the same as free:
/// the roll-up leaves its `usd` blank and the panel totals it under its own
/// heading rather than folding a guess into the figure.
public struct RateCard: Equatable, Sendable, Codable {
    public let version: String
    public let models: [String: Rate]

    public init(version: String, models: [String: Rate]) {
        self.version = version
        self.models = models
    }

    /// The bundled list prices; Fable's two ids are priced apart. Haiku is priced and grouped as "other", which is the
    /// display group the panel totals everything else under.
    public static let bundled = RateCard(version: "2026-09", models: [
        "claude-opus-5": Rate(input: 5, output: 25, group: "Opus"),
        "claude-fable-5": Rate(input: 10, output: 50, cacheRead: 1, group: "Fable"),
        "claude-fable-5-1": Rate(input: 10, output: 50, cacheRead: Decimal(string: "0.25")!,
                                 group: "Fable"),
        "claude-sonnet-5": Rate(input: 2, output: 10, group: "Sonnet"),
        "claude-haiku-4-5-20251001": Rate(input: 1, output: 5, group: "other"),
    ])

    public static var defaultFile: URL { AppPaths.support.appendingPathComponent("rates.json") }

    public func rate(for model: String) -> Rate? { models[model] }

    /// Nil where the card has no rate: an unpriced bucket, not a free one.
    public func usd(model: String, counts: TokenCounts) -> Decimal? {
        guard let rate = rate(for: model) else { return nil }
        var total = Decimal(counts.input) * rate.input
        total += Decimal(counts.output) * rate.output
        total += Decimal(counts.cacheRead) * rate.readCache
        total += Decimal(counts.cacheWrite5m) * rate.write5m
        total += Decimal(counts.cacheWrite1h) * rate.write1h
        return total / Decimal(1_000_000)
    }

    /// The display group the rate table names for a model. The Spend tab heads
    /// by `ModelFamily` and `priceStatus` instead.
    public func group(for model: String) -> String { rate(for: model)?.group ?? "unpriced" }

    /// A card that is not there, or will not decode, leaves the bundled one in
    /// use. Pricing nothing is worse than pricing on a table one version old.
    public static func load(_ file: URL = RateCard.defaultFile,
                            log: (String) -> Void = { _ in }) -> RateCard {
        guard let data = FileManager.default.contents(atPath: file.path) else { return .bundled }
        do {
            return try JSONDecoder().decode(RateCard.self, from: data)
        } catch {
            log("rates: \(file.lastPathComponent) could not be read, the bundled card stays in use")
            return .bundled
        }
    }

    public func write(to file: URL) throws {
        let writer = JSONEncoder()
        writer.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try writer.encode(self).write(to: file, options: .atomic)
    }
}

/// A model's family, read from its name alone, first match wins. It is not
/// its price: whether a model is priced is the rate table's question.
public enum ModelFamily: String, CaseIterable, Sendable {
    case opus = "Opus", fable = "Fable", sonnet = "Sonnet", sol = "Sol", other

    public init(model: String) {
        let name = model.lowercased()
        self = [.opus, .fable, .sonnet, .sol].first { name.contains($0.rawValue.lowercased()) } ?? .other
    }
}

public enum PriceStatus: Sendable { case priced, unpriced }

extension RateCard {
    /// Priced only for a model the versioned table carries.
    public func priceStatus(for model: String) -> PriceStatus { rate(for: model) == nil ? .unpriced : .priced }
}

/// What a row is keyed on: the four columns that make one cell of the CSV.
public struct SpendCell: Hashable, Sendable {
    public let seat, day, hour, model: String

    public init(seat: String, day: String, hour: String, model: String) {
        self.seat = seat
        self.day = day
        self.hour = hour
        self.model = model
    }
}

/// One line of `spend.csv`. `seat` is the profile directory
/// name, `day` and `hour` are local, and `usd` is blank for a model the rate
/// card does not carry.
public struct SpendRow: Equatable, Sendable, Codable {
    public let seat, day, hour, model: String
    public let responses, input, output, thinking, cacheRead, cacheWrite5m, cacheWrite1h: Int
    public let usd: Decimal?
    public let sealed: Bool

    public init(seat: String, day: String, hour: String, model: String,
                counts: TokenCounts, usd: Decimal?, sealed: Bool) {
        self.seat = seat
        self.day = day
        self.hour = hour
        self.model = model
        responses = counts.responses
        input = counts.input
        output = counts.output
        thinking = counts.thinking
        cacheRead = counts.cacheRead
        cacheWrite5m = counts.cacheWrite5m
        cacheWrite1h = counts.cacheWrite1h
        self.usd = usd
        self.sealed = sealed
    }

    public var counts: TokenCounts {
        TokenCounts(responses: responses, input: input, output: output, thinking: thinking,
                    cacheRead: cacheRead, cacheWrite5m: cacheWrite5m, cacheWrite1h: cacheWrite1h)
    }

    public var cell: SpendCell { SpendCell(seat: seat, day: day, hour: hour, model: model) }

    /// The same row, sealed. Sealing is one way: a cell that has been closed
    /// is never opened again by a later run.
    public func sealing(_ shut: Bool) -> SpendRow {
        SpendRow(seat: seat, day: day, hour: hour, model: model, counts: counts, usd: usd,
                 sealed: sealed || shut)
    }
}
