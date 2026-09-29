import Foundation
import ServiceManagement
import Testing
import UserNotifications

import SeatGaugeCore
@testable import SeatGauge

/// The weekly alert and the login item. Nothing here posts a banner or registers a login item: the notification
/// centre is behind `BannerPosting` and `SMAppService` is behind
/// `LoginItemService`, and both are stubbed.
@Suite(.sharedMirror) @MainActor struct AlertAndLoginItemTests {

    // MARK: - Building a reading

    static let sevenDays = Duration.seconds(7 * 24 * 60 * 60)
    static let fiveHours = Duration.seconds(5 * 60 * 60)

    static func now() -> Date { Date(timeIntervalSince1970: 1_790_000_000) }

    static func weekly(used: Int, inHours: Double) -> SeatGaugeCore.Window {
        SeatGaugeCore.Window(kind: .weekly, usedPercent: used,
                             resetsAt: now().addingTimeInterval(inHours * 3600), length: sevenDays)
    }

    static func fable(used: Int, inHours: Double) -> SeatGaugeCore.Window {
        SeatGaugeCore.Window(kind: .fable, usedPercent: used,
                             resetsAt: now().addingTimeInterval(inHours * 3600), length: sevenDays)
    }

    static func reading(_ seat: String, _ windows: [SeatGaugeCore.Window]) -> Reading {
        Reading(seat: SeatID(rawValue: seat), windows: windows.sorted { $0.kind < $1.kind },
                takenAt: now(), plan: "max")
    }

    static func snapshot(_ states: [String: SeatState]) -> Snapshot {
        let keyed = Dictionary(uniqueKeysWithValues: states.map { (SeatID(rawValue: $0.key), $0.value) })
        return Snapshot(states: keyed, order: states.keys.sorted().map { SeatID(rawValue: $0) })
    }

    /// A scratch `state.json`, so no case writes where the app keeps its own.
    static func scratchStore() throws -> StateStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-alert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return StateStore(file: directory.appendingPathComponent("state.json"))
    }

    /// Counts what the real centre would have been asked to do, in order.
    final class SpyBanners: BannerPosting, @unchecked Sendable {
        private let lock = NSLock()
        private var said: [String] = []
        var asked = 0

        var posts: [String] { lock.withLock { said } }
        func request() async -> Bool { lock.withLock { asked += 1 }; return true }
        func post(_ text: String) async { lock.withLock { said.append(text) } }
    }

    /// `SMAppService` as the app uses it, with the answer a case chooses.
    final class StubService: LoginItemService, @unchecked Sendable {
        private let lock = NSLock()
        private var state: (status: SMAppService.Status, registers: Int, unregisters: Int)
        var failure: (any Error)?

        init(status: SMAppService.Status = .notRegistered) {
            state = (status, 0, 0)
        }

        struct Refused: Error, CustomStringConvertible {
            var description: String { "the login item could not be registered" }
        }

        var status: SMAppService.Status { lock.withLock { state.status } }
        var registers: Int { lock.withLock { state.registers } }
        var unregisters: Int { lock.withLock { state.unregisters } }
        func set(_ status: SMAppService.Status) { lock.withLock { state.status = status } }

        func register() throws {
            if let failure { throw failure }
            lock.withLock { state.registers += 1; state.status = .enabled }
        }

        func unregister() throws {
            lock.withLock { state.unregisters += 1; state.status = .notRegistered }
        }
    }

    static let installed = URL(fileURLWithPath: "/Applications/Seat Gauge.app", isDirectory: true)
    static let inDist = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("code/seat-gauge/dist/Seat Gauge.app", isDirectory: true)

    // MARK: - The two stages

    @Test("the two stages fire on their own thresholds")
    func stagesFireOnTheirThresholds() {
        let ledger = AlertLedger()
        // 40 h to run and 54% of the week still there: the two-day stage.
        let early = Self.reading("work", [Self.weekly(used: 46, inHours: 40)])
        let first = AlertPolicy.due(reading: early, now: Self.now(), ledger: ledger)
        #expect(first?.stage == .twoDays)
        #expect(first?.window.kind == .weekly)

        // 20 h to run and 35% left: under the two-day headroom, over the
        // one-day one.
        let late = Self.reading("work", [Self.weekly(used: 65, inHours: 20)])
        #expect(AlertPolicy.due(reading: late, now: Self.now(), ledger: ledger)?.stage == .oneDay)

        // Inside the window but with too little left to be worth saying.
        let spent = Self.reading("work", [Self.weekly(used: 80, inHours: 20)])
        #expect(AlertPolicy.due(reading: spent, now: Self.now(), ledger: ledger) == nil)
        // Plenty left, but the week has days to run.
        let young = Self.reading("work", [Self.weekly(used: 10, inHours: 72)])
        #expect(AlertPolicy.due(reading: young, now: Self.now(), ledger: ledger) == nil)
    }

    // MARK: - Both due at once

    @Test("both due at once fires the most urgent and marks the lower stage")
    func bothDueFiresTheMostUrgentOnce() async throws {
        // 20 h to run with 60% unused answers both thresholds.
        let read = Self.reading("work", [Self.weekly(used: 40, inHours: 20)])
        var ledger = AlertLedger()
        let due = try #require(AlertPolicy.due(reading: read, now: Self.now(), ledger: ledger))
        #expect(due.stage == .oneDay)

        let key = AlertKey(seat: read.seat, resetsAt: due.window.resetsAt)
        ledger.mark(due.stage, for: key)
        #expect(ledger.has(.oneDay, for: key))
        #expect(ledger.has(.twoDays, for: key))
        // Nothing is due a second time, so one banner is all that is posted.
        #expect(AlertPolicy.due(reading: read, now: Self.now(), ledger: ledger) == nil)

        let banners = SpyBanners()
        let alerter = Alerter(notifier: banners, store: try Self.scratchStore())
        let snapshot = Self.snapshot(["work": .live(read)])
        let seats = [Seat(id: read.seat, label: "Work", kind: .claude(profileDir: URL(fileURLWithPath: "/tmp/seat-gauge-profile")))]
        await alerter.consider(snapshot, seats: seats, now: Self.now())
        await alerter.consider(snapshot, seats: seats, now: Self.now().addingTimeInterval(600))
        #expect(banners.posts.count == 1)
    }

    // MARK: - The ledger

    @Test("the ledger is keyed on the seat and the week, and survives a quit")
    func ledgerIsKeyedOnTheSeatAndTheWeek() async throws {
        let store = try Self.scratchStore()
        let read = Self.reading("work", [Self.weekly(used: 46, inHours: 40)])
        let seats = [Seat(id: read.seat, label: "Work", kind: .claude(profileDir: URL(fileURLWithPath: "/tmp/seat-gauge-profile")))]
        let banners = SpyBanners()
        await Alerter(notifier: banners, store: store)
            .consider(Self.snapshot(["work": .live(read)]), seats: seats, now: Self.now())
        #expect(banners.posts.count == 1)

        // A new Alerter, as a relaunch makes one, reads the ledger back off
        // state.json and says nothing more about the same week.
        let second = SpyBanners()
        await Alerter(notifier: second, store: store)
            .consider(Self.snapshot(["work": .live(read)]), seats: seats, now: Self.now())
        #expect(second.posts.isEmpty)

        // The next week is a new key, so the same stage is due again.
        let nextWeek = Self.reading("work", [SeatGaugeCore.Window(
            kind: .weekly, usedPercent: 46,
            resetsAt: Self.now().addingTimeInterval((40 + 7 * 24) * 3600), length: Self.sevenDays)])
        let third = SpyBanners()
        await Alerter(notifier: third, store: store)
            .consider(Self.snapshot(["work": .live(nextWeek)]), seats: seats,
                      now: Self.now().addingTimeInterval(7 * 24 * 3600))
        #expect(third.posts.count == 1)
        // And the old week is still in the ledger beside the new one.
        #expect(store.load().alerts.fired.count == 2)
    }

    // MARK: - Only the weekly window

    @Test("only the weekly window of a live seat raises anything")
    func onlyTheWeeklyWindowOfALiveSeatAlerts() {
        let ledger = AlertLedger()
        // A Fable window on the same numbers raises nothing.
        let fableOnly = Self.reading("work", [Self.fable(used: 46, inHours: 40)])
        #expect(AlertPolicy.due(reading: fableOnly, now: Self.now(), ledger: ledger) == nil)

        let read = Self.reading("work", [Self.weekly(used: 46, inHours: 40),
                                           Self.fable(used: 5, inHours: 40)])
        #expect(AlertPolicy.due(reading: read, now: Self.now(), ledger: ledger)?.window.kind == .weekly)

        // A seat with a last reading but no live state is not read at all.
        let stale = Self.snapshot(["work": .unreadable(reason: "timed out", last: read)])
        #expect(AlertPolicy.due(in: stale, now: Self.now(), ledger: ledger) == nil)
        let live = Self.snapshot(["work": .live(read)])
        #expect(AlertPolicy.due(in: live, now: Self.now(), ledger: ledger)?.seat == read.seat)
    }

    // MARK: - The banner

    @Test("the banner reads as a sentence, without sound, after authorisation")
    func bannerReadsAsASentence() async throws {
        let window = Self.weekly(used: 46, inHours: 40)
        let text = AlertPolicy.text(label: "Work", window: window, now: Self.now())
        #expect(text.hasPrefix("Work: 54% of the week unused, resets "))
        // A day name and a twelve-hour time, and never a number of seconds.
        #expect(text.contains("am") || text.contains("pm"))
        #expect(!text.contains(":00"))

        let banners = SpyBanners()
        let read = Self.reading("work", [window])
        let seats = [Seat(id: read.seat, label: "Work", kind: .claude(profileDir: URL(fileURLWithPath: "/tmp/seat-gauge-profile")))]
        let alerter = Alerter(notifier: banners, store: try Self.scratchStore())
        await alerter.consider(Self.snapshot(["work": .live(read)]), seats: seats, now: Self.now())
        #expect(banners.asked == 1)
        #expect(banners.posts == [text])
        // Asked once, not once a poll.
        await alerter.consider(Self.snapshot(["work": .live(read)]), seats: seats, now: Self.now())
        #expect(banners.asked == 1)

        // The real centre is asked for an alert and nothing else, and the
        // banner it posts carries no sound.
        #expect(Notifier.options == [.alert])
        #expect(Notifier.sound == nil)
    }

    // MARK: - The test banner

    @Test("--test-notification posts one banner and changes nothing else")
    func testNotificationPostsOneBanner() async throws {
        #expect(Alerter.wantsTestBanner(["--test-notification"]))
        #expect(!Alerter.wantsTestBanner([]))
        #expect(!Alerter.wantsTestBanner(["--watch"]))

        let store = try Self.scratchStore()
        let banners = SpyBanners()
        let alerter = Alerter(notifier: banners, store: store)
        await alerter.testBanner()
        #expect(banners.posts.count == 1)
        #expect(banners.asked == 1)
        #expect(banners.posts.first?.contains("Seat Gauge") == true)
        // The ledger is not touched, so a test banner never costs a real one.
        #expect(store.load().alerts.fired.isEmpty)
    }

    // MARK: - Where the login item registers from

    @Test("the login item registers from /Applications and nowhere else")
    func registersOnlyFromApplications() throws {
        let service = StubService()
        let item = LoginItem(service: service, bundle: Self.installed, store: try Self.scratchStore())
        #expect(item.isInApplications)
        item.registerAtLaunch()
        item.registerAtLaunch()
        // Idempotent, so it runs on every launch rather than being remembered.
        #expect(service.registers == 2)

        let fromDist = StubService()
        let copy = LoginItem(service: fromDist, bundle: Self.inDist, store: try Self.scratchStore())
        #expect(!copy.isInApplications)
        copy.registerAtLaunch()
        #expect(fromDist.registers == 0)
    }

    // MARK: - Declined, and the menu tick

    @Test("a declined item is not registered, and the tick reads the real status")
    func declinedIsNotRegisteredAndTheTickReadsStatus() throws {
        let store = try Self.scratchStore()
        try store.update { $0.loginItemDeclined = true }
        let service = StubService()
        let item = LoginItem(service: service, bundle: Self.installed, store: store)
        item.registerAtLaunch()
        #expect(service.registers == 0)

        // Turning it on again clears the refusal and registers.
        item.toggle()
        #expect(service.registers == 1)
        #expect(item.isOn)
        #expect(store.load().loginItemDeclined == false)
        // And turning it off records the refusal, so the next launch leaves it.
        item.toggle()
        #expect(service.unregisters == 1)
        #expect(!item.isOn)
        #expect(store.load().loginItemDeclined)

        // The menu tick is the service's status, not a bool the app keeps.
        let menu = PanelMenu()
        menu.loginItem = item
        service.set(.enabled)
        menu.menuNeedsUpdate(menu.menu)
        #expect(menu.menu.items[1].state == .on)
        service.set(.requiresApproval)
        menu.menuNeedsUpdate(menu.menu)
        #expect(menu.menu.items[1].state == .off)
        #expect(item.hint != nil)
        #expect(menu.menu.items.contains { $0.title == item.hint })
    }

    // MARK: - A failed register

    @Test("a register that fails is logged and leaves the app running")
    func aFailedRegisterIsLoggedAndNotFatal() throws {
        let said = Log()
        let service = StubService(status: .notFound)
        service.failure = StubService.Refused()
        let item = LoginItem(service: service, bundle: Self.installed,
                             store: try Self.scratchStore(), log: { said.add($0) })
        item.registerAtLaunch()
        #expect(service.registers == 0)
        #expect(said.all.contains { $0.contains("login item") })
        #expect(item.problem != nil)
        // The tick still reads the service rather than an assumption.
        #expect(!item.isOn)

        // And the panel is built and shown all the same.
        let controller = WindowController(autosaveName: "SeatGaugeAlertCase", rootView: Root())
        #expect(controller.window.contentView != nil)
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame SeatGaugeAlertCase")
    }

    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var said: [String] = []
        func add(_ line: String) { lock.withLock { said.append(line) } }
        var all: [String] { lock.withLock { said } }
    }

    // MARK: - Fails closed

    @Test("Fails closed: no weekly window, not live, and an unreadable ledger")
    func failsClosedOnAMissingWindowAndABadLedger() async throws {
        let ledger = AlertLedger()
        // No weekly window at all.
        let noWeek = Self.reading("work", [SeatGaugeCore.Window(
            kind: .fiveHour, usedPercent: 5, resetsAt: Self.now().addingTimeInterval(3600),
            length: Self.fiveHours)])
        #expect(AlertPolicy.due(reading: noWeek, now: Self.now(), ledger: ledger) == nil)
        // A weekly window that has already reset says nothing either.
        let past = Self.reading("work", [Self.weekly(used: 46, inHours: -1)])
        #expect(AlertPolicy.due(reading: past, now: Self.now(), ledger: ledger) == nil)

        let dormant = Self.snapshot(["work": .dormant(reason: "not logged in")])
        #expect(AlertPolicy.due(in: dormant, now: Self.now(), ledger: ledger) == nil)

        // A state.json that will not decode is an empty ledger, not a silence.
        let store = try Self.scratchStore()
        try Data("{ not json".utf8).write(to: store.file)
        #expect(store.load().alerts.fired.isEmpty)
        let banners = SpyBanners()
        let read = Self.reading("work", [Self.weekly(used: 46, inHours: 40)])
        await Alerter(notifier: banners, store: store).consider(
            Self.snapshot(["work": .live(read)]),
            seats: [Seat(id: read.seat, label: "Work", kind: .claude(profileDir: URL(fileURLWithPath: "/tmp/seat-gauge-profile")))],
            now: Self.now())
        #expect(banners.posts.count == 1)
    }
}
