import Foundation

/// The hand-written CLI transcripts in `Tests/Fixtures/`, one per seat, named
/// `<seat>-<date>.jsonl`.
public enum Fixture {
    public static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Support
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("Fixtures", isDirectory: true)

    public struct Missing: Error, CustomStringConvertible {
        public let seat: String
        public var description: String { "no \(seat)-<date>.jsonl in Tests/Fixtures" }
    }

    /// The newest transcript for `seat`, as the lines the CLI printed.
    public static func lines(_ seat: String) throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("\(seat)-") && $0.hasSuffix(".jsonl") }.sorted()
        guard let name = names.last else { throw Missing(seat: seat) }
        return try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
