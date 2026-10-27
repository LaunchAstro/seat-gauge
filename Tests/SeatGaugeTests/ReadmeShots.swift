import AppKit
import Foundation
import SwiftUI
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// The README's pictures, drawn by the real window from made-up seats,
/// machines, spend and sessions, so they can be redrawn after any change to
/// the panel. Nothing here reads the home it runs under. The drawing runs
/// only when `SEATGAUGE_SHOTS` names the folder the images go in, which
/// `make shots` sets to `docs/images`; it needs a logged-in screen to draw on.
@Suite(.serialized, .sharedMirror) @MainActor struct ReadmeShots {
    typealias Widths = CardWidthTests

    nonisolated static let folder = ProcessInfo.processInfo.environment["SEATGAUGE_SHOTS"].map { URL(fileURLWithPath: $0) }

    /// The countdowns and the synced line read the clock, so every fixture
    /// time is counted from the minute the run starts.
    static let now: Date = {
        let at = Date()
        return at.addingTimeInterval(-at.timeIntervalSince1970.truncatingRemainder(dividingBy: 60))
    }()

    /// One picture: the tab, the window's content width, the height the
    /// user dragged to (nil is the resting height), the appearance and the
    /// card under the pointer.
    struct Shot {
        let name: String
        let tab: SeatGauge.Tab
        var width: CGFloat = 1_160
        var height: CGFloat? = nil
        var light = false
        var hovered: SeatID? = nil
    }

    static let shots = [
        Shot(name: "seats", tab: .seats),
        Shot(name: "load", tab: .load),
        Shot(name: "spend", tab: .spend),
        // Two rows' height, so the list shows more than its first session.
        Shot(name: "log", tab: .log, height: 280),
        Shot(name: "seats-detail", tab: .seats, hovered: SeatID(rawValue: "work")),
        Shot(name: "seats-tall", tab: .seats, width: 600, height: 640),
        Shot(name: "seats-light", tab: .seats, light: true),
    ]

    /// The committed pictures, which every run checks, screen or not: each
    /// shot is in `docs/images`, small, a PNG with no text chunk to carry a
    /// name or a path, and shown in the README with alt text, beside the
    /// secondary monitor note.
    @Test func theReadmeShowsEveryShot() throws {
        let images = Widths.root.appendingPathComponent("docs/images")
        let readme = try String(contentsOf: Widths.root.appendingPathComponent("README.md"), encoding: .utf8)
        let committed = try FileManager.default.contentsOfDirectory(atPath: images.path)
            .filter { $0.hasSuffix(".png") }
        #expect(Set(committed) == Set(Self.shots.map { "\($0.name).png" }))
        for shot in Self.shots {
            let path = "docs/images/\(shot.name).png"
            let data = try #require(FileManager.default.contents(atPath: images.appendingPathComponent("\(shot.name).png").path),
                                    "\(path) is missing")
            #expect(data.count < 300_000, "\(path) is \(data.count) bytes")
            #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), "\(path) is not a PNG")
            #expect(Self.chunks(data).allSatisfy { !["tEXt", "iTXt", "zTXt"].contains($0) }, "\(path) carries text")
            let markdown = readme.contains(try Regex("!\\[[^\\]]{12,}\\]\\(\(path)\\)"))
            let html = readme.contains(try Regex("<img src=\"\(path)\"[^>]* alt=\"[^\"]{12,}\""))
            #expect(markdown || html, "\(path) is not in the README with alt text")
        }
        #expect(readme.contains("secondary monitor"))
        #expect(readme.contains("vertical (portrait) display"))
    }

    /// A PNG's chunk types in order, from its length and type headers.
    static func chunks(_ data: Data) -> [String] {
        let bytes = [UInt8](data)
        var types: [String] = []
        var at = 8
        while at + 8 <= bytes.count {
            let length = bytes[at..<at + 4].reduce(0) { $0 << 8 | Int($1) }
            types.append(String(decoding: bytes[at + 4..<at + 8], as: UTF8.self))
            at += 12 + length
        }
        return types
    }

    @Test(.enabled(if: folder != nil, "set SEATGAUGE_SHOTS to the folder the images go in"))
    func drawTheReadmeImages() async throws {
        let folder = try #require(Self.folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let faces = Type.registered
        Type.registered = Widths.registerBundledFaces()
        let mirror = GaugeMirror.shared
        let was = (mirror.snapshot, mirror.seats, mirror.tab, mirror.lightAppearance, mirror.machines,
                   mirror.machineStates, mirror.machineHistory, mirror.sessionLog)
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("readme-shots-\(UUID())")
        defer {
            Type.registered = faces
            mirror.apply(was.0, seats: was.1)
            mirror.tab = was.2
            mirror.lightAppearance = was.3
            mirror.machines = was.4
            mirror.machineStates = was.5
            mirror.machineHistory = was.6
            mirror.sessionLog = was.7
            mirror.hover(nil)
            try? FileManager.default.removeItem(at: scratch)
        }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let csv = scratch.appendingPathComponent("spend.csv")
        try SpendCSV.write(Self.spend, to: csv)
        mirror.readSpend(csv: csv, state: scratch.appendingPathComponent("state.json"),
                         attribution: scratch.appendingPathComponent("attribution.json"))
        mirror.apply(Self.snapshot, seats: Self.seats)
        mirror.machines = Self.machines
        mirror.machineStates = Self.machineStates
        mirror.machineHistory = Self.machineHistory
        mirror.sessionLog = SessionLogFile(updated: Self.now, sessions: Self.sessions)

        for shot in Self.shots {
            mirror.tab = shot.tab
            mirror.lightAppearance = shot.light
            mirror.hover(nil)
            let file = folder.appendingPathComponent("\(shot.name).png")
            try await Self.draw(shot, to: file)
            #expect(FileManager.default.fileExists(atPath: file.path), "\(shot.name)")
        }
    }

    /// The window as the app builds it, at the shot's width and height,
    /// drawn with its title bar at twice its size.
    static func draw(_ shot: Shot, to file: URL) async throws {
        let name = "SeatGaugeReadmeShot-\(UUID().uuidString)"
        let key = "NSWindow Frame \(name)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        // A saved frame is the user's width, which the window keeps rather
        // than widening to show every card in one row.
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1_440, height: 900)
        UserDefaults.standard.set("\(Int(screen.minX) + 40) \(Int(screen.minY) + 40) \(Int(shot.width)) 200 "
            + "\(Int(screen.minX)) \(Int(screen.minY)) \(Int(screen.width)) \(Int(screen.height))", forKey: key)
        let controller = WindowController(autosaveName: name, rootView: Root())
        defer { controller.window.close() }
        controller.show()
        var frame = controller.window.frame
        frame.size.width = shot.width
        controller.window.setFrame(frame, display: true)
        controller.panelHeight.chosen = shot.height
        controller.refit(.now)
        await settle()
        if let hovered = shot.hovered {
            GaugeMirror.shared.hover(hovered)
            // The detail face fades in.
            try? await Task.sleep(for: .milliseconds(400))
        }
        await settle()
        let view = try #require(controller.window.contentView?.superview)
        try write(view, to: file)
    }

    /// Two turns of the main queue: one to draw at the new size, one for the
    /// refit that drawing schedules.
    static func settle() async {
        for _ in 0..<2 { try? await Task.sleep(for: .milliseconds(250)) }
    }

    /// The window's frame view, title bar and all, into a bitmap at two
    /// pixels a point with the window's rounded corners cut out.
    static func write(_ view: NSView, to file: URL) throws {
        let size = view.bounds.size
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                                pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        let rounded = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide,
                                                    pixelsHigh: rep.pixelsHigh, bitsPerSample: 8,
                                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rounded.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rounded)
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 10, yRadius: 10).addClip()
        rep.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(rounded.representation(using: .png, properties: [:]))
        try data.write(to: file)
    }

    // MARK: - The made-up data

    static let seats: [Seat] = [
        seat("personal", "Personal", plan: "Max 5x"),
        seat("work", "Work", plan: "Max 20x"),
        seat("team", "Team", plan: "Team"),
        Seat(id: SeatID(rawValue: "codex"), label: "Codex", kind: .codex, plan: "Pro"),
    ]

    static func seat(_ id: String, _ label: String, plan: String) -> Seat {
        let profile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("readme-shots-\(id)")
        return Seat(id: SeatID(rawValue: id), label: label, kind: .claude(profileDir: profile), plan: plan)
    }

    /// Each seat's used share of its 5-hour, weekly and Fable windows, and
    /// how many minutes until each resets.
    static let usage: [String: [(WindowKind, Int, Double)]] = [
        "personal": [(.fiveHour, 35, 150), (.weekly, 40, 3 * 1_440 + 300)],
        "work": [(.fiveHour, 70, 75), (.weekly, 55, 2 * 1_440 + 600), (.fable, 30, 2 * 1_440 + 600)],
        "team": [(.fiveHour, 10, 240), (.weekly, 20, 5 * 1_440 + 120)],
        "codex": [(.fiveHour, 25, 200), (.weekly, 45, 4 * 1_440 + 60)],
    ]

    static var snapshot: Snapshot {
        var states: [SeatID: SeatState] = [:]
        for seat in seats {
            let windows = (usage[seat.id.rawValue] ?? []).map { kind, used, minutes in
                SeatGaugeCore.Window(kind: kind, usedPercent: used, resetsAt: now.addingTimeInterval(minutes * 60),
                                     length: .seconds(kind == .fiveHour ? 5 * 3_600 : 7 * 86_400))
            }
            states[seat.id] = .live(Reading(seat: seat.id, windows: windows, takenAt: now.addingTimeInterval(-120),
                                            plan: seat.plan))
        }
        return Snapshot(states: states, order: seats.map(\.id))
    }

    static let machines = [Machine(id: "studio", label: "Studio"), Machine(id: "laptop", label: "Laptop", ssh: "laptop")]

    static var machineStates: [String: MachineState] {
        [
            "studio": .live(MachineReading(takenAt: now, cpuUsed: 42, load: [6, 5, 4], cores: 12, ramUsed: 58,
                                           ramBytes: 64 * 1_073_741_824, diskUsed: 46, diskFreeBytes: 540_000_000_000,
                                           agents: AgentCount(working: 3, blocked: 0, idle: 2))),
            "laptop": .live(MachineReading(takenAt: now, cpuUsed: 18, load: [2, 2, 2], cores: 10, ramUsed: 66,
                                           ramBytes: 32 * 1_073_741_824, diskUsed: 71, diskFreeBytes: 290_000_000_000,
                                           agents: AgentCount(working: 1, blocked: 1, idle: 0))),
        ]
    }

    /// Ten minutes of reads every 10 seconds, wandering around each reading.
    static var machineHistory: [String: [LoadSample]] {
        func wander(cpu: Int, ram: Int, free: Int64) -> [LoadSample] {
            (0..<60).map { step in
                let wave = sin(Double(step) / 5)
                return LoadSample(at: now.addingTimeInterval(Double(step - 59) * 10),
                                  cpu: cpu + Int(wave * 12), ram: ram + Int(wave * 3), diskFree: free)
            }
        }
        return ["studio": wander(cpu: 42, ram: 58, free: 540_000_000_000),
                "laptop": wander(cpu: 18, ram: 66, free: 290_000_000_000)]
    }

    /// Four weeks of sealed hours, a few a day per seat, heavier on weekdays.
    static var spend: [SpendRow] {
        let calendar = Calendar.current
        let day = DateFormatter()
        day.calendar = calendar
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let mix: [(seat: String, model: String, millions: Double)] = [
            ("personal", "claude-sonnet-5-5", 1.5),
            ("work", "claude-opus-5-5", 3),
            ("work", "claude-fable-5-1", 0.5),
            ("team", "claude-sonnet-5-5", 2),
            ("codex", "gpt-6.1-sol", 2.5),
        ]
        var rows: [SpendRow] = []
        for back in 1...27 {
            let date = calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: now)) ?? now
            let weekday = calendar.component(.weekday, from: date)
            let weight = (weekday == 1 || weekday == 7) ? 0.3 : 1 + 0.4 * sin(Double(back) / 3)
            for (index, line) in mix.enumerated() {
                let input = Int(line.millions * weight * (1 + 0.25 * Double((back + index) % 4)) * 1_000_000)
                let counts = TokenCounts(responses: 40, input: input / 10, output: input / 40, cacheRead: input)
                rows.append(SpendRow(seat: line.seat, day: day.string(from: date), hour: "10", model: line.model,
                                     counts: counts, usd: RateCard.bundled.usd(model: line.model, counts: counts),
                                     sealed: true))
            }
        }
        return rows
    }

    static var sessions: [SessionRow] {
        func row(_ machine: String, _ workspace: String, _ pane: String, tool: String, model: String,
                 effort: String, branch: String, status: String, started: Double, millions: Double,
                 usd: Int) -> SessionRow {
            var row = SessionRow(machine: machine, sessionId: "\(machine)-\(pane)", workspace: workspace, pane: pane,
                                 tool: tool, status: status, asOf: now)
            row.model = model
            row.effort = effort
            row.branch = branch
            row.startedAt = now.addingTimeInterval(-started * 60)
            let total = Int(millions * 1_000_000)
            row.tokens = TokenCounts(input: total * 9 / 10, output: total / 10)
            row.usd = Decimal(usd)
            return row
        }
        return [
            row("studio", "example-api-checkout-personal", "w1:p1", tool: "claude", model: "claude-opus-5-5",
                effort: "high", branch: "checkout-retry", status: "working", started: 42, millions: 3.2, usd: 18),
            row("studio", "example-web-search-work", "w2:p1", tool: "codex", model: "gpt-6.1-sol",
                effort: "medium", branch: "search-filters", status: "working", started: 95, millions: 5.8, usd: 12),
            row("laptop", "example-docs-guides-team", "w1:p2", tool: "claude", model: "claude-sonnet-5-5",
                effort: "medium", branch: "guides-refresh", status: "blocked", started: 20, millions: 0.9, usd: 2),
            row("studio", "example-api-billing-work", "w3:p1", tool: "claude", model: "claude-opus-5-5",
                effort: "high", branch: "billing-export", status: "idle", started: 180, millions: 7.5, usd: 31),
        ]
    }
}
