import Foundation

/// The small reading both parsers share. Transport values arrive as whatever
/// `JSONSerialization` made of them, and a value of the wrong shape is a
/// missing value rather than a trap.
enum JSON {
    static func object(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    /// A JSON boolean is an `NSNumber` too, and on Darwin one holding 0 or 1
    /// bridges to `Bool` as well, so the boolean is told apart by its type id.
    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// A token count: a whole number from zero to `TokenCounts.ceiling`. A
    /// count outside that is a broken line rather than a figure, and turning
    /// it away here is what keeps the sums after it from overflowing.
    /// Nil for a missing value as well; `isCount` tells the two apart.
    static func count(_ value: Any?) -> Int? {
        guard let number = int(value), (0 ... TokenCounts.ceiling).contains(number) else { return nil }
        // `intValue` saturates a fraction too big for an Int rather than
        // refusing it, so the Double is checked against the range as well.
        if let number = value as? NSNumber, !(0 ... Double(TokenCounts.ceiling)).contains(number.doubleValue) {
            return nil
        }
        return number
    }

    /// Whether a value is absent or a readable count, so a reader can drop a
    /// line whose count is broken instead of reading it as zero.
    static func isCount(_ value: Any?) -> Bool { value == nil || value is NSNull || count(value) != nil }

    /// A fractional number, told from a boolean the same way. `utilization` on
    /// a `rate_limit_event` arrives this way, as a fraction of the window.
    static func fraction(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return finite(number.doubleValue) }
        if let text = value as? String { return Double(text).flatMap(finite) }
        return nil
    }

    /// `"nan"` and `"inf"` are Doubles the reader makes and conversion traps on.
    private static func finite(_ number: Double) -> Double? { number.isFinite ? number : nil }

    static func text(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// The span a date read from a reply or a log may fall in: 1970 to the
    /// year 3000. No reset or timestamp is outside it, and a countdown to
    /// anything inside it fits an `Int`, where one to `1e30` traps.
    static let dates = 0.0 ... 32_503_680_000.0

    /// ISO 8601 with fractional seconds, as the Claude reply writes it, or
    /// without, or epoch seconds, as the Codex reply writes it. Nil outside
    /// `dates`.
    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            guard dates.contains(number.doubleValue) else { return nil }
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        guard let text = value as? String else { return nil }
        let spellings: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
        ]
        for options in spellings {
            let reader = ISO8601DateFormatter()
            reader.formatOptions = options
            if let date = reader.date(from: text) { return dates.contains(date.timeIntervalSince1970) ? date : nil }
        }
        return nil
    }
}
