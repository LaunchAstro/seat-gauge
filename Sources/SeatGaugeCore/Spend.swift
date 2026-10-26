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

    /// The most one field of one log line may say: a thousand million
    /// million tokens, past any real response or session by a factor of
    /// millions. A reader refuses a line over it, so a corrupt or hostile log
    /// is an unreadable line rather than a sum that overflows.
    public static let ceiling = 1_000_000_000_000_000

    /// Field by field, held at the largest and smallest `Int` rather than
    /// trapping: the counts come from files on disk and from other machines,
    /// and a trap would end the always-on app, which would meet the same
    /// files again on relaunch.
    public static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(responses: sum(a.responses, b.responses), input: sum(a.input, b.input),
                    output: sum(a.output, b.output), thinking: sum(a.thinking, b.thinking),
                    cacheRead: sum(a.cacheRead, b.cacheRead),
                    cacheWrite5m: sum(a.cacheWrite5m, b.cacheWrite5m),
                    cacheWrite1h: sum(a.cacheWrite1h, b.cacheWrite1h))
    }

    public static func - (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        func less(_ x: Int, _ y: Int) -> Int {
            let (out, over) = x.subtractingReportingOverflow(y)
            return over ? (y > 0 ? .min : .max) : out
        }
        return TokenCounts(responses: less(a.responses, b.responses), input: less(a.input, b.input),
                           output: less(a.output, b.output), thinking: less(a.thinking, b.thinking),
                           cacheRead: less(a.cacheRead, b.cacheRead),
                           cacheWrite5m: less(a.cacheWrite5m, b.cacheWrite5m),
                           cacheWrite1h: less(a.cacheWrite1h, b.cacheWrite1h))
    }

    /// Whole numbers added the way `+` adds counts: held at the largest or
    /// smallest `Int` rather than trapping. For the totals drawn from counts.
    public static func sum(_ parts: Int...) -> Int {
        parts.reduce(0) { total, part in
            let (out, over) = total.addingReportingOverflow(part)
            return over ? (part > 0 ? .max : .min) : out
        }
    }

    /// Everything but thinking, which is inside output already.
    public var total: Int { Self.sum(input, output, cacheRead, cacheWrite5m, cacheWrite1h) }

    public static func += (a: inout TokenCounts, b: TokenCounts) { a = a + b }
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

    /// The bundled list prices, per million tokens; Fable's two ids are priced apart. Haiku and the
    /// OpenAI models other than Sol are grouped as "other", the display group the panel totals
    /// everything else under. OpenAI caches carry no write charge in these logs, so only a read
    /// price is given. GPT-5.6 Sol is at its list price, not the short promotional one.
    public static let bundled = RateCard(version: "2026-10", models: [
        "claude-opus-5-5": Rate(input: 4, output: 20, cacheRead: Decimal(string: "0.20")!, group: "Opus"),
        "claude-opus-5": Rate(input: 5, output: 25, group: "Opus"),
        "claude-opus-4-8": Rate(input: 5, output: 25, group: "Opus"),
        "claude-fable-5": Rate(input: 10, output: 50, cacheRead: 1, group: "Fable"),
        "claude-fable-5-1": Rate(input: 10, output: 50, cacheRead: Decimal(string: "0.25")!,
                                 group: "Fable"),
        "claude-sonnet-5-5": Rate(input: 2, output: 10, cacheRead: Decimal(string: "0.20")!, group: "Sonnet"),
        "claude-sonnet-5": Rate(input: 2, output: 10, group: "Sonnet"),
        "claude-haiku-5-5": Rate(input: Decimal(string: "0.10")!, output: Decimal(string: "0.50")!, group: "other"),
        "claude-haiku-4-5-20251001": Rate(input: 1, output: 5, group: "other"),
        "gpt-6.1-sol": Rate(input: 2, output: 10, cacheRead: Decimal(string: "0.10")!, group: "Sol"),
        "gpt-6-sol": Rate(input: 2, output: 10, cacheRead: Decimal(string: "0.20")!, group: "Sol"),
        "gpt-5.6-sol": Rate(input: 5, output: 30, cacheRead: Decimal(string: "0.50")!, group: "Sol"),
        "gpt-6-astra": Rate(input: 10, output: 50, cacheRead: 1, group: "other"),
        "gpt-6-luna": Rate(input: Decimal(string: "0.10")!, output: Decimal(string: "0.50")!,
                           cacheRead: Decimal(string: "0.01")!, group: "other"),
        "gpt-5.6-terra": Rate(input: 2, output: 12, cacheRead: Decimal(string: "0.20")!, group: "other"),
        "gpt-5.5": Rate(input: 5, output: 30, cacheRead: Decimal(string: "0.50")!, group: "other"),
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
/// Cells sort in the record's order: seat, day, hour, model.
public struct SpendCell: Hashable, Sendable, Comparable {
    public let seat, day, hour, model: String

    public init(seat: String, day: String, hour: String, model: String) {
        self.seat = seat
        self.day = day
        self.hour = hour
        self.model = model
    }

    public static func < (a: SpendCell, b: SpendCell) -> Bool {
        (a.seat, a.day, a.hour, a.model) < (b.seat, b.day, b.hour, b.model)
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

    public init(cell: SpendCell, counts: TokenCounts, usd: Decimal?, sealed: Bool) {
        self.init(seat: cell.seat, day: cell.day, hour: cell.hour, model: cell.model,
                  counts: counts, usd: usd, sealed: sealed)
    }

    public var counts: TokenCounts {
        TokenCounts(responses: responses, input: input, output: output, thinking: thinking,
                    cacheRead: cacheRead, cacheWrite5m: cacheWrite5m, cacheWrite1h: cacheWrite1h)
    }

    public var cell: SpendCell { SpendCell(seat: seat, day: day, hour: hour, model: model) }

    /// The same row, sealed. Sealing is one way: a cell that has been closed
    /// is never opened again by a later run.
    public func sealing(_ shut: Bool) -> SpendRow {
        SpendRow(cell: cell, counts: counts, usd: usd, sealed: sealed || shut)
    }
}
