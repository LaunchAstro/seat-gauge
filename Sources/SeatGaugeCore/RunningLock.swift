import Foundation

/// Held by the app for as long as it runs: an exclusive lock on `running.lock`
/// in its Application Support folder. The seed command takes the same lock, so
/// it refuses while the app is running and the app cannot start mid-seed
/// without knowing. The lock goes when the holder is released or
/// the process ends.
public final class RunningLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(_ descriptor: Int32) { self.descriptor = descriptor }

    /// The lock, or nil when another process holds it.
    public static func claim(in folder: URL = AppPaths.support) -> RunningLock? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.appendingPathComponent("running.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return RunningLock(descriptor)
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
