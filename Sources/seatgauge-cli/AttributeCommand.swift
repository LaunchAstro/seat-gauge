import Foundation
import SeatGaugeCore

/// `seatgauge-cli attribute --seed <file> [--record <attribution.json>]`: files
/// the main login's past under accounts from a local seed file, once. It holds
/// `running.lock` for the whole run, so it refuses while the app is running.
func attribute(_ arguments: ArraySlice<String>) async {
    var words = Array(arguments)
    var seedFile: URL?
    var record = AttributionFile.defaultFile
    while words.count >= 2 {
        switch words[0] {
        case "--seed": seedFile = URL(fileURLWithPath: words[1])
        case "--record": record = URL(fileURLWithPath: words[1])
        default: refuse("\(words[0]) is not --seed or --record")
        }
        words.removeFirst(2)
    }
    guard words.isEmpty, let seedFile else { refuse("usage is attribute --seed <file> [--record <file>]") }
    guard let running = RunningLock.claim(in: record.deletingLastPathComponent()) else {
        refuse("Seat Gauge is running, so quit it and seed again")
    }
    guard let data = FileManager.default.contents(atPath: seedFile.path) else {
        refuse("\(seedFile.lastPathComponent) could not be read")
    }
    guard let spans = try? JSONDecoder.attribution.decode([SeedSpan].self, from: data) else {
        refuse("\(seedFile.lastPathComponent) is not a JSON list of spans")
    }
    let outcome = await AttributionWriter(file: record).seed(spans, now: Date())
    withExtendedLifetime(running) {}
    if case .refused = outcome { refuse(outcome) }
    print(outcome.sentence)
}

private func refuse(_ reason: String) -> Never { refuse(.refused(reason)) }

private func refuse(_ outcome: SeedOutcome) -> Never {
    FileHandle.standardError.write(Data((outcome.sentence + "\n").utf8))
    exit(1)
}
