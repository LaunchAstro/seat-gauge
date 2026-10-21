import AppKit
import Foundation
import Testing

@testable import SeatGauge

/// The app's wake source: `NSWorkspace.didWakeNotification`, as a stream the
/// seat loop reads.
@Suite struct WakeSourceTests {
    @Test func aPostedWakeIsAWake() async {
        let center = NotificationCenter()
        let wakes = WakeSource.stream(center: center)
        let heard = Task { () -> Bool in
            for await _ in wakes { return true }
            return false
        }
        // The observer is in place before the stream is returned.
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await heard.value)
    }
}
