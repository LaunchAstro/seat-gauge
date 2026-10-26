import Foundation

/// Whole lines out of a transcript or rollout, a chunk at a time, so a reader
/// holds at most one chunk and one line of the file however big it is. Spend
/// and the Log both read through it.
enum TranscriptLines {
    /// The longest line read. Past it a line is dropped as it streams, and
    /// counted. The longest real lines on a working Mac in October 2026 were
    /// under 2 MB in Claude transcripts and 6 MB in Codex rollouts, both
    /// attachments or tool output rather than the usage lines Spend reads, so
    /// this is well past anything real. With twelve files read at once it
    /// still caps the walk's file bytes in memory near 200 MB.
    static let longestLine = 16 << 20
    static let chunk = 256 << 10

    /// Where a read stopped. `skipping` means `offset` is inside a dropped
    /// line, so the next read discards up to its newline first. That flag is
    /// all a checkpoint keeps of such a line, never its bytes.
    struct Stop: Equatable {
        var offset: UInt64
        var dropped = 0
        var skipping: Bool
    }

    /// Hands `lines` each run of whole lines from `offset` on, every one
    /// ending in a newline and none past `longestLine`. Past `budget` bytes
    /// it reads on only to finish the line in hand, and stops at once inside
    /// a dropped one, so one pass reads at most about `budget` plus a line.
    /// With `tail`, a last line with no newline is handed over too, which is
    /// right for a whole-file read and wrong for one that resumes, where the
    /// line may still be being written. `lines` is also told the offset just
    /// past each run, so a reader that keeps one is right even when a later
    /// read throws.
    static func read(_ url: URL, from offset: UInt64 = 0, skipping: Bool = false, budget: Int = .max,
                     tail: Bool = false, _ lines: (Data, UInt64) throws -> Void) throws -> Stop {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        var stop = Stop(offset: offset, skipping: skipping)
        var rest = Data()
        var bytes = 0
        var ended = false
        while bytes < budget || !rest.isEmpty {
            // FileHandle hands back autoreleased buffers, which would
            // otherwise live until the caller's pool drains: the whole file.
            guard let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: Self.chunk) }),
                  !chunk.isEmpty else { ended = true; break }
            bytes += chunk.count
            var fresh = chunk[...]
            if stop.skipping {
                guard let newline = fresh.firstIndex(of: 0x0A) else {
                    stop.offset += UInt64(fresh.count)
                    continue
                }
                stop.offset += UInt64(fresh.distance(from: fresh.startIndex, to: newline) + 1)
                stop.skipping = false
                fresh = fresh[fresh.index(after: newline)...]
            }
            // The chunk's first newline ends the line `rest` holds, which is
            // the only one that can have grown past the ceiling: every other
            // line in the chunk is shorter than the chunk.
            if let newline = fresh.firstIndex(of: 0x0A),
               rest.count + fresh.distance(from: fresh.startIndex, to: newline) > Self.longestLine {
                stop.offset += UInt64(rest.count + fresh.distance(from: fresh.startIndex, to: newline) + 1)
                stop.dropped += 1
                rest = Data()
                fresh = fresh[fresh.index(after: newline)...]
            }
            // Only the fresh bytes are searched, so a long line is scanned
            // once rather than again with every chunk.
            if let end = fresh.lastIndex(of: 0x0A) {
                rest.append(contentsOf: fresh[...end])
                let run = rest
                stop.offset += UInt64(run.count)
                try autoreleasepool { try lines(run, stop.offset) }
                rest = Data(fresh[fresh.index(after: end)...])
                // Past the budget the line in hand is done; what follows it
                // waits for the next pass.
                if bytes >= budget { rest = Data(); break }
            } else {
                rest.append(contentsOf: fresh)
            }
            if rest.count > Self.longestLine {
                stop.offset += UInt64(rest.count)
                stop.dropped += 1
                stop.skipping = true
                rest = Data()
            }
        }
        if tail, ended, !rest.isEmpty {
            stop.offset += UInt64(rest.count)
            try lines(rest, stop.offset)
        }
        return stop
    }
}
