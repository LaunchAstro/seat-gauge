import Foundation

/// The seats already on this Mac, for first launch to seed `seats.json` with.
public struct SeatDiscovery: Sendable {
    public let home: URL
    public let codexLogin: URL

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                codexLogin: URL = CodexPlanFile.defaultFile) {
        self.home = home
        self.codexLogin = codexLogin
    }

    /// One seat found, as `seats.json` will name it.
    public struct Found: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case claude(profile: URL)
            case codex
        }
        public let id: String
        public let kind: Kind
        public init(id: String, kind: Kind) {
            self.id = id
            self.kind = kind
        }
    }

    /// Where the app keeps Claude seat profiles, under the home.
    public static let profileFolder = ".seat-gauge/profiles"
    /// The seat first launch names when no Claude profile is found.
    public static let freshSeat = "claude"
    public var profileRoot: URL { home.appendingPathComponent(Self.profileFolder, isDirectory: true) }

    public func seats() -> [Found] { [] }
}
