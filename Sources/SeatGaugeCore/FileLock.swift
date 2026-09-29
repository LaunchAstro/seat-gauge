import Foundation

/// An exclusive `flock` on a sibling lock file, held while a record is read,
/// changed and written, so the app and `seatgauge-cli` never interleave on
/// one record. The lock belongs to the open file description, so a second
/// open in the same process waits exactly as another process would.
public enum FileLock {
    /// Another writer held the lock for longer than the caller would wait.
    public struct Busy: Error, Equatable, CustomStringConvertible {
        public let lock: URL
        public var description: String { "\(lock.lastPathComponent) is held by another writer" }
    }

    /// `<record>.lock`, beside the record it guards.
    public static func file(for record: URL) -> URL {
        record.deletingLastPathComponent().appendingPathComponent(record.lastPathComponent + ".lock")
    }

    /// Runs `body` holding the lock, or throws `Busy` without running it.
    public static func holding<T>(_ lock: URL, timeout: Duration, _ body: () throws -> T) throws -> T {
        let descriptor = try open(lock)
        defer { close(descriptor) }
        let deadline = ContinuousClock.now + timeout
        while try !taken(descriptor, lock, deadline) { usleep(20_000) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// The same lock around a body that suspends, such as the spend
    /// coordinator's walk, waited for without holding a thread.
    public static func holdingAsync<T>(_ lock: URL, timeout: Duration,
                                       _ body: @Sendable () async throws -> T) async throws -> T {
        let descriptor = try open(lock)
        defer { close(descriptor) }
        let deadline = ContinuousClock.now + timeout
        while try !taken(descriptor, lock, deadline) { try await Task.sleep(for: .milliseconds(20)) }
        defer { flock(descriptor, LOCK_UN) }
        return try await body()
    }

    private static func open(_ lock: URL) throws -> Int32 {
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let descriptor = Darwin.open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw Busy(lock: lock) }
        return descriptor
    }

    /// True once the lock is held; false to wait and try again; `Busy` once
    /// the deadline has passed or the failure is not contention.
    private static func taken(_ descriptor: Int32, _ lock: URL, _ deadline: ContinuousClock.Instant) throws -> Bool {
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
        guard errno == EWOULDBLOCK, ContinuousClock.now < deadline else { throw Busy(lock: lock) }
        return false
    }
}
