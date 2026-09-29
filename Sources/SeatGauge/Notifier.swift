import Foundation
import SeatGaugeCore
import UserNotifications

/// What the alert needs of Notification Centre, so a case can count banners
/// instead of showing them and `swift test` never reaches the real one.
protocol BannerPosting: Sendable {
    func request() async -> Bool
    func post(_ text: String) async
}

/// The real centre. It is asked for an alert and nothing else, and the banners
/// it posts carry no sound: this is a gauge, not an alarm.
///
/// A bundle whose code-signing identifier does not match `CFBundleIdentifier`
/// is refused here silently, with `UNErrorDomain Code=1`, because usernoted
/// names its client by that identifier. `scripts/build-app.sh` passes
/// `--identifier` for exactly this reason.
final class Notifier: BannerPosting, @unchecked Sendable {
    static let options: UNAuthorizationOptions = [.alert]
    static let sound: UNNotificationSound? = nil

    private let log: @Sendable (String) -> Void

    init(log: @escaping @Sendable (String) -> Void = PollLog.system) { self.log = log }

    func request() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: Self.options)
        } catch {
            log("notifications: \(error.localizedDescription)")
            return false
        }
    }

    func post(_ text: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Seat Gauge"
        content.body = text
        content.sound = Self.sound
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content,
                                            trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            log("notifications: \(error.localizedDescription)")
        }
    }
}

/// The one alert, from the policy in Core to the banner on the screen. It owns
/// the ledger in `state.json`, so a stage fires once per seat per week however
/// often the panel polls.
@MainActor final class Alerter {
    private let notifier: any BannerPosting
    private let store: StateStore
    private var asked = false

    init(notifier: any BannerPosting = Notifier(), store: StateStore = StateStore()) {
        self.notifier = notifier
        self.store = store
    }

    /// A hidden launch argument that posts one test banner.
    static func wantsTestBanner(_ arguments: [String]) -> Bool {
        arguments.contains("--test-notification")
    }

    /// Authorisation is asked for once, on the first thing the app has to say,
    /// which is always after the panel has appeared.
    private func askOnce() async {
        guard !asked else { return }
        asked = true
        _ = await notifier.request()
    }

    /// One poll's answer, read for anything worth saying. The ledger is marked
    /// before the banner is posted, so a slow centre never doubles an alert.
    @discardableResult
    func consider(_ snapshot: Snapshot, seats: [Seat], now: Date) async -> String? {
        guard let due = AlertPolicy.due(in: snapshot, now: now, ledger: store.load().alerts) else { return nil }
        let label = seats.first { $0.id == due.seat }?.label ?? due.seat.rawValue
        let text = AlertPolicy.text(label: label, window: due.window, now: now)
        _ = try? store.update { $0.alerts.mark(due.stage, for: AlertKey(seat: due.seat, resetsAt: due.window.resetsAt)) }
        await askOnce()
        await notifier.post(text)
        return text
    }

    /// `--test-notification`: one banner, and nothing else changed.
    func testBanner() async {
        await askOnce()
        await notifier.post("Seat Gauge is set up to tell you when a week is running out unused.")
    }
}
