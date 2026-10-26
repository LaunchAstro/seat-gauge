import Foundation

/// Only a whole line moves the offset on. The checkpoint keeps what resumes
/// an incremental read and no record per message (issue #120): for Claude, a
/// digest of each message the file counts and the totals they make; for
/// Codex, the file's first usage event, what it adds after that, and the
/// total it ends on, which is all a resume needs to be put in order exactly
/// as Spend orders it. A Codex file whose usage fields change inside it
/// keeps no more: a resume after another file reads its usage lines again.
struct SessionTokens: Sendable {
    var offset: UInt64 = 0
    var identity: UInt64 = 0
    var complete = false
    /// True when `offset` is inside a line too long to read, so the next pass
    /// discards up to its newline.
    var skipping: Bool?
    /// What the file adds read alone: for Claude, the messages it counts;
    /// for Codex, every event measured from no earlier total.
    var models: [String: TokenCounts] = [:]

    var counted = MessageDigests()
    /// The files that were counting a message when this one read it. When
    /// one of them stops counting anything, `rescan` reads this file again
    /// from its start, keeping what it counts, so it takes over what nobody
    /// counts now.
    var deferredTo: Set<String> = []
    var rescan = false

    var session: String?
    var cwd: String?
    var firstToken: Date?
    var model = "unknown"
    /// The total the last usage event left.
    var baseline: [String: Int]?
    /// The first usage event, the one a resume measures against the file
    /// before it, and what the events after it add.
    var head: CodexRollout.Event?
    var after: [String: TokenCounts] = [:]
    var resetAfter = false
    /// True when an event after the head carries a usage field the head did
    /// not, or no `total_tokens`. Then what the file adds after an earlier
    /// file depends on more than its head.
    var uneven = false

    /// A checkpoint written before issue #120 kept every response, and which
    /// file counted each lives in `SessionCheckpoint`, so it migrates there.
    var legacy: [SpendResponse]?

    /// `countedBy` names the other file that counts a message already.
    mutating func read(_ url: URL, tool: String, budget: Int = 32 << 20,
                       countedBy: (UInt64) -> String? = { _ in nil }) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        // A file cut short or replaced is a new file, a rescan included.
        if inode != identity || size < offset {
            self = SessionTokens(); identity = inode
        } else if rescan {
            offset = 0; skipping = nil
        }
        rescan = false
        let stop = try TranscriptLines.read(url, from: offset, skipping: skipping ?? false, budget: budget) { data, through in
            if tool == "codex" {
                for line in CodexRollout.candidates(data) {
                    switch CodexRollout.decode(line) {
                    case let .session(id, folder): if session == nil { session = id; cwd = folder }
                    case let .model(named): model = named
                    case let .tokens(at, total, last):
                        if firstToken == nil { firstToken = at }
                        if let total, let at { add(CodexRollout.Event(at: at, model: model, total: total, last: last)) }
                    default: break
                    }
                }
            } else {
                // Each read starts its own set: the digests are what carry a
                // message from one read to the next.
                var fresh: Set<String> = []
                for response in ClaudeCollector.read(data: data, primer: AppPaths.primer, seen: &fresh).responses {
                    let digest = MessageDigests.digest(response.messageID)
                    guard !counted.contains(digest) else { continue }
                    if let owner = countedBy(digest) {
                        deferredTo.insert(owner)
                    } else {
                        counted.insert(digest)
                        models[response.filedModel, default: TokenCounts()] += response.counts
                    }
                }
            }
            // Moved with each run, so a read that fails later in the pass
            // leaves the offset on what was counted, and nothing is counted twice.
            offset = through
            skipping = nil
        }
        offset = stop.offset
        skipping = stop.skipping ? true : nil
        complete = offset == size
    }

    /// One timestamped usage event, measured from the one before it.
    mutating func add(_ event: CodexRollout.Event) {
        let step = CodexRollout.contribution(total: event.total, last: event.last, after: baseline)
        let adds = step.added.values.contains { $0 > 0 }
        if adds { models[event.model, default: TokenCounts()] += CodexRollout.counts(step.added) }
        if let head {
            if step.reset { resetAfter = true }
            if adds { after[event.model, default: TokenCounts()] += CodexRollout.counts(step.added) }
            if event.total["total_tokens"] == nil || !Set(event.total.keys).isSubset(of: head.total.keys) { uneven = true }
        } else {
            head = event
            if event.total["total_tokens"] == nil { uneven = true }
        }
        baseline = step.baseline
    }

    /// What the file at `url` adds after an earlier one that ended on
    /// `entry`, and the total it ends on. With nothing before it, the file is
    /// what it adds alone. Nil when an uneven file cannot be read again.
    func added(after entry: [String: Int]?, url: URL) -> (models: [String: TokenCounts], baseline: [String: Int]?)? {
        guard let head else { return ([:], entry) }
        guard let entry, let baseline else { return (models, self.baseline) }
        if uneven {
            // Measured again from `entry`, event by event, as Spend reads it.
            // Never seen on a real Mac, where Codex writes the same fields
            // throughout a file.
            guard let rollout = CodexRollout.parse(url) else { return nil }
            var replay = SessionTokens()
            replay.baseline = entry
            for event in rollout.events where event.at != nil { replay.add(event) }
            return (replay.models, replay.baseline)
        }
        let step = CodexRollout.contribution(total: head.total, last: head.last, after: entry)
        var models = after
        if step.added.values.contains(where: { $0 > 0 }) {
            models[head.model, default: TokenCounts()] += CodexRollout.counts(step.added)
        }
        // Without a fall to zero, a field the file never wrote keeps the
        // value the earlier file left.
        return (models, step.reset || resetAfter ? baseline : entry.merging(baseline) { _, fresh in fresh })
    }

    var total: TokenCounts { models.values.reduce(TokenCounts(), +) }
}

extension SessionTokens: Codable {
    enum CodingKeys: String, CodingKey {
        case offset, identity, complete, skipping, models, counted, deferredTo, rescan
        case session, cwd, firstToken, model, baseline, head, after, resetAfter, uneven
        case responses, seen, events
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        offset = try values.decodeIfPresent(UInt64.self, forKey: .offset) ?? 0
        identity = try values.decodeIfPresent(UInt64.self, forKey: .identity) ?? 0
        complete = try values.decodeIfPresent(Bool.self, forKey: .complete) ?? false
        skipping = try values.decodeIfPresent(Bool.self, forKey: .skipping)
        models = try values.decodeIfPresent([String: TokenCounts].self, forKey: .models) ?? [:]
        counted = try values.decodeIfPresent(MessageDigests.self, forKey: .counted) ?? MessageDigests()
        deferredTo = try values.decodeIfPresent(Set<String>.self, forKey: .deferredTo) ?? []
        rescan = try values.decodeIfPresent(Bool.self, forKey: .rescan) ?? false
        session = try values.decodeIfPresent(String.self, forKey: .session)
        cwd = try values.decodeIfPresent(String.self, forKey: .cwd)
        firstToken = try values.decodeIfPresent(Date.self, forKey: .firstToken)
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? "unknown"
        baseline = try values.decodeIfPresent([String: Int].self, forKey: .baseline)
        head = try values.decodeIfPresent(CodexRollout.Event.self, forKey: .head)
        after = try values.decodeIfPresent([String: TokenCounts].self, forKey: .after) ?? [:]
        resetAfter = try values.decodeIfPresent(Bool.self, forKey: .resetAfter) ?? false
        uneven = try values.decodeIfPresent(Bool.self, forKey: .uneven) ?? false
        if let responses = try values.decodeIfPresent([SpendResponse].self, forKey: .responses), !responses.isEmpty {
            legacy = responses
        }
        // The old shape kept every Codex event and no head, so the new one is
        // built by reading them again in order, as a read of the file would.
        if values.contains(.seen), let events = try values.decodeIfPresent([CodexRollout.Event].self, forKey: .events) {
            models = [:]; baseline = nil; head = nil; after = [:]; resetAfter = false; uneven = false
            for event in events where event.at != nil { add(event) }
        }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(offset, forKey: .offset)
        try values.encode(identity, forKey: .identity)
        try values.encode(complete, forKey: .complete)
        try values.encodeIfPresent(skipping, forKey: .skipping)
        if !models.isEmpty { try values.encode(models, forKey: .models) }
        if !counted.isEmpty { try values.encode(counted, forKey: .counted) }
        if !deferredTo.isEmpty { try values.encode(deferredTo.sorted(), forKey: .deferredTo) }
        if rescan { try values.encode(rescan, forKey: .rescan) }
        try values.encodeIfPresent(session, forKey: .session)
        try values.encodeIfPresent(cwd, forKey: .cwd)
        try values.encodeIfPresent(firstToken, forKey: .firstToken)
        if model != "unknown" { try values.encode(model, forKey: .model) }
        try values.encodeIfPresent(baseline, forKey: .baseline)
        try values.encodeIfPresent(head, forKey: .head)
        if !after.isEmpty { try values.encode(after, forKey: .after) }
        if resetAfter { try values.encode(resetAfter, forKey: .resetAfter) }
        if uneven { try values.encode(uneven, forKey: .uneven) }
    }
}

/// Claude message ids, each kept as a 64-bit FNV-1a digest and written as
/// eight bytes in one base64 string, so an id costs about 11 bytes on disk
/// rather than the 60 it took as text. Two of the ids a checkpoint holds
/// sharing a digest is about as likely as one in 10^10, and would leave one
/// response uncounted.
struct MessageDigests: Codable, Sendable, Equatable {
    private(set) var values: Set<UInt64> = []

    static func digest(_ id: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        return hash
    }

    var isEmpty: Bool { values.isEmpty }
    func contains(_ digest: UInt64) -> Bool { values.contains(digest) }
    @discardableResult mutating func insert(_ digest: UInt64) -> Bool { values.insert(digest).inserted }

    init() {}

    init(from decoder: any Decoder) throws {
        let data = try decoder.singleValueContainer().decode(Data.self)
        guard data.count % 8 == 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "a digest is 8 bytes"))
        }
        values = Set(stride(from: 0, to: data.count, by: 8).map { start in
            data[data.startIndex + start ..< data.startIndex + start + 8].reversed().reduce(0) { $0 << 8 | UInt64($1) }
        })
    }

    func encode(to encoder: any Encoder) throws {
        var data = Data(capacity: values.count * 8)
        for value in values.sorted() { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        var container = encoder.singleValueContainer()
        try container.encode(data)
    }
}
