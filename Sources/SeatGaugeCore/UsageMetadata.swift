import Foundation

/// JSONDecoder skips every key not asked for without decoding its value, so
/// neither transcript format's content or prompt is ever decoded.
struct UsageMetadata: Decodable {
    let object: [String: Any]
    static let selection = CodingUserInfoKey(rawValue: "usage-metadata-fields")!

    struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let fields = decoder.userInfo[Self.selection] as? Set<String> ?? []
        let values = try decoder.container(keyedBy: Key.self)
        var object: [String: Any] = [:]
        let containers: Set<String> = ["payload", "info", "message", "usage", "total_token_usage",
            "last_token_usage", "output_tokens_details", "cache_creation"]
        for key in values.allKeys where fields.contains(key.stringValue) {
            if let nested = try? values.decode(Self.self, forKey: key) { object[key.stringValue] = nested.object }
            else if containers.contains(key.stringValue) { continue }
            else if let text = try? values.decode(String.self, forKey: key) { object[key.stringValue] = text }
            else if let number = try? values.decode(Int.self, forKey: key) { object[key.stringValue] = NSNumber(value: number) }
            else if let number = try? values.decode(Double.self, forKey: key) { object[key.stringValue] = NSNumber(value: number) }
            // A null or a boolean is a missing value, as before. Anything
            // else left is a number no Double holds, such as 1e400, or an
            // array: kept as a mark, so a reader can refuse the line rather
            // than read the field as absent, which for a count is zero.
            else if (try? values.decodeNil(forKey: key)) == true || (try? values.decode(Bool.self, forKey: key)) != nil {}
            else { object[key.stringValue] = Unreadable() }
        }
        self.object = object
    }

    /// A field that was there but could not be read. No cast a reader
    /// makes matches it, so everywhere but `JSON.isCount` it reads as absent.
    final class Unreadable {}

    static func read(_ data: Data, fields: Set<String>) -> [String: Any]? {
        let decoder = JSONDecoder()
        decoder.userInfo[selection] = fields
        return (try? decoder.decode(Self.self, from: data))?.object
    }
}
