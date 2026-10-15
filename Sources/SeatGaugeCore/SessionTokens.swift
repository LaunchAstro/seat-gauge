import Foundation

/// Only complete lines advance the offset. A crash can reread bytes, but
/// cannot publish half an event or retain a prompt in the checkpoint.
struct SessionTokens: Codable, Sendable {
    var offset: UInt64 = 0
    var identity: UInt64 = 0
    var session: String?
    var model = "unknown"
    var baseline: [String: Int]?
    var seen: Set<String> = []
    var models: [String: TokenCounts] = [:]
    var complete = false

    mutating func read(_ url: URL, tool: String, budget: Int = 32 << 20, after prior: [String: Int]? = nil,
                       excluding messages: Set<String> = []) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        if inode != identity || size < offset { self = SessionTokens(); identity = inode }
        if offset == 0 { baseline = prior }
        if tool == "claude" { seen.formUnion(messages) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        var bytes = 0
        var rest = Data()
        while bytes < budget || !rest.isEmpty {
            guard var chunk = try handle.read(upToCount: 256 << 10), !chunk.isEmpty else { break }
            let finishing = bytes >= budget
            let boundary = finishing ? chunk.firstIndex(of: 0x0A) : nil
            if let boundary { chunk = Data(chunk[...boundary]) }
            bytes += chunk.count
            rest.append(chunk)
            if let end = rest.lastIndex(of: 0x0A) {
                let data = Data(rest[...end])
                if tool == "codex" {
                    for line in CodexRollout.candidates(data) {
                        switch CodexRollout.decode(line) {
                        case let .session(id, _): if session == nil { session = id }
                        case let .model(named): model = named
                        case let .tokens(at, total?, last) where at != nil:
                            let step = CodexRollout.contribution(total: total, last: last, after: baseline)
                            baseline = step.baseline
                            if step.added.values.contains(where: { $0 > 0 }) {
                                models[model, default: TokenCounts()] = models[model, default: TokenCounts()]
                                    + CodexRollout.counts(step.added)
                            }
                        default: break
                        }
                    }
                } else {
                    let reading = ClaudeCollector.read(data: data, primer: AppPaths.primer, seen: &seen)
                    for response in reading.responses {
                        let name = response.model.replacingOccurrences(of: "[1m]", with: "")
                        models[name, default: TokenCounts()] = models[name, default: TokenCounts()] + response.counts
                    }
                }
                offset += UInt64(data.count)
                rest = Data(rest[rest.index(after: end)...])
            }
            if finishing, boundary != nil { break }
        }
        complete = offset == size
    }

    var total: TokenCounts { models.values.reduce(TokenCounts(), +) }
}
