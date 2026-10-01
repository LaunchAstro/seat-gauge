import Foundation

/// Stub for the red run: today's behaviour, no shell asked.
public struct LoginShell: Sendable {
    public let executable: URL
    public let environment: [String: String]
    public let timeout: Duration

    public init(executable: URL, environment: [String: String], timeout: Duration = .seconds(3)) {
        self.executable = executable
        self.environment = environment
        self.timeout = timeout
    }

    public static func user(parent: [String: String] = ProcessInfo.processInfo.environment) -> LoginShell? {
        parent["SHELL"].map { LoginShell(executable: URL(fileURLWithPath: $0), environment: parent) }
    }

    public func path() -> [String]? { nil }
}

public final class SearchPath: @unchecked Sendable {
    public static let shared = SearchPath(shell: nil, home: NSHomeDirectory())
    let home: String

    public init(shell: LoginShell?, home: String) { self.home = home }

    public func directories() -> [String] {
        ["/opt/homebrew/bin", home + "/.local/bin", home + "/.bun/bin"]
    }

    public func joined(after path: String?) -> String {
        ((path.map { [$0] } ?? []) + directories()).joined(separator: ":")
    }
}
