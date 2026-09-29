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

    /// ISO 8601 with fractional seconds, as the Claude reply writes it, or
    /// without, or epoch seconds, as the Codex reply writes it.
    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
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
            if let date = reader.date(from: text) { return date }
        }
        return nil
    }
}
