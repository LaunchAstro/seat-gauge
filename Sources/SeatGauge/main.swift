import AppKit
import SeatGaugeCore

/// The whole app in one file: the window, the menu, the poll loop, the spend
/// roll-up beside it, the login item and the one alert. Everything with a
/// decision in it is a type of its own, so this reads as the wiring it is.
/// It is an ordinary application: a Dock icon, a menu bar and a window that
/// closes and reopens while the loop keeps its schedule.
let application = NSApplication.shared
// Held until the app quits, so the seed command refuses while it runs.
let running = RunningLock.claim()
SeatGaugeApp.start(application)
FontLoader.registerBundledFonts()
// The size the user last chose, before the first card is measured, so the
// window opens at it rather than at the ordinary size and jumping.
GaugeMirror.shared.textScale = TextSizeStore.load()
GaugeMirror.shared.lightAppearance = AppearanceStore.load()
GaugeMirror.shared.choice = DetailChoiceStore.load()

let controller = WindowController(rootView: Root())
let panelMenu = PanelMenu()
controller.window.contentView?.menu = panelMenu.menu
let delegate = SeatGaugeDelegate(controller: controller)
application.delegate = delegate
controller.show()
// On its saved frame now, which is not the width the content was measured at.
controller.refit(.drawn)

// From /Applications only, and never when the user has turned it off. A
// register that fails is a line in the log and a line in the menu.
let loginItem = LoginItem()
loginItem.registerAtLaunch()
panelMenu.loginItem = loginItem
delegate.settings.loginItem = loginItem

// Authorisation is asked for on the first thing the app has to say, which is
// always after the panel has appeared.
GaugeMirror.shared.readSpend()
// Each provider's mark, from the cache, or from its site when none is cached.
// The cards draw the names alone until it lands.
Task {
    GaugeMirror.shared.marks = await SeatMark.load()
    controller.refit(.drawn)
}
let alerter = Alerter()
if Alerter.wantsTestBanner(Array(CommandLine.arguments.dropFirst())) {
    Task { await alerter.testBanner() }
}

// A config that will not open at all is the one thing the window cannot poll
// through, and it says so in the one line the empty state already has.
if let watcher = try? ConfigWatcher() {
    let store = GaugeStore()
    let spend = SpendCoordinator()
    let poller = Poller(watcher: watcher, service: RefreshService(), store: store,
                        clock: ContinuousClock(),
                        rollup: {
                            // At launch and every sixth poll, off the main
                            // actor, after the cards are up.
                            let seats = await watcher.config.seats
                            _ = try? await spend.run(profiles: SpendProfile.from(seats: seats),
                                                     rates: RateCard.load(), now: Date())
                            await MainActor.run { GaugeMirror.shared.readSpend() }
                        },
                        identity: IdentityObserver.hook(writer: AttributionWriter()),
                        notify: { snapshot, seats in
                            Task { @MainActor in
                                GaugeMirror.shared.apply(snapshot, seats: seats)
                                GaugeMirror.shared.configProblem = await watcher.problem
                                GaugeMirror.shared.pollMinutes = await watcher.config.pollMinutes
                                // Cards that changed ask for a height.
                                controller.refit(.drawn)
                                await alerter.consider(snapshot, seats: seats, now: Date())
                            }
                        },
                        // The seats a poll is reading, then none, for the busy icons.
                        syncing: { ids in Task { @MainActor in GaugeMirror.shared.syncing = ids } })
    GaugeMirror.shared.sync = { id in Task { await poller.sync([id]) } }
    GaugeMirror.shared.syncAll = { Task { await poller.syncAll() } }
    Task {
        // The store restores `readings.json` as it is built, so a cold
        // start is instant: last night's cards are
        // up, dimmed and dated, before the first fetch answers.
        GaugeMirror.shared.apply(await store.snapshot, seats: await watcher.config.seats)
        GaugeMirror.shared.configProblem = await watcher.problem
        GaugeMirror.shared.pollMinutes = await watcher.config.pollMinutes
        // The cards are in, so the user's height has something to fill.
        controller.refit(.drawn)
        await poller.run()
    }
}

application.run()
