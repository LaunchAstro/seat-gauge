import AppKit

/// The machine's wakes, from `NSWorkspace.didWakeNotification`, as the stream
/// `Poll` reads. Core is Foundation only, so the app hands them in.
nonisolated enum WakeSource {
    /// The observer is in place before this returns, and goes when the
    /// stream ends. Wakes nobody has read yet count as one.
    static func stream(center: NotificationCenter = NSWorkspace.shared.notificationCenter) -> AsyncStream<Void> {
        let (wakes, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observer = Observer(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                   queue: nil) { _ in wake.yield(()) })
        wake.onTermination = { _ in center.removeObserver(observer.token) }
        return wakes
    }

    /// The observer's token, which only `removeObserver` ever reads.
    private final class Observer: @unchecked Sendable {
        let token: any NSObjectProtocol
        init(_ token: any NSObjectProtocol) { self.token = token }
    }
}
