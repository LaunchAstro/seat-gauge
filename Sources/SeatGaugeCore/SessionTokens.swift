import Foundation

/// Only a whole line moves the offset on. A checkpoint keeps the numeric usage
/// events, so a resume can be put back in order exactly as Spend orders it.
struct SessionTokens: Codable, Sendable {
    var offset: UInt64 = 0
    var identity: UInt64 = 0
    var session: String?
    var cwd: String?
    var firstToken: Date?
    var model = "unknown"
    var baseline: [String: Int]?
    var seen: Set<String> = []
    var models: [String: TokenCounts] = [:]
    var events: [CodexRollout.Event] = []
    var responses: [SpendResponse] = []
    var complete = false
    /// True when `offset` is inside a line too long to read, so the next pass
    /// discards up to its newline. Optional so a checkpoint written before it
    /// still reads.
    var skipping: Bool?

    mutating func read(_ url: URL, tool: String, budget: Int = 32 << 20) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        if inode != identity || size < offset { self = SessionTokens(); identity = inode }
        let stop = try TranscriptLines.read(url, from: offset, skipping: skipping ?? false, budget: budget) { data, through in
            if tool == "codex" {
                for line in CodexRollout.candidates(data) {
                    switch CodexRollout.decode(line) {
                    case let .session(id, folder): if session == nil { session = id; cwd = folder }
                    case let .model(named): model = named
                    case let .tokens(at, total, last):
                        if firstToken == nil { firstToken = at }
                        if let total {
                            events.append(CodexRollout.Event(at: at, model: model, total: total, last: last))
                            if at != nil {
                                let step = CodexRollout.contribution(total: total, last: last, after: baseline)
                                baseline = step.baseline
                                if step.added.values.contains(where: { $0 > 0 }) {
                                    models[model, default: TokenCounts()] += CodexRollout.counts(step.added)
                                }
                            }
                        }
                    default: break
                    }
                }
            } else {
                let reading = ClaudeCollector.read(data: data, primer: AppPaths.primer, seen: &seen)
                responses += reading.responses
                for response in reading.responses {
                    models[response.filedModel, default: TokenCounts()] += response.counts
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

    func rollout(_ url: URL) -> CodexRollout.Rollout {
        CodexRollout.Rollout(url: url, session: session, cwd: cwd, firstToken: firstToken, events: events, skipped: 0)
    }

    var total: TokenCounts { models.values.reduce(TokenCounts(), +) }
}
