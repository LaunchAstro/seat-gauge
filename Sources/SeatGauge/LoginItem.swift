import Foundation
import Observation
import SeatGaugeCore
import ServiceManagement

/// What the app needs of `SMAppService`, so `swift test` registers nothing on
/// the machine it runs on.
protocol LoginItemService: Sendable {
    func register() throws
    func unregister() throws
    var status: SMAppService.Status { get }
}

/// The real one. `SMAppService.mainApp` registers the app bundle itself, which
/// is why the app has to be the one in `/Applications` when it asks.
struct MainAppService: LoginItemService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// Launch at login, and the menu tick over it.
///
/// `register()` is idempotent, so it runs on every launch rather than being
/// remembered anywhere, and it runs only from `/Applications`: reading or
/// registering from a second copy repoints the record at that copy, and then
/// the login item is the copy in `dist/` that the next build deletes. The
/// user's refusal is the one thing that is remembered, in `state.json`.
/// Observed, so the Settings window's switch follows the menu's.
@MainActor @Observable final class LoginItem {
    private let service: any LoginItemService
    private let bundle: URL
    private let store: StateStore
    private let log: (String) -> Void

    /// What the last register or unregister could not do, for the menu.
    private(set) var problem: String?
    /// The status is the service's and changes where nothing here sees it: a
    /// toggle, or an approval in System Settings. Reading `status` reads this,
    /// so bumping it redraws whatever showed the old one.
    private var looks = 0

    init(service: any LoginItemService = MainAppService(),
         bundle: URL = Bundle.main.bundleURL,
         store: StateStore = StateStore(),
         log: @escaping (String) -> Void = { PollLog.system($0) }) {
        self.service = service
        self.bundle = bundle
        self.store = store
        self.log = log
    }

    var isInApplications: Bool { bundle.standardizedFileURL.path.hasPrefix("/Applications/") }

    var status: SMAppService.Status {
        _ = looks
        return service.status
    }

    /// Ask the service again, on the next draw.
    func refresh() { looks += 1 }

    var isOn: Bool { status == .enabled }

    /// One line under the menu when macOS is holding the item for the user to
    /// approve, because a tick that will not go on needs a reason beside it.
    var hint: String? {
        if status == .requiresApproval {
            return "Approve Seat Gauge in System Settings, General, Login Items."
        }
        return problem
    }

    /// Every launch from `/Applications`, unless the user has said no.
    func registerAtLaunch() {
        guard isInApplications else { return }
        guard !store.load().loginItemDeclined else { return }
        register()
    }

    /// The menu switch. Turning it off is remembered; turning it on forgets.
    func toggle() {
        defer { refresh() }
        if isOn {
            do {
                try service.unregister()
                problem = nil
            } catch {
                report(error, doing: "unregistered")
            }
            _ = try? store.update { $0.loginItemDeclined = true }
        } else {
            _ = try? store.update { $0.loginItemDeclined = false }
            register()
        }
    }

    /// A login item that will not register is a line in the log and a line in
    /// the menu. It is never a launch that stops: the panel is the app.
    private func register() {
        do {
            try service.register()
            problem = nil
        } catch {
            report(error, doing: "registered")
        }
    }

    private func report(_ error: any Error, doing what: String) {
        let said = "the login item could not be \(what): \(error.localizedDescription)"
        problem = said
        log(said)
    }
}
