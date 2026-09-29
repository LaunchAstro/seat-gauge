import Foundation

/// Daily copies of the token history. Once transcripts age out, `spend.csv`
/// and `attribution.json` are the only record, so one bad write could lose it.
/// Each day gets a folder in `backups/` named by the date, the last 30 are
/// kept, and a day whose files match the newest copy gets none. The copies
/// stay in the support folder, which Time Machine already covers.
public struct HistoryBackup: Sendable {
    public static let kept = 30
    public static let names = ["spend.csv", "attribution.json"]

    let support: URL
    let calendar: Calendar

    public init(support: URL, calendar: Calendar = .current) {
        self.support = support
        self.calendar = calendar
    }

    var folder: URL { support.appendingPathComponent("backups", isDirectory: true) }

    /// The day's copy, if it is due, then the pruning. Only ever reads the live
    /// files: a copy is built in a hidden folder and renamed into place whole,
    /// so a failure leaves at most that hidden folder, which the next run clears.
    /// Returns the folder written, or nil when none was due.
    @discardableResult
    public func run(now: Date) throws -> URL? {
        let manager = FileManager.default
        let day = SpendCSV.columns(at: now, calendar: calendar).day
        let target = folder.appendingPathComponent(day, isDirectory: true)
        defer { prune() }

        let live = Self.names.compactMap { name in
            manager.contents(atPath: support.appendingPathComponent(name).path).map { (name, $0) }
        }
        // A copy missing a file would still claim the day, so it waits for both.
        guard live.count == Self.names.count, !manager.fileExists(atPath: target.path) else { return nil }
        if let newest = days().last {
            let previous = folder.appendingPathComponent(newest, isDirectory: true)
            let current = Dictionary(uniqueKeysWithValues: live)
            let same = Self.names.allSatisfy { name in
                current[name] == manager.contents(atPath: previous.appendingPathComponent(name).path)
            }
            if same { return nil }
        }

        let partial = folder.appendingPathComponent(".\(day)", isDirectory: true)
        try? manager.removeItem(at: partial)
        do {
            try manager.createDirectory(at: partial, withIntermediateDirectories: true)
            for (name, data) in live {
                try data.write(to: partial.appendingPathComponent(name))
            }
            try manager.moveItem(at: partial, to: target)
        } catch {
            try? manager.removeItem(at: partial)
            throw error
        }
        return target
    }

    /// The dated folders, oldest first. A date sorts as its own text.
    func days() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { SpendCSV.start(day: $0, calendar: calendar) != nil }.sorted()
    }

    func prune() {
        for day in days().dropLast(Self.kept) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(day, isDirectory: true))
        }
    }
}
