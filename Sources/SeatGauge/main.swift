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
// window opens at it rather than opening at the ordinary size and jumping.
GaugeMirror.shared.textScale = TextSizeStore.load()
GaugeMirror.shared.lightAppearance = AppearanceStore.load()
GaugeMirror.shared.choice = DetailChoiceStore.load()
GaugeMirror.shared.readCards()

let controller = WindowController(rootView: Root())
GaugeMirror.shared.refit = { controller.refit(.drawn) }
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

let poll = Poll(options: Poll.Options(
    identity: true,
    wakes: WakeSource.stream(),
    notify: { snapshot, seats, watcher in
        Task { @MainActor in
            await GaugeMirror.shared.take(snapshot, seats: seats, through: watcher)
            // Cards that changed ask for a height.
            controller.refit(.drawn)
            await alerter.consider(snapshot, seats: seats, now: Date())
        }
    },
    // The seats a poll is reading, then none, for the busy icons.
    syncing: { ids in Task { @MainActor in GaugeMirror.shared.syncing = ids } },
    rolledUp: { await MainActor.run { GaugeMirror.shared.readSpend() } }))
let watcher = poll.watcher, store = poll.store, poller = poll.poller
// Each machine's load, on its own loop beside the seat poll, into the
// LOAD tab and `machines.json`, with a copy of the file on each other
// machine for the agents there, and every 15 minutes the size of each
// machine's folders worth clearing.
let machineMonitor = MachineMonitor(prober: MachineProber(runner: RealProcessRunner()),
                                    share: MachineShare(runner: RealProcessRunner()),
                                    sizer: ClearableSizer(runner: RealProcessRunner()),
                                    config: { await watcher.config },
                                    notify: { machines, states, history in
                                        Task { @MainActor in
                                            let mirror = GaugeMirror.shared
                                            // A card that gains or loses its meters
                                            // changes the tab's height.
                                            let shape = { (all: [String: MachineState]) in
                                                all.filter { $0.value.reading != nil }.keys.sorted() }
                                            let reshaped = mirror.machines != machines
                                                || shape(mirror.machineStates) != shape(states)
                                            mirror.machines = machines
                                            mirror.machineStates = states
                                            mirror.machineHistory = history
                                            if reshaped { controller.refit(.drawn) }
                                        }
                                    })
let logMonitor = SessionLogMonitor(prober: MachineProber(runner: RealProcessRunner()),
    config: { await watcher.config }, notify: { log in
        Task { @MainActor in GaugeMirror.shared.sessionLog = log }
    })
Task { await logMonitor.run() }
GaugeMirror.shared.readMachines = { Task { await machineMonitor.read() } }
Task {
    GaugeMirror.shared.machines = await watcher.config.machines
    await machineMonitor.run()
}
GaugeMirror.shared.sync = { id in Task { await poller.sync([id]) } }
GaugeMirror.shared.syncAll = { Task { await poller.syncAll() } }
GaugeMirror.shared.signIn = { id in
    SignIn.start(id, seats: GaugeMirror.shared.seats) { Task { await poller.sync([id]) } }
}
Task {
    // The store restores `readings.json` as it is built, so a cold
    // start is instant: last night's cards are up, dimmed and dated,
    // before the first fetch answers.
    await GaugeMirror.shared.take(await store.snapshot, seats: await watcher.config.seats, through: watcher)
    // The cards are in, so the user's height has something to fill.
    controller.refit(.drawn)
    await poll.run()
}

application.run()
