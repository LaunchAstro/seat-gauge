import Foundation

/// What a CLI child starts with. A few variables any program expects come from
/// the parent, and so do the standard proxy settings, so a seat behind a proxy
/// reaches its provider; the fetcher adds what the seat needs; nothing else is
/// inherited. A key the launching shell exported, such as `ANTHROPIC_API_KEY`
/// or `OPENAI_API_KEY`, never reaches a poll, and one CLI's login never
/// reaches the other.
public enum ChildEnvironment {
    public static let inherited = ["PATH", "HOME", "USER", "LANG", "TMPDIR", "SHELL"] + proxies

    /// Both spellings, since tools differ on which one they read.
    static let proxies = ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"].flatMap { [$0, $0.lowercased()] }

    /// `keeping` names parent variables this CLI reads as well, and
    /// `setting` is what the fetcher gives it outright.
    public static func make(from parent: [String: String], keeping: [String] = [],
                            setting: [String: String] = [:]) -> [String: String] {
        var environment = parent.filter { (inherited + keeping).contains($0.key) }
        environment.merge(setting) { _, set in set }
        return environment
    }
}
