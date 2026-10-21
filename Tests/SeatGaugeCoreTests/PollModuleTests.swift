import Foundation
import Testing

import SeatGaugeCore

/// The seat loop as every front end starts it: `Poll`, from the config file
/// and a few options.
@Suite struct PollModuleTests {
    typealias Loop = ConfigAndPollTests

    static func scratch() -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-poll-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static let tokenLine = "{ \"id\": \"paid\", \"label\": \"Paid\", \"kind\": \"claude\", \"profile\": \"~/profiles/paid\", \"token\": \"~/paid.token\" }"

    // MARK: - The primer

    @Test("proof: a Claude read whose primer folder is missing fails before the CLI starts")
    func missingPrimerFailsTheClaudeRead() async {
        let folder = Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let missing = folder.appendingPathComponent("primer", isDirectory: true)
        let seat = Seat(id: SeatID(rawValue: "work"), label: "Work",
                        kind: .claude(profileDir: folder.appendingPathComponent("profile")))
        let fetched = await ClaudeFetcher(runner: RealProcessRunner(), primer: missing)
            .fetch(seat, now: Date(), last: nil)
        guard case .unreadable = fetched.state else {
            Issue.record("a read with no primer folder was \(fetched.state)")
            return
        }
        #expect(fetched.lines.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test("starting the loop makes the primer folder the Claude reads run in")
    func pollMakesThePrimer() throws {
        let folder = Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let seats = folder.appendingPathComponent("seats.json")
        try Data(Loop.config(Loop.workLine).utf8).write(to: seats)
        let primer = folder.appendingPathComponent("primer", isDirectory: true)
        _ = try Poll(file: seats, readings: folder.appendingPathComponent("readings.json"), primer: primer)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: primer.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    // MARK: - Wake

    @Test("a wake is a timer poll: the seats that poll themselves are read and a token seat is not")
    func wakeReadsFreeSeatsOnly() async throws {
        let folder = Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let seats = folder.appendingPathComponent("seats.json")
        try Data(Loop.config("\(Loop.workLine), \(Self.tokenLine)").utf8).write(to: seats)
        let clock = Loop.TestClock(parks: true)
        let counter = Loop.Counter()
        let (wakes, wake) = AsyncStream<Void>.makeStream()
        let poll = try Poll(file: seats, readings: folder.appendingPathComponent("readings.json"),
                            primer: folder.appendingPathComponent("primer"),
                            options: Poll.Options(wakes: wakes, wakeDelay: .zero, log: { _ in },
                                                  fetcher: { _ in Loop.CountingFetcher(counter: counter, gate: nil) }),
                            clock: clock)
        let loop = Task { await poll.run() }
        try await Loop.waitUntil("the first poll and its sleep") { counter.finished == 1 && clock.sleeps.count == 1 }
        wake.yield(())
        try await Loop.waitUntil("the wake poll and its sleep") { counter.finished == 2 && clock.sleeps.count == 2 }
        #expect(counter.seats == ["work", "work"])
        loop.cancel()
        clock.release()
        _ = await loop.value
    }

    @Test("a wake polls only after its delay, so the network is back")
    func wakeWaitsForTheNetwork() async throws {
        let clock = Loop.TestClock(parks: true)
        let (raw, wake) = AsyncStream<Void>.makeStream()
        let delayed = Wake.after(raw, delay: .seconds(5), clock: clock)
        let heard = Loop.Counter()
        let listening = Task { for await _ in delayed { heard.begin("wake") } }
        wake.yield(())
        try await Loop.waitUntil("the wake to wait") { clock.sleeps.count == 1 }
        #expect(clock.sleeps == [.seconds(5)])
        #expect(heard.started == 0)
        clock.release()
        try await Loop.waitUntil("the wake to arrive") { heard.started == 1 }
        listening.cancel()
    }
}
