import Foundation
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// Every suite that draws the panel or builds a window reads or writes
/// `GaugeMirror.shared`: its text size, appearance, vertical factor, detail
/// choice and hovered card. Resetting those between cases is not enough while
/// two such cases can run at once, since one can change the mirror while the
/// other waits at an `await`. So each case of a suite carrying this trait
/// holds one lock file for its whole run, and starts and ends on the mirror's
/// resting values. The lock is `flock` on one path, which two opens in one
/// process contend for.
struct SharedMirror: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    static let lock = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("seat-gauge-shared-mirror.lock")

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        guard testCase != nil else { return try await function() }
        try await FileLock.holdingAsync(Self.lock, timeout: .seconds(900)) {
            await Self.rest()
            do { try await function() } catch { await Self.rest(); throw error }
            await Self.rest()
        }
    }

    @MainActor static func rest() {
        let mirror = GaugeMirror.shared
        mirror.verticalFactor = 1
        mirror.choice = DetailChoice()
        mirror.hover(nil)
    }
}

extension Trait where Self == SharedMirror {
    static var sharedMirror: SharedMirror { SharedMirror() }
}
