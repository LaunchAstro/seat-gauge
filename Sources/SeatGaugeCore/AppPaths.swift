import Foundation

/// The folders the app keeps, named off the running bundle identifier as the
/// File System Programming Guide asks.
public enum AppPaths {
    public static let bundleID = "com.launchastro.seatgauge"

    /// The running bundle's identifier when it is this app's under a suffix,
    /// such as the `.dev` build `make app` makes, so a clone's build never
    /// shares the installed app's folder. The CLI and a test
    /// process have no bundle of ours and read the app's own. An empty suffix
    /// is no build.
    public static func identifier(running: String?) -> String {
        guard let running, running.hasPrefix(bundleID + "."), running.count > bundleID.count + 1
        else { return bundleID }
        return running
    }

    public static func support(identifier: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        return (base.first ?? URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent(identifier, isDirectory: true)
    }

    public static var support: URL { support(identifier: identifier(running: Bundle.main.bundleIdentifier)) }

    /// The working directory the gauge's own Claude calls run in, so their
    /// transcripts land somewhere the spend roll-up can exclude.
    public static var primer: URL { support.appendingPathComponent("primer", isDirectory: true) }

    /// The working directory the gauge's own `codex app-server` polls run in,
    /// beside the Claude one, so the Codex roll-up can exclude them.
    public static var codexPrimer: URL { support.appendingPathComponent("codex-primer", isDirectory: true) }

    /// `primer` and both builds' primers of the same name beside it, the
    /// installed app's and the `.dev` one's, so neither build counts the
    /// other's polling.
    public static func primers(beside primer: URL) -> [String] {
        let name = primer.standardizedFileURL.lastPathComponent
        let base = primer.standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
        return [primer.standardizedFileURL.path] + [bundleID, bundleID + ".dev"].map {
            base.appendingPathComponent("\($0)/\(name)").path
        }
    }
}
