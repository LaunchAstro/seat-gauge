import Foundation
import SeatGaugeCore

/// `seatgauge-cli import-codex`: a one-off read of every Codex session log
/// still on disk into `spend.csv`, adding only the cells the record lacks.
/// Prints each day it added and its tokens, then the total.
func importCodex() async throws {
    let rates = RateCard.load(RateCard.defaultFile) { print($0) }
    guard let added = try await SpendCoordinator(log: { print($0) })
        .importCodex(rates: rates, now: Date()) else { return }
    guard !added.isEmpty else { print("import-codex: nothing to add"); return }
    let byDay = Dictionary(grouping: added, by: \.day)
    for day in byDay.keys.sorted() {
        print("\(day)  \(tokens(byDay[day]!).formatted()) tokens")
    }
    print("added \(tokens(added).formatted()) tokens over \(byDay.count) day(s) "
          + "in \(added.count) row(s) of \(SpendCSV.defaultFile.path)")
}

/// Input, output and cache tokens. Thinking is a part of output, so it is
/// not added again.
func tokens(_ rows: [SpendRow]) -> Int {
    rows.reduce(0) { $0 + $1.input + $1.output + $1.cacheRead + $1.cacheWrite5m + $1.cacheWrite1h }
}
