import Foundation

/// One assistant response, as the roll-up keeps it before it is bucketed.
public struct SpendResponse: Equatable, Sendable {
    public let requestID, messageID, model: String
    public let at: Date
    public let counts: TokenCounts
}

/// What one transcript gave up: its responses, the session cost it carries if
/// it carries one, and how many lines could not be read.
public struct FileReading: Sendable {
    public let responses: [SpendResponse]
    public let sessionCosts: [String: Double]
    public let skipped: Int
}

/// Walks the Claude transcripts into cells for the spend coordinator.
///
/// The figure it produces is a floor. Background calls are billed and barely
/// transcribed, and the logs are pruned at 30 days, so the roll-up undercounts
/// in one direction only and each session's own `cost-state` total is kept
/// beside it to keep the gap measurable.
public struct ClaudeCollector: Sendable {
    let primer: URL
    let calendar: Calendar
    let lanes: Int

    public init(primer: URL = AppPaths.primer, calendar: Calendar = .current,
                lanes: Int = max(2, min(12, ProcessInfo.processInfo.activeProcessorCount))) {
        self.primer = primer
        self.calendar = calendar
        self.lanes = lanes
    }

    func collect(_ profiles: [SpendProfile], rolledUpAt: Date?, now: Date) async throws -> SpendCollection {
        let files = Self.transcripts(profiles, rolledUpAt: rolledUpAt, now: now, calendar: calendar)
        var out = SpendCollection(files: files.count)
        var seen: Set<String> = []
        for (seat, reading) in try await walk(files) {
            out.skipped += reading.skipped
            out.sessionCosts.merge(reading.sessionCosts) { _, fresh in fresh }
            for response in reading.responses {
                // The same response is written to the transcript more than
                // once, about twice per response.
                guard seen.insert("\(response.requestID) \(response.messageID)").inserted else { continue }
                out.responses += 1
                let cell = self.cell(seat: seat, response: response)
                out.cells[cell] = (out.cells[cell] ?? TokenCounts()) + response.counts
            }
        }
        return out
    }

    /// The local day, hour and model one response buckets under. `[1m]` is
    /// stripped, which merges a long-context request into its model's row:
    /// fewer rows, at the cost of understating a 1M-context premium if one is
    /// ever charged.
    func cell(seat: String, response: SpendResponse) -> SpendCell {
        let at = SpendCSV.columns(at: response.at, calendar: calendar)
        return SpendCell(seat: seat, day: at.day, hour: at.hour,
                         model: response.model.replacingOccurrences(of: "[1m]", with: ""))
    }

    /// Every `.jsonl` under each profile's `projects/`, which is where the
    /// `<session>/subagents/` files are as well. The first run, with no
    /// roll-up behind it, reads all 28 days, because that walk is the only
    /// thing that ever builds the history the CSV then keeps.
    ///
    /// After it, a transcript is passed by only when both tests hold: it has
    /// not been written since that roll-up, which is the run that counted it,
    /// and every cell it can feed has sealed. Either alone loses tokens. The
    /// sealing test alone skips a file the last run never saw, so a gap in
    /// roll-ups spanning a cell's open life closes it on one of its feeders.
    /// The written-since test alone skips a session gone quiet while its cell
    /// is open, and since a cell is `(seat, day, hour, model)` that several
    /// sessions share, the merge then replaces it without them.
    static func transcripts(_ profiles: [SpendProfile], rolledUpAt: Date?, now: Date,
                            calendar: Calendar) -> [(String, URL)] {
        var files: [(String, URL)] = []
        for profile in profiles {
            guard let walk = FileManager.default.enumerator(
                at: profile.projects, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walk where url.pathExtension == "jsonl" {
                if let rolledUpAt,
                   let changed = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                       .contentModificationDate,
                   changed <= rolledUpAt,
                   SpendCSV.sealedThrough(lastWrite: changed, now: now, calendar: calendar) { continue }
                files.append((profile.seat, url))
            }
        }
        return files
    }

    /// The files are read a few at a time on the cooperative pool: the walk is
    /// all file reading and JSON, and the panel is never waiting on it.
    func walk(_ files: [(String, URL)]) async throws -> [(String, FileReading)] {
        guard !files.isEmpty else { return [] }
        let primer = primer
        return try await withThrowingTaskGroup(of: (String, FileReading).self) { group in
            var out: [(String, FileReading)] = []
            out.reserveCapacity(files.count)
            var next = 0
            for _ in 0 ..< min(lanes, files.count) {
                let (seat, url) = files[next]; next += 1
                group.addTask { (seat, Self.read(file: url, primer: primer)) }
            }
            while let done = try await group.next() {
                out.append(done)
                if next < files.count {
                    let (seat, url) = files[next]; next += 1
                    group.addTask { (seat, Self.read(file: url, primer: primer)) }
                }
            }
            return out
        }
    }

    // MARK: - One file

    /// `type == "assistant"` lines carrying `message.usage`, deduped inside the
    /// file, with `<synthetic>` and the gauge's own primer calls left out, and
    /// each `cost-state` total picked up on the way past.
    public static func read(file: URL, primer: URL) -> FileReading {
        guard let data = try? Data(contentsOf: file) else {
            return FileReading(responses: [], sessionCosts: [:], skipped: 0)
        }
        let here = AppPaths.primers(beside: primer)
        var responses: [SpendResponse] = []
        var costs: [String: Double] = [:]
        var seen: Set<String> = []
        var skipped = 0

        for line in Self.candidates(data) {
            // Half the assistant lines in a transcript are a response already
            // counted, so the pair is read out of the raw bytes first and the
            // JSON reader is never asked about a line that is one.
            if let already = Self.pairKey(line), seen.contains(already) { continue }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                skipped += 1
                continue
            }
            let kind = object["type"] as? String
            if kind == "cost-state" {
                if let session = object["sessionId"] as? String,
                   let total = object["totalCostUSD"] as? Double { costs[session] = total }
                continue
            }
            guard kind == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let model = message["model"] as? String, model != "<synthetic>",
                  let request = object["requestId"] as? String,
                  let id = message["id"] as? String,
                  let at = JSON.date(object["timestamp"]) else { continue }
            // Either build's own Claude calls run in its `primer/`, and counting
            // them would have the panel report its polling as the user's work.
            if let cwd = object["cwd"] as? String, here.contains(where: { (cwd + "/").hasPrefix($0 + "/") }) { continue }
            guard seen.insert("\(request) \(id)").inserted else { continue }
            responses.append(SpendResponse(requestID: request, messageID: id, model: model,
                                           at: at, counts: Self.counts(usage)))
        }
        return FileReading(responses: responses, sessionCosts: costs, skipped: skipped)
    }

    static func counts(_ usage: [String: Any]) -> TokenCounts {
        let creation = usage["cache_creation"] as? [String: Any]
        let written = JSON.int(usage["cache_creation_input_tokens"]) ?? 0
        return TokenCounts(
            responses: 1,
            input: JSON.int(usage["input_tokens"]) ?? 0,
            output: JSON.int(usage["output_tokens"]) ?? 0,
            thinking: JSON.int((usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"]) ?? 0,
            cacheRead: JSON.int(usage["cache_read_input_tokens"]) ?? 0,
            // Without the split, every write is priced as the 5-minute one,
            // which is the cheaper of the two and keeps the figure a floor.
            cacheWrite5m: creation.flatMap { JSON.int($0["ephemeral_5m_input_tokens"]) } ?? written,
            cacheWrite1h: creation.flatMap { JSON.int($0["ephemeral_1h_input_tokens"]) } ?? 0)
    }

    /// The lines worth decoding. A transcript is mostly attachments and user
    /// turns, and handing all of them to the JSON reader costs more than the
    /// whole roll-up is allowed, so the kind is read out of the raw bytes
    /// first, in one pass, and only the two kinds that matter are decoded.
    /// The lines come back as slices of the file rather than copies of it.
    static func candidates(_ data: Data) -> [Data] {
        let key = Array(#""type":"#.utf8)
        let assistant = Array("assistant".utf8)
        let costState = Array("cost-state".utf8)
        var lines: [Range<Int>] = []
        data.withUnsafeBytes { raw in
            guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = raw.count
            var start = 0
            var index = 0
            while index <= count {
                guard index == count || bytes[index] == 0x0A else { index += 1; continue }
                if index > start, wanted(bytes, start ..< index, key, assistant, costState) {
                    lines.append(start ..< index)
                }
                start = index + 1
                index += 1
            }
        }
        let origin = data.startIndex
        return lines.map { data[(origin + $0.lowerBound) ..< (origin + $0.upperBound)] }
    }

    /// `"type"` and the value beside it, found without the JSON reader being
    /// asked about the line. A space after the colon is allowed, since nothing
    /// promises the writer stays compact.
    static func wanted(_ bytes: UnsafePointer<UInt8>, _ line: Range<Int>,
                       _ key: [UInt8], _ assistant: [UInt8], _ costState: [UInt8]) -> Bool {
        guard line.count > key.count else { return false }
        let last = line.upperBound - key.count
        var at = line.lowerBound
        while at <= last {
            if bytes[at] == 0x22 {
                var offset = 1
                while offset < key.count, bytes[at + offset] == key[offset] { offset += 1 }
                if offset == key.count {
                    var value = at + key.count
                    while value < line.upperBound, bytes[value] == 0x20 { value += 1 }
                    if value < line.upperBound, bytes[value] == 0x22 {
                        if holds(bytes, value + 1, assistant, line.upperBound)
                            || holds(bytes, value + 1, costState, line.upperBound) { return true }
                    }
                }
            }
            at += 1
        }
        return false
    }

    /// `(requestId, message.id)` read out of the raw bytes, for the one thing
    /// it is safe to decide without the JSON reader: whether this line is a
    /// response already counted. Anything it cannot read with certainty, an
    /// escaped value or a message id that is not Anthropic's `msg_` shape,
    /// comes back nil and the line is parsed in full.
    static func pairKey(_ line: Data) -> String? {
        let requestKey = Array(#""requestId":""#.utf8)
        let messageKey = Array(#""message":{"#.utf8)
        let idKey = Array(#""id":""#.utf8)
        return line.withUnsafeBytes { raw -> String? in
            guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let count = raw.count
            guard let request = quoted(bytes, count, after: requestKey, from: 0),
                  let message = find(bytes, count, messageKey, from: 0),
                  let id = quoted(bytes, count, after: idKey, from: message),
                  id.hasPrefix("msg_") else { return nil }
            return "\(request) \(id)"
        }
    }

    static func find(_ bytes: UnsafePointer<UInt8>, _ count: Int, _ needle: [UInt8],
                     from: Int) -> Int? {
        guard needle.count <= count else { return nil }
        var at = from
        let last = count - needle.count
        while at <= last {
            if bytes[at] == needle[0], holds(bytes, at, needle, count) { return at + needle.count }
            at += 1
        }
        return nil
    }

    /// The quoted value after `needle`. An escape inside it gives up rather
    /// than guessing, because this is a shortcut and never the only reader.
    static func quoted(_ bytes: UnsafePointer<UInt8>, _ count: Int, after needle: [UInt8],
                       from: Int) -> String? {
        guard let start = find(bytes, count, needle, from: from) else { return nil }
        var end = start
        while end < count, bytes[end] != 0x22 {
            if bytes[end] == 0x5C { return nil }
            end += 1
        }
        guard end < count, end > start else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes + start, count: end - start),
                      as: UTF8.self)
    }

    static func holds(_ bytes: UnsafePointer<UInt8>, _ at: Int, _ needle: [UInt8],
                      _ end: Int) -> Bool {
        guard at + needle.count <= end else { return false }
        var offset = 0
        while offset < needle.count, bytes[at + offset] == needle[offset] { offset += 1 }
        return offset == needle.count
    }
}
