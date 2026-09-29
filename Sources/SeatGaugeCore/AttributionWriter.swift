import Foundation

/// The one writer of `attribution.json`. Each change reads the
/// file, applies the change and writes it back atomically, all under an
/// exclusive lock on `attribution.json.lock`, so the seeding command can never
/// write between the read and the write. A malformed file is never written
/// over: the writer stops, says so in `problem`, and reads again next time.
public actor AttributionWriter {
    let file: URL
    let timeZone: TimeZone
    let lockTimeout: Duration
    /// Directories whose open span an unrecorded observation has cut: the next
    /// successful observation starts a new span even for the same account.
    private var broken: Set<String> = []
    public private(set) var problem: PanelProblem?

    public init(file: URL = AttributionFile.defaultFile, timeZone: TimeZone = .current,
                lockTimeout: Duration = .seconds(10)) {
        self.file = file
        self.timeZone = timeZone
        self.lockTimeout = lockTimeout
    }

    public func observe(_ observation: IdentityObservation,
                        directory: String = SpendAttribution.mainDirectory, now: Date) {
        let account: String
        switch observation {
        case .incomplete: broken.insert(directory); return
        case .noMatch: account = AttributionRecord.unattributed
        case let .match(seat): account = seat
        }
        let now = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
        let cut = broken.contains(directory)
        let wrote = change { record in
            var spans = record.directories[directory] ?? []
            Self.observe(account, at: now, cut: cut, into: &spans)
            record.directories[directory] = spans
        }
        if wrote { broken.remove(directory) } else { broken.insert(directory) }
    }

    /// Extends the open span when the account is the same and nothing cut it;
    /// otherwise closes it at `lastSeen`, files the gap as unattributed, and
    /// opens a new span at `now`.
    static func observe(_ account: String, at now: Date, cut: Bool, into spans: inout [AttributionSpan]) {
        guard var open = spans.last, open.to == nil else {
            spans.append(AttributionSpan(from: now, lastSeen: now, account: account))
            return
        }
        guard now > open.lastSeen else { return }
        if open.account == account, !cut {
            open.lastSeen = now
            spans[spans.count - 1] = open
            return
        }
        spans.removeLast()
        if open.from < open.lastSeen {
            open.to = open.lastSeen
            spans.append(open)
        }
        spans.append(AttributionSpan(from: open.lastSeen, to: now, lastSeen: open.lastSeen,
                                     account: AttributionRecord.unattributed))
        spans.append(AttributionSpan(from: now, lastSeen: now, account: account))
    }

    /// One read, change and write under the lock. False when nothing was
    /// written: the lock was held, the file is malformed, or the write failed.
    @discardableResult
    func change(_ apply: (inout AttributionRecord) -> Void) -> Bool {
        let lock = FileLock.file(for: file)
        var read: AttributionFile.Read?
        let wrote = (try? FileLock.holding(lock, timeout: lockTimeout) { () -> Bool in
            read = AttributionFile.read(file)
            var record: AttributionRecord
            switch read {
            case let .record(existing): record = existing
            case .missing: record = AttributionRecord(timeZone: timeZone.identifier)
            case .malformed, nil: return false
            }
            apply(&record)
            guard (try? record.validate()) != nil,
                  let data = try? JSONEncoder.attribution.encode(record) else { return false }
            return (try? data.write(to: file, options: .atomic)) != nil
        }) ?? false
        // A held lock read nothing, so it says nothing about the file.
        if let read {
            if case .malformed = read { problem = .attributionRecord } else { problem = nil }
        }
        return wrote
    }
}
