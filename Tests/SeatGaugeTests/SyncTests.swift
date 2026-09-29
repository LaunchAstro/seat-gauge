import AppKit
import Foundation
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// The synced line, a token seat's own date, the busy icon and the hovered
/// bar's read-out.
@Suite(.serialized, .sharedMirror) @MainActor struct SyncTests {

    typealias Glance = GlanceFaceTests
    typealias History = DetailHistoryTests

    static let now = Glance.now

    static func token(_ id: String) -> Seat {
        Seat(id: SeatID(rawValue: id), label: id,
             kind: .claude(profileDir: URL(fileURLWithPath: "/tmp/seat-gauge-\(id)")),
             tokenFile: URL(fileURLWithPath: "/tmp/seat-gauge-\(id)/token"))
    }

    static func live(_ seat: Seat, minutesAgo: Double) -> SeatState {
        .live(Reading(seat: seat.id, windows: [Glance.window(.weekly, used: 30)],
                      takenAt: now.addingTimeInterval(-minutesAgo * 60), plan: nil))
    }

    static func model(_ pairs: [(Seat, SeatState)], syncing: Set<SeatID> = [], pollMinutes: Int = 5) -> PanelModel {
        let states = Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.id, $0.1) })
        return PanelModel.make(snapshot: Snapshot(states: states, order: pairs.map(\.0.id)), seats: pairs.map(\.0),
                               now: now, hovered: nil, selected: nil, histories: [:], syncing: syncing,
                               pollMinutes: pollMinutes)
    }

    // MARK: - The synced line

    @Test func theSyncedLineCountsTheSeatsThatPollThemselves() {
        let work = Glance.claude("work"), codex = Glance.codex("codex"), paid = Self.token("paid")
        // Both read within two intervals: the oldest's age.
        #expect(Self.model([(work, Self.live(work, minutesAgo: 2)), (codex, Self.live(codex, minutesAgo: 7))])
            .updated == "all seats synced 7m ago")
        // One past two intervals is behind.
        #expect(Self.model([(work, Self.live(work, minutesAgo: 2)), (codex, Self.live(codex, minutesAgo: 10))])
            .updated == "1 of 2 synced")
        // The interval sets the limit.
        #expect(Self.model([(work, Self.live(work, minutesAgo: 2)), (codex, Self.live(codex, minutesAgo: 10))],
                           pollMinutes: 15).updated == "all seats synced 10m ago")
        // A seat that failed is behind, however recent its last reading.
        let failed = SeatState.unreadable(reason: "timed out", last: nil)
        #expect(Self.model([(work, Self.live(work, minutesAgo: 1)), (codex, failed)]).updated == "1 of 2 synced")
        // A hidden dormant seat and a token seat are left out.
        let asleep = SeatState.dormant(reason: "not signed in")
        let stale = Self.model([(work, Self.live(work, minutesAgo: 1)), (codex, asleep),
                                (paid, Self.live(paid, minutesAgo: 600))])
        #expect(stale.updated == "all seats synced 1m ago")
        #expect(Self.model([(paid, Self.live(paid, minutesAgo: 3))]).updated == "not polled yet")
    }

    @Test func aTokenSeatsCardDatesItself() {
        let work = Glance.claude("work"), paid = Self.token("paid")
        let model = Self.model([(work, Self.live(work, minutesAgo: 2)), (paid, Self.live(paid, minutesAgo: 90))])
        #expect(model.cards.map(\.dated) == [nil, "synced 1:30 ago"])
        #expect(model.cards.map(\.isDimmed) == [false, false])
        // A failed token seat says stale instead.
        let failed = Self.model([(paid, .unreadable(reason: "timed out",
                                                    last: Reading(seat: paid.id, windows: [], takenAt: Self.now, plan: nil)))])
        #expect(failed.cards.first?.dated == nil)
        #expect(failed.cards.first?.stale != nil)
    }

    // MARK: - Sync controls

    @Test func aSeatBeingReadDrawsItsIconBusyAndTheMenuSyncsAll() {
        let work = Glance.claude("work"), codex = Glance.codex("codex")
        let model = Self.model([(work, Self.live(work, minutesAgo: 1)), (codex, Self.live(codex, minutesAgo: 1))],
                               syncing: [codex.id])
        #expect(model.cards.map(\.isSyncing) == [false, true])

        let mirror = GaugeMirror.shared
        let kept = mirror.syncAll
        defer { mirror.syncAll = kept }
        var asked = 0
        mirror.syncAll = { asked += 1 }
        let menu = PanelMenu()
        guard let item = menu.menu.items.first(where: { $0.title == "Sync all" }), let action = item.action else {
            Issue.record("no Sync all"); return
        }
        NSApplication.shared.sendAction(action, to: item.target, from: item)
        #expect(asked == 1)
    }

    // MARK: - The read-out

    @Test func theSelectedBarIsNamedByTheStatusLine() {
        let record = SpendRecord.available([History.row("work", "2026-09-23", input: 1_200_000)])
        let picked = History.model(record: record, hovered: History.work, selected: 2)
        #expect(picked.details[History.work]?.status?.text == "Wed 23 Sep · 1.2M tokens")
        #expect(History.model(record: record, hovered: History.work).details[History.work]?.status?.text
                != "Wed 23 Sep · 1.2M tokens")
    }
}

/// A fresh install: no saved frame, the empty state first and the cards a
/// poll later. Every card is drawn and the window stays on its screen.
@Suite(.serialized, .sharedMirror) @MainActor struct FirstLaunchTests {

    typealias Bar = TitleBarTests

    @Test func aFreshInstallOpensWithEveryCardOnScreen() async {
        await Bar.keepingMirror {
            GaugeMirror.shared.textScale = .normal
            GaugeMirror.shared.apply(Snapshot(states: [:], order: []), seats: [])
            for count in [3, 4] {
                let name = Bar.freshName()
                defer { Bar.forget(name) }
                let built = Bar.controller(name)
                defer { built.window.close() }
                built.show()
                let seats = (1...count).map { Seat(id: SeatID(rawValue: "seat\($0)"), label: "seat\($0)", kind: .codex) }
                let states = Dictionary(uniqueKeysWithValues: seats.map {
                    ($0.id, SeatState.live(Reading(seat: $0.id, windows: [GlanceFaceTests.window(.weekly, used: 30)],
                                                   takenAt: Date(), plan: nil)))
                })
                GaugeMirror.shared.apply(Snapshot(states: states, order: seats.map(\.id)), seats: seats)
                built.refit(.drawn)
                await Bar.settle()
                let frame = built.window.frame
                #expect(built.window.contentLayoutRect.width >= PanelLayout.minimumContentWidth(cards: count) - 0.5,
                        "\(count): \(frame)")
                guard let screen = built.window.screen?.visibleFrame, screen.width >= frame.width else { continue }
                #expect(screen.contains(frame), "\(count) cards: \(frame) off \(screen)")
            }
        }
    }
}
