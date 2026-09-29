import Foundation

/// Codex's session logs as a source for the spend coordinator: which rollout
/// files a run reads, and the cells they give, with the gauge's own polls
/// left out. The parsing is `CodexRollout`'s.
public struct CodexCollector: Sendable {
    public let sessions: URL
    public let primer: URL

    public init(sessions: URL = CodexCollector.defaultSessions, primer: URL = AppPaths.codexPrimer) {
        self.sessions = sessions
        self.primer = primer
    }

    public static var defaultSessions: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    /// A file whose session could not be keyed counts as a skipped line.
    func collect(rolledUpAt: Date?, now: Date, calendar: Calendar) -> SpendCollection {
        let files = Self.rollouts(in: sessions, rolledUpAt: rolledUpAt, now: now, calendar: calendar)
        let reading = CodexRollout.read(files: files, calendar: calendar,
                                        excluding: AppPaths.primers(beside: primer))
        return SpendCollection(cells: reading.cells,
                               responses: reading.cells.values.reduce(0) { $0 + $1.responses },
                               files: files.count, skipped: reading.skipped + reading.unkeyed)
    }

    /// Every `rollout-*.jsonl` under `sessions` that this run has to read.
    ///
    /// The Claude walk's rule, applied to a whole session rather than a file:
    /// a session is passed by only when every file of it is unchanged since
    /// the last roll-up and every cell it can feed has sealed. A resume
    /// continues the file before it, so reading one file of a session without
    /// the rest would lose the baseline and count its opening total again.
    /// A file whose session cannot be told from its first line is always read.
    static func rollouts(in sessions: URL, rolledUpAt: Date?, now: Date, calendar: Calendar) -> [URL] {
        guard let walk = FileManager.default.enumerator(
            at: sessions, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var bySession: [String: [URL]] = [:]
        var always: [URL] = []
        for case let url as URL in walk
        where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
            guard let session = firstSession(of: url) else { always.append(url); continue }
            bySession[session, default: []].append(url)
        }
        var files = always
        for group in bySession.values {
            let passable = rolledUpAt.map { rolledUpAt in
                group.allSatisfy { url in
                    guard let changed = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate else { return false }
                    return changed <= rolledUpAt
                        && SpendCSV.sealedThrough(lastWrite: changed, now: now, calendar: calendar)
                }
            } ?? false
            if !passable { files += group }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// The session a rollout's first line names, read without the rest of it.
    static func firstSession(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var line = Data()
        while line.count < 16 << 20, let chunk = try? handle.read(upToCount: 64 << 10), !chunk.isEmpty {
            if let end = chunk.firstIndex(of: 0x0A) {
                line.append(chunk[chunk.startIndex ..< end])
                break
            }
            line.append(chunk)
        }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "session_meta" else { return nil }
        return (object["payload"] as? [String: Any])?["id"] as? String
    }
}
