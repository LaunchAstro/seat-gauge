import AppKit
import CoreText
import Foundation
import SwiftUI
import Testing

import SeatGaugeCore
@testable import SeatGauge

/// Digit tracking, the light appearance and the palettes. The window case
/// builds a real `WindowController` under an autosave name of its own and
/// forgets it when it ends.
@Suite(.sharedMirror) @MainActor struct AppearanceTests {

    static func freshName() -> String { "SeatGaugeHeightTest-\(UUID().uuidString)" }

    static func forget(_ name: String) {
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)")
    }

    static func controller(_ name: String) -> WindowController {
        _ = NSApplication.shared
        return WindowController(autosaveName: name, rootView: Root())
    }

    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func rgba(_ color: Color) -> [CGFloat] {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return [ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent]
    }

    /// Luminance of a colour laid over a ground, so a translucent ink is read
    /// as it is drawn.
    static func luminance(_ color: Color, over ground: Color) -> CGFloat {
        let c = rgba(color), g = rgba(ground)
        let mixed = (0..<3).map { c[$0] * c[3] + g[$0] * (1 - c[3]) }
        return 0.2126 * mixed[0] + 0.7152 * mixed[1] + 0.0722 * mixed[2]
    }

    static func same(_ a: Color, _ b: Color) -> Bool {
        zip(rgba(a), rgba(b)).allSatisfy { abs($0 - $1) < 0.002 }
    }

    // MARK: - Looser digits that still fit their columns

    @Test func digitsCarryTrackingAndStillFitTheirColumns() throws {
        let fonts = Self.root.appendingPathComponent("Resources/Fonts")
        for file in ["FunnelDisplay[wght].ttf", "ChivoMono[wght].ttf"] {
            CTFontManagerRegisterFontsForURL(fonts.appendingPathComponent(file) as CFURL, .process, nil)
        }
        let was = GaugeMirror.shared.textScale
        defer { GaugeMirror.shared.textScale = was }

        GaugeMirror.shared.textScale = .normal
        #expect(abs(CardMetrics.digitTracking - 1) < 0.25)

        var trackings: [CGFloat] = []
        for step in TextScale.steps {
            let scale = TextScale(step: step)
            GaugeMirror.shared.textScale = scale
            let tracking = CardMetrics.digitTracking
            trackings.append(tracking)
            func width(_ text: String, family: String, base: CGFloat) -> CGFloat {
                let size = CGFloat(scale.scaled(Double(base)))
                let face = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
                let widest = [face, NSFont.systemFont(ofSize: size),
                              NSFont.monospacedSystemFont(ofSize: size, weight: .regular)]
                    .compactMap { $0 }
                    .map { font in
                        NSAttributedString(string: text, attributes: [.font: font, .kern: tracking])
                            .size().width
                    }
                return widest.max() ?? .greatestFiniteMagnitude
            }
            #expect(width("12d 23h", family: "Funnel Display", base: 12) <= CardMetrics.countdownWidth)
            #expect(width("100%", family: "Chivo Mono", base: 9) <= CardMetrics.percentWidth)
        }
        #expect(zip(trackings, trackings.dropFirst()).allSatisfy { $0 < $1 })
    }

    // MARK: - A light appearance toggle, off by default

    @Test func lightAppearanceTogglesPersistsAndDefaultsOff() throws {
        #expect(AppState().lightAppearance == false)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seat-gauge-appearance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StateStore(file: directory.appendingPathComponent("state.json"))
        #expect(AppearanceStore.load(store) == false)
        try AppearanceStore.save(true, to: store)
        #expect(AppearanceStore.load(store) == true)
        #expect(store.load().textSizeStep == TextScale.default.step)
        let written = try String(contentsOf: store.file, encoding: .utf8)
        #expect(written.contains("\"lightAppearance\""))
        #expect(written.contains("\"textSizeStep\""))

        let was = GaugeMirror.shared.lightAppearance
        defer { GaugeMirror.shared.lightAppearance = was }

        // The menu's item, with its checkmark following the toggle, and the
        // four commands still first.
        GaugeMirror.shared.lightAppearance = false
        let menu = PanelMenu()
        #expect(menu.menu.items.prefix(4).map(\.title)
            == ["Sync all", "Launch at login", "Reveal config", "Quit"])
        let item = try #require(menu.menu.items.first { $0.title == "Light appearance" })
        #expect(item.state == .off)
        GaugeMirror.shared.lightAppearance = true
        menu.rebuild()
        #expect(menu.menu.items.first { $0.title == "Light appearance" }?.state == .on)

        // The window follows it, ground and all.
        let name = Self.freshName()
        defer { Self.forget(name) }
        let built = Self.controller(name)
        built.applyAppearance()
        #expect(built.window.appearance?.name == .aqua)
        GaugeMirror.shared.lightAppearance = false
        built.applyAppearance()
        #expect(built.window.appearance?.name == .darkAqua)

        // Off is the dark palette.
        let dark = Palette.dark
        #expect(Self.same(dark.bg, Color(red: 0.043, green: 0.043, blue: 0.055)))
        #expect(Self.same(dark.ink, Color(white: 0.98)))
        #expect(Self.same(dark.inkMuted, Color(white: 0.98).opacity(0.55)))
        #expect(Self.same(dark.inkDim, Color(white: 0.98).opacity(0.36)))
        #expect(Self.same(dark.rule, Color(white: 0.98).opacity(0.10)))
        #expect(Self.same(dark.accent, Color(red: 116 / 255, green: 92 / 255, blue: 238 / 255)))
        #expect(Self.same(Tone.bg, dark.bg))

        // On is a white ground, dark ink, muted ink between them, the same
        // accent, and a meter track that shows on white.
        let light = Palette.light
        #expect(Self.luminance(light.bg, over: light.bg) > 0.95)
        #expect(Self.luminance(light.ink, over: light.bg) < 0.2)
        let muted = Self.luminance(light.inkMuted, over: light.bg)
        #expect(muted > Self.luminance(light.ink, over: light.bg))
        #expect(muted < Self.luminance(light.bg, over: light.bg) - 0.2)
        #expect(Self.same(light.accent, dark.accent))
        #expect(Self.luminance(light.meterTrack, over: light.bg)
            < Self.luminance(light.bg, over: light.bg) - 0.05)
    }
}
