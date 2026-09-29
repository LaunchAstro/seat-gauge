import Foundation
import SeatGaugeCore

/// `seatgauge-cli state [--file <path>] [range W|M|6M|Y] [measure tokens|usd]`:
/// sets the card detail's range and measure through the same locked writer
/// the app uses, then prints both. With nothing to set it only prints them.
func state(_ arguments: ArraySlice<String>) throws {
    var words = Array(arguments)
    var file = StateStore.defaultFile
    if words.first == "--file", words.count > 1 {
        file = URL(fileURLWithPath: words[1])
        words.removeFirst(2)
    }
    var range: HistoryRange?
    var measure: Measure?
    while words.count >= 2 {
        switch (words[0], words[1]) {
        case let ("range", value): range = try HistoryRange(rawValue: value) ?? refuse(value, "W, M, 6M or Y")
        case let ("measure", value): measure = try Measure(rawValue: value) ?? refuse(value, "tokens or usd")
        default: throw ProcessFailure("state: \(words[0]) is neither range nor measure")
        }
        words.removeFirst(2)
    }
    guard words.isEmpty else { throw ProcessFailure("state: \(words[0]) takes a value") }
    let store = StateStore(file: file)
    let now = range == nil && measure == nil ? store.load() : try store.update {
        if let range { $0.historyRange = range }
        if let measure { $0.measure = measure }
    }
    print("range \(now.historyRange.rawValue), measure \(now.measure.rawValue)")
}

private func refuse<T>(_ value: String, _ allowed: String) throws -> T {
    throw ProcessFailure("state: \(value) is not one of \(allowed)")
}
