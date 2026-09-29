import AppKit
import Foundation
import SwiftUI
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// The text size, the marks, the plan and a config with a bad field. The text
/// size is a value, so every case but the window one reads it as
/// arithmetic. The two that need a window build a real `WindowController`
/// under an autosave name of their own and remove that entry when they end,
/// so none of them leaves a window position behind on the machine.
@Suite(.sharedMirror) @MainActor struct GlanceTests {

    static func freshName() -> String { "SeatGaugeGlanceTest-\(UUID().uuidString)" }

    static func forget(_ name: String) {
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)")
    }

    static func controller(_ name: String) -> WindowController {
        _ = NSApplication.shared
        return WindowController(autosaveName: name, rootView: Root())
    }

    /// A `StateStore` on a temporary file, so a case that reads persistence
    /// never touches the state the running app keeps.
    static func temporaryState() -> (store: StateStore, folder: URL) {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-glance-\(UUID().uuidString)", isDirectory: true)
        return (StateStore(file: folder.appendingPathComponent("state.json")), folder)
    }

    static func seat(_ id: String, account: String? = nil, plan: String? = nil) -> Seat {
        Seat(id: SeatID(rawValue: id), label: id.capitalized, kind: .codex,
             account: account, plan: plan)
    }

    /// One live seat with one window, so a card exists to read the identity
    /// line off. The percentage is the same for every seat here: which card is
    /// best is not what these cases read.
    static func snapshot(_ seats: [Seat], plans: [String?], now: Date) -> Snapshot {
        var states: [SeatID: SeatState] = [:]
        for (seat, reported) in zip(seats, plans) {
            let window = SeatGaugeCore.Window(kind: .fiveHour, usedPercent: 40,
                                              resetsAt: now.addingTimeInterval(3600),
                                              length: .seconds(5 * 3600))
            states[seat.id] = .live(Reading(seat: seat.id, windows: [window],
                                            takenAt: now, plan: reported))
        }
        return Snapshot(states: states, order: seats.map(\.id))
    }

    // MARK: - The size changes, persists, and the window still fits

    @Test func theTextSizeChangesByMenuAndByKeyAndSurvivesARelaunch() throws {
        let was = GaugeMirror.shared.textScale
        defer { GaugeMirror.shared.textScale = was }

        // Stepping walks the range and stops at both ends rather than running
        // off it, so a held Cmd + is not an unreadable window.
        #expect(TextScale.smallest.factor < TextScale.normal.factor)
        #expect(TextScale.normal.factor < TextScale.largest.factor)
        #expect(TextScale.normal.stepped(by: 1).factor > TextScale.normal.factor)
        #expect(TextScale.normal.stepped(by: -1).factor < TextScale.normal.factor)
        #expect(TextScale.largest.stepped(by: 3) == TextScale.largest)
        #expect(TextScale.smallest.stepped(by: -3) == TextScale.smallest)
        #expect(TextScale(step: TextScale.normal.step) == TextScale.normal)

        // Persisted: the step is written to state.json and read back whole.
        let (store, folder) = Self.temporaryState()
        defer { try? FileManager.default.removeItem(at: folder) }
        try TextSizeStore.save(.largest, to: store)
        #expect(TextSizeStore.load(store) == TextScale.largest)
        try TextSizeStore.save(.smallest, to: store)
        #expect(TextSizeStore.load(store) == TextScale.smallest)
        // A state file nobody has written yet is the ordinary size.
        let (fresh, other) = Self.temporaryState()
        defer { try? FileManager.default.removeItem(at: other) }
        #expect(TextSizeStore.load(fresh) == TextScale.default)

        // By key: the three equivalents are on the application's menu bar.
        let bar = SeatGaugeApp.menuBar()
        let items = bar.items.compactMap(\.submenu).flatMap(\.items)
        func key(_ action: Selector) -> (String, NSEvent.ModifierFlags)? {
            items.first { $0.action == action }
                .map { ($0.keyEquivalent, $0.keyEquivalentModifierMask) }
        }
        #expect(key(#selector(SeatGaugeDelegate.increaseTextSize(_:)))?.0 == "+")
        #expect(key(#selector(SeatGaugeDelegate.decreaseTextSize(_:)))?.0 == "-")
        #expect(key(#selector(SeatGaugeDelegate.resetTextSize(_:)))?.0 == "0")
        for action in [#selector(SeatGaugeDelegate.increaseTextSize(_:)),
                       #selector(SeatGaugeDelegate.decreaseTextSize(_:)),
                       #selector(SeatGaugeDelegate.resetTextSize(_:))] {
            #expect(key(action)?.1 == .command)
        }

        // By menu: the same three are a right click away, after the four
        // commands at the top of that menu.
        let menu = PanelMenu()
        #expect(menu.menu.items.prefix(4).map(\.title)
            == ["Sync all", "Launch at login", "Reveal config", "Quit"])
        let titles = menu.menu.items.map(\.title)
        for title in ["Bigger text", "Smaller text", "Ordinary text"] {
            #expect(titles.contains(title))
        }

        // The window fits its content at both ends: the height is the one the
        // content asks for, with no strip under the cards, and the width is
        // never under what the content can be drawn in.
        var heights: [CGFloat] = []
        for scale in [TextScale.smallest, TextScale.largest] {
            GaugeMirror.shared.textScale = scale
            let name = Self.freshName()
            defer { Self.forget(name) }
            let built = Self.controller(name)
            #expect(built.contentHeight > 0)
            #expect(abs(built.window.contentLayoutRect.height - built.contentHeight) < 1)
            #expect(built.window.frame.width >= built.window.contentMinSize.width)
            built.refit()
            #expect(abs(built.window.contentLayoutRect.height - built.contentHeight) < 1)
            heights.append(built.contentHeight)
        }
        #expect(heights.count == 2)
        #expect((heights.last ?? 0) > (heights.first ?? 0))
    }

    // MARK: - A provider per kind

    @Test func eachSeatKindNamesItsProvider() {
        #expect(SeatKind.claude(profileDir: URL(fileURLWithPath: "/tmp/x")).provider == .claude)
        #expect(SeatKind.codex.provider == .codex)
        #expect(Provider.allCases.map(\.name) == ["Claude", "Codex"])
        // Each mark is fetched from the provider's own site, over https.
        #expect(Provider.allCases.allSatisfy { $0.site.scheme == "https" })
        #expect(SeatMark.side(.smallest) >= SeatMark.minimumSide)
    }

    // MARK: - Config first, then the wire, then nothing, and never "Free"

    @Test func thePlanResolvesConfigFirstAndIsNeverInventedAsFree() {
        let now = Date(timeIntervalSince1970: 1_758_500_100)
        let declared = Self.seat("personal", plan: "Max 20x")
        let wireOnly = Self.seat("codex")
        let neither = Self.seat("work")
        let disagreeing = Self.seat("team", plan: "Max 5x")
        let seats = [declared, wireOnly, neither, disagreeing]
        let model = PanelModel.make(
            snapshot: Self.snapshot(seats, plans: ["max", "prolite", nil, "max"], now: now),
            seats: seats, now: now)

        func plan(_ seat: Seat) -> String? { model.cards.first { $0.id == seat.id }?.plan }
        #expect(plan(declared) == "Max 20x")
        #expect(plan(wireOnly) == "prolite")
        // A token seat reports `null`, which is not reported rather than free.
        #expect(plan(neither) == nil)
        // Both, and disagreeing: the config wins, uncorrected.
        #expect(plan(disagreeing) == "Max 5x")
        for card in model.cards {
            #expect(card.plan?.lowercased().contains("free") != true)
        }
        // The rule itself, since it is what the card is drawn from.
        #expect(PlanText.resolve(tier: nil, declared: "Pro", wire: "max") == "Pro")
        #expect(PlanText.resolve(tier: nil, declared: nil, wire: "max") == "max")
        #expect(PlanText.resolve(tier: nil, declared: "  ", wire: nil) == nil)
        #expect(PlanText.resolve(tier: nil, declared: nil, wire: nil) == nil)
    }

    // MARK: - Fails closed: a bad field loses neither the seats nor the app

    @Test func aBadFieldOrSizeIsReadWithoutLosingWhatIsFine() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-glance-tokens-\(UUID().uuidString)", isDirectory: true)
        let text = """
            {
              "colour": "blue",
              "seats": [
                { "id": "work", "label": "Work", "kind": "claude", "profile": "~/.seat-work", "account": "work account" },
                { "id": "team", "label": "Team", "kind": "claude", "profile": "~/.seat-team",
                  "plan": 7, "sparkle": true },
                { "id": "codex", "label": "Codex", "kind": "codex", "plan": "Pro Lite" },
              ],
              "pollMinutes": 5,
            }
            """
        let config = try ConfigLoader.decode(Data(text.utf8), tokenDirectory: folder)

        // Every seat that is fine is still there, in order, and so is the one
        // whose plan was not a string: the field is ignored, not the seat.
        #expect(config.seats.map(\.id.rawValue) == ["work", "team", "codex"])
        #expect(config.seats[0].account == "work account")
        #expect(config.seats[1].plan == nil)
        #expect(config.seats[2].plan == "Pro Lite")

        // The template the first launch writes carries both keys, so the user
        // is told they exist without the app inventing a value for either.
        let template = try ConfigLoader.decode(Data(ConfigLoader.template.utf8),
                                               tokenDirectory: folder)
        #expect(template.seats.isEmpty == false)
        #expect(ConfigLoader.template.contains("account"))
        #expect(ConfigLoader.template.contains("plan"))

        // A text size outside the range is clamped rather than crashed on,
        // whichever end it came from, on the value and off the state file.
        #expect(TextScale(step: 9_999) == TextScale.largest)
        #expect(TextScale(step: -9_999) == TextScale.smallest)
        let wild = Data(#"{"textSizeStep": 9999, "timeZone": "Europe/Lisbon"}"#.utf8)
        let state = try JSONDecoder().decode(AppState.self, from: wild)
        #expect(TextScale.steps.contains(state.textSizeStep))
        #expect(state.timeZone == "Europe/Lisbon")
        // A state file with no size at all is the ordinary one.
        let quiet = try JSONDecoder().decode(AppState.self, from: Data("{}".utf8))
        #expect(quiet.textSizeStep == TextScale.default.step)
    }
}
