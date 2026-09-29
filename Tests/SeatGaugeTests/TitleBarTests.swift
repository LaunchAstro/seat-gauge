import AppKit
import Foundation
import SwiftUI
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// The title bar row: its place, its status, its floor and its clicks. Window cases build a real `WindowController` under an autosave name of
/// their own and forget it when they end.
@Suite(.serialized, .sharedMirror) @MainActor struct TitleBarTests {

    typealias Glance = GlanceFaceTests
    typealias Widths = CardWidthTests

    static let now = Date(timeIntervalSince1970: 1_758_500_100)

    static func freshName() -> String { "SeatGaugeTitleBarTest-\(UUID().uuidString)" }

    static func forget(_ name: String) {
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)")
    }

    static func controller(_ name: String) -> WindowController {
        _ = NSApplication.shared
        return WindowController(autosaveName: name, rootView: Root())
    }

    static func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    /// A view's frame in its window's coordinates.
    static func inWindow(_ view: NSView) -> CGRect { view.convert(view.bounds, to: nil) }

    /// The mirror as a case found it, put back when the case ends.
    static func keepingMirror(_ body: () async throws -> Void) async rethrows {
        let mirror = GaugeMirror.shared
        let was = (mirror.textScale, mirror.snapshot, mirror.seats, mirror.tab, mirror.configProblem,
                   mirror.lightAppearance, mirror.verticalFactor)
        defer {
            mirror.textScale = was.0
            mirror.apply(was.1, seats: was.2)
            mirror.tab = was.3
            mirror.configProblem = was.4
            mirror.lightAppearance = was.5
            mirror.verticalFactor = was.6
        }
        try await body()
    }

    /// One live Codex seat, so the cards are one card wide.
    static func oneCard() {
        let seat = Seat(id: SeatID(rawValue: "codex"), label: "codex", kind: .codex)
        let reading = Reading(seat: seat.id, windows: [Glance.window(.weekly, used: 30)], takenAt: Date(), plan: nil)
        GaugeMirror.shared.apply(Snapshot(states: [seat.id: .live(reading)], order: [seat.id]), seats: [seat])
    }

    // MARK: - An ordinary window with its content under the title bar

    @Test func theWindowIsOrdinaryWithItsContentUnderTheTitleBar() throws {
        let name = Self.freshName()
        defer { Self.forget(name) }
        let window = Self.controller(name).window
        #expect(window.styleMask == [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        #expect(window.level == .normal)
        #expect(window.collectionBehavior.contains(.canJoinAllSpaces) == false)
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary) == false)
        #expect(window.isFloatingPanel == false)
        #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titleVisibility == .hidden)
        #expect(window.title == "Seat Gauge")
        #expect(window.frameAutosaveName == name)
    }

    // MARK: - The row sits in the title bar

    @Test func theRowSitsInTheTitleBar() async {
        await Self.keepingMirror {
            Self.oneCard()
            let name = Self.freshName()
            defer { Self.forget(name) }
            let built = Self.controller(name)
            defer { built.window.close() }
            built.show()
            await Self.settle()
            let window = built.window
            let hosts = built.titleBarHosts
            #expect(hosts.count == 2)
            guard hosts.count == 2, let zoom = window.standardWindowButton(.zoomButton) else { return }
            let lead = Self.inWindow(hosts[0]), controls = Self.inWindow(hosts[1])
            let band = window.contentLayoutRect.maxY
            for frame in [lead, controls] {
                #expect(frame.width > 0 && frame.height > 0, "\(frame)")
                #expect(frame.minY >= band - 1, "\(frame) under the bar at \(band)")
                #expect(frame.maxY <= window.frame.height + 1, "\(frame)")
            }
            #expect(lead.minX >= Self.inWindow(zoom).maxX, "\(lead) against the traffic lights")
            #expect(abs(controls.maxX - window.frame.width) <= 1, "\(controls) against \(window.frame.width)")
            #expect(lead.maxX <= controls.minX, "\(lead) \(controls)")
            #expect(built.chrome > 10)
            #expect(abs((window.contentView?.safeAreaInsets.top ?? 0) - built.chrome) < 1)
            #expect(abs(window.contentLayoutRect.height - built.contentHeight) < 1)
        }
    }

    // MARK: - The status says one thing

    @Test func theStatusSaysOneThingAndTheMenuSaysItAll() async throws {
        let quiet = TitleStatus.of(updated: "updated 2m ago", problems: [])
        #expect(quiet == TitleStatus(text: "updated 2m ago", isProblem: false))
        let loud = TitleStatus.of(updated: "updated 2m ago", problems: ["config first", "spend second"])
        #expect(loud == TitleStatus(text: "config first", isProblem: true))

        let read = Reading(seat: SeatID(rawValue: "work"), windows: [Glance.window(.weekly, used: 31)],
                           takenAt: Self.now.addingTimeInterval(-120), plan: nil)
        let model = PanelModel.make(snapshot: Snapshot(states: [read.seat: .live(read)], order: [read.seat]),
                                    seats: [Glance.codex("work")], now: Self.now)
        #expect(model.updated == "all seats synced 2m ago")

        await Self.keepingMirror {
            let sentence = "seats.json: the claude seat \"work\" has no profile."
            GaugeMirror.shared.configProblem = sentence
            #expect(GaugeMirror.shared.problems == [sentence])
            let told = PanelMenu()
            #expect(told.menu.items.first?.title == sentence)
            #expect(told.menu.items.first?.isEnabled == false)
            let commands = told.menu.items.filter { $0.action != nil && !$0.isSeparatorItem }.prefix(4).map(\.title)
            #expect(commands == ["Sync all", "Launch at login", "Reveal config", "Quit"])

            GaugeMirror.shared.configProblem = nil
            let menu = PanelMenu()
            menu.loginItemOn = true
            menu.rebuild()
            #expect(Array(menu.menu.items.prefix(4).map(\.title)) == ["Sync all", "Launch at login", "Reveal config", "Quit"])
            #expect(menu.menu.items[1].state == .on)
        }
    }

    // MARK: - Title bar text follows the size up to step 4

    @Test func titleBarTextFollowsTheSizeUpToStepFour() throws {
        let was = GaugeMirror.shared.textScale
        defer { GaugeMirror.shared.textScale = was }
        for step in TextScale.steps {
            GaugeMirror.shared.textScale = TextScale(step: step)
            let held = min(step, TitleBarMetrics.topStep)
            #expect(TitleBarMetrics.scale.step == held)
            let expected = CGFloat(TextScale(step: held).scaled(Double(TitleBarMetrics.textSize)))
            #expect(abs(TitleBarMetrics.points(TitleBarMetrics.textSize) - expected) < 0.001, "step \(step)")
        }
        #expect(TitleBarMetrics.topStep == 4)
    }

    // MARK: - The status gives way first

    @Test func theStatusTruncatesThenHidesAndNothingElseShrinks() async {
        let full = TitleBarMetrics.trail(available: 500, controls: 80, status: 120)
        #expect(full.showsStatus && full.width == 80 + TitleBarMetrics.gap + 120)
        let cut = TitleBarMetrics.trail(available: 200, controls: 80, status: 120)
        #expect(cut.showsStatus && cut.width == 200)
        let gone = TitleBarMetrics.trail(available: 80 + TitleBarMetrics.gap + TitleBarMetrics.statusFloor - 1,
                                         controls: 80, status: 120)
        #expect(!gone.showsStatus && gone.width == 80)

        await Self.keepingMirror {
            Self.oneCard()
            let name = Self.freshName()
            defer { Self.forget(name) }
            let built = Self.controller(name)
            defer { built.window.close() }
            built.show()
            GaugeMirror.shared.textScale = .normal
            built.refit()
            await Self.settle()
            // The narrowest window that still holds the title; under it the
            // title gives way too.
            let title = NSHostingView(rootView: TitleText()).fittingSize.width
            let controls = NSHostingView(rootView: TitleControls()).fittingSize.width
            var frame = built.window.frame
            frame.size.width = (built.buttonsEdge + TitleBarMetrics.gap * 4 + title + controls).rounded(.up)
            built.window.setFrame(frame, display: true)
            built.layoutTitleBar()
            await Self.settle()
            let hosts = built.titleBarHosts
            guard hosts.count == 2 else { Issue.record("no row"); return }
            #expect(hosts[0].frame.width >= title - 0.5, "\(hosts[0].frame.width) under \(title)")
            #expect(abs(hosts[1].frame.width - controls) < 0.5, "\(hosts[1].frame.width)")
            #expect(Self.inWindow(hosts[0]).maxX <= Self.inWindow(hosts[1]).minX)
        }
    }

    // MARK: - The layout holds, and the row sets a floor

    @Test func theLayoutHoldsAndTheRowSetsAFloor() async {
        let was = GaugeMirror.shared.textScale
        var minimums: [CGFloat] = []
        for step in TextScale.steps {
            GaugeMirror.shared.textScale = TextScale(step: step)
            #expect(CardMetrics.minimumWidth > CardMetrics.fixedColumns)
            #expect(CardMetrics.meterWidth(cardWidth: CardMetrics.minimumWidth) >= CardMetrics.minimumMeter)
            minimums.append(CardMetrics.minimumWidth)
        }
        GaugeMirror.shared.textScale = was
        #expect(zip(minimums, minimums.dropFirst()).allSatisfy { $0 < $1 })

        Widths.atOrdinaryStep { _ in
            for cards in 1...4 {
                let floor = PanelLayout.minimumContentWidth(cards: cards)
                #expect(floor >= CGFloat(cards) * CardMetrics.minimumWidth)
                for width in stride(from: floor, through: 6016, by: 271) {
                    let widths = PanelLayout.cardWidths(contentWidth: width, cards: cards)
                    #expect(widths.count == cards)
                    for one in widths {
                        #expect(one >= CardMetrics.minimumWidth)
                        #expect(CardMetrics.meterWidth(cardWidth: one) >= CardMetrics.minimumMeter)
                    }
                    let drawn = widths.reduce(0, +) + CGFloat(cards - 1) * PanelLayout.ruleWidth
                    #expect(abs(drawn - width) < 1)
                }
                #expect(PanelLayout.cardWidths(contentWidth: 10, cards: cards).allSatisfy { $0 == CardMetrics.minimumWidth })
            }
        }

        await Self.keepingMirror {
            Self.oneCard()
            GaugeMirror.shared.textScale = .smallest
            let name = Self.freshName()
            defer { Self.forget(name) }
            let built = Self.controller(name)
            defer { built.window.close() }
            built.show()
            built.refit(.drawn)
            await Self.settle()
            built.refit()
            await Self.settle()
            let controls = NSHostingView(rootView: TitleControls()).fittingSize.width
            let row = TitleBarMetrics.minimumWidth(buttons: built.buttonsEdge, controls: controls)
            #expect(abs(GaugeMirror.shared.chromeMinimum - row) < 1)
            #expect(built.window.contentMinSize.width <= CardMetrics.minimumWidth + 1)
        }
    }

    // MARK: - Clicks on the bar

    @Test func aClickMovesTheWindowAndADoubleClickDoesWhatTheOwnerSet() throws {
        #expect(TitleBarClick.action(clickCount: 1, setting: nil) == .drag)
        #expect(TitleBarClick.action(clickCount: 1, setting: "Minimize") == .drag)
        #expect(TitleBarClick.action(clickCount: 2, setting: nil) == .zoom)
        #expect(TitleBarClick.action(clickCount: 2, setting: "Maximize") == .zoom)
        #expect(TitleBarClick.action(clickCount: 2, setting: "Minimize") == .minimise)
        #expect(TitleBarClick.action(clickCount: 2, setting: "None") == .nothing)

        let name = Self.freshName()
        defer { Self.forget(name) }
        let built = Self.controller(name)
        let hosts = built.titleBarHosts
        #expect(hosts.map(\.mouseDownCanMoveWindow) == [true, true])
        #expect(hosts.map(\.passesClicks) == [false, true])
    }

    // MARK: - One toggle, one state

    @Test func theButtonAndTheMenuItemAreOneToggle() async {
        await Self.keepingMirror {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("seat-gauge-title-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = Self.freshName()
            defer { Self.forget(name) }
            let built = Self.controller(name)
            let delegate = SeatGaugeDelegate(controller: built,
                                             store: StateStore(file: directory.appendingPathComponent("state.json")))
            @MainActor func item() -> NSMenuItem? { PanelMenu().menu.items.first { $0.title == AppearanceCommand.title } }
            #expect(item()?.action == AppearanceCommand.action)

            GaugeMirror.shared.lightAppearance = false
            #expect(item()?.state == .off)
            delegate.toggleLightAppearance(nil)
            #expect(GaugeMirror.shared.lightAppearance)
            #expect(item()?.state == .on)
            delegate.toggleLightAppearance(nil)
            #expect(item()?.state == .off)
        }
    }

    // MARK: - The row draws as a stack of the same cards

    @Test func theCardRowStillDrawsAsAStack() {
        Glance.appearances { light in
            Widths.atOrdinaryStep { step in
                for count in 1...4 {
                    var cards = Widths.cards(count)
                    if count > 1 { cards[1] = Widths.card("team", provider: "Claude", countdown: "123456d 23h") }
                    let floor = PanelLayout.minimumContentWidth(cards: count)
                    let width = floor + 233.5
                    let stack = HStack(spacing: PanelLayout.ruleWidth) { ForEach(cards) { CardView(card: $0) } }
                        .fixedSize(horizontal: false, vertical: true)
                    #expect(Glance.same(stack, ComboLayout(cards: cards), width: width),
                            "light \(light), step \(step), \(count) cards, \(width)")
                }
            }
        }
    }

    // MARK: - Fails closed

    @Test func theRowFailsClosed() async {
        let long = TitleBarMetrics.trail(available: 300, controls: 80, status: 50_000)
        #expect(long.showsStatus && long.width <= 300)
        for bad in [CGFloat.nan, .infinity, -.infinity, -40, 0] {
            let none = TitleBarMetrics.trail(available: bad, controls: 80, status: 120)
            #expect(!none.showsStatus && none.width == 80, "\(bad): \(none)")
        }
        #expect(TitleBarMetrics.buttonsEdge(zoom: nil) > 0)
        // A window shorter than the on-screen minimum is on screen when all
        // of it is, and still off it when most of it is not.
        let screen = [CGRect(x: 0, y: 0, width: 1000, height: 1000)]
        #expect(PanelPlacement.isOnScreen(CGRect(x: 100, y: 100, width: 520, height: 60), visibleFrames: screen))
        #expect(!PanelPlacement.isOnScreen(CGRect(x: 100, y: 970, width: 520, height: 60), visibleFrames: screen))
        #expect(!PanelPlacement.isOnScreen(CGRect(x: -480, y: 100, width: 520, height: 60), visibleFrames: screen))
        #expect(TitleBarMetrics.buttonsEdge(zoom: CGRect(x: 48, y: 4, width: 14, height: 16)) == 62)

        Widths.atOrdinaryStep { step in
            let minimum = CardMetrics.minimumWidth
            #expect(PanelLayout.cardWidths(contentWidth: 800, cards: 0).isEmpty)
            #expect(PanelLayout.minimumContentWidth(cards: 0) == minimum)
            for bad in [10, -300, CGFloat.nan, .infinity, -.infinity] {
                for count in 1...4 {
                    let widths = PanelLayout.cardWidths(contentWidth: bad, cards: count)
                    #expect(widths.count == count)
                    #expect(widths.allSatisfy { $0 == minimum }, "step \(step), \(bad): \(widths)")
                }
                #expect(CardMetrics.meterWidth(cardWidth: bad) == CardMetrics.minimumMeter)
                #expect(CardMetrics.meterWidth(cardWidth: bad, overflow: 50) == CardMetrics.minimumMeter)
            }
            for overflow in [0, 1e6, -40, .nan, .infinity] as [CGFloat] {
                let meter = CardMetrics.meterWidth(cardWidth: minimum + 200, overflow: overflow)
                #expect(meter >= CardMetrics.minimumMeter && meter.isFinite, "\(overflow): \(meter)")
            }
        }

        await Self.keepingMirror {
            GaugeMirror.shared.configProblem = "seats.json could not be read"
            #expect(TitleStatus.of(updated: "updated 1m ago", problems: GaugeMirror.shared.problems).isProblem)
            GaugeMirror.shared.configProblem = nil
            #expect(TitleStatus.of(updated: "updated 1m ago", problems: GaugeMirror.shared.problems)
                == TitleStatus(text: "updated 1m ago", isProblem: false))
        }
    }
}
