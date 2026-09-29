import SwiftUI

/// The panel's colours, in two sets of the same names: dark, the default,
/// and light. Every
/// colour the panel draws is one of these; no view picks its own.
struct Palette {
    let bg: Color
    let ink: Color
    let inkMuted: Color
    let inkDim: Color
    let rule: Color
    /// Every card's box on the ground, the best card's included.
    let box: Color
    /// The ALL card's box, a touch lighter, so it reads as the summary.
    let summaryBox: Color
    /// The unfilled part of a meter.
    let meterTrack: Color
    let accent: Color
    let success: Color
    let warning: Color
    let danger: Color

    static let accent = Color(red: 116 / 255, green: 92 / 255, blue: 238 / 255)

    static let dark = palette(
        bg: Color(red: 0.043, green: 0.043, blue: 0.055),
        ink: Color(white: 0.98),
        muted: 0.55, dim: 0.36, track: 0.10, summary: 0.09)

    static let light = palette(
        bg: Color(white: 0.98),
        ink: Color(white: 0.12),
        muted: 0.60, dim: 0.42, track: 0.14, summary: 0.025)

    static func of(_ scheme: ColorScheme) -> Palette { scheme == .dark ? dark : light }

    /// The two palettes differ in their ground, their ink and how far the
    /// quieter inks fall back; the accent and the three meter tones are the
    /// same in both. The ALL card's box is lighter than the others in both:
    /// more of the pale ink on the dark ground, less of the dark ink on the
    /// light one.
    private static func palette(bg: Color, ink: Color, muted: Double, dim: Double,
                                track: Double, summary: Double) -> Palette {
        Palette(bg: bg, ink: ink,
                inkMuted: ink.opacity(muted),
                inkDim: ink.opacity(dim),
                rule: ink.opacity(0.10),
                box: ink.opacity(0.05),
                summaryBox: ink.opacity(summary),
                meterTrack: ink.opacity(track),
                accent: accent,
                success: Color(red: 0x34 / 255, green: 0xd3 / 255, blue: 0x99 / 255),
                warning: Color(red: 0xfb / 255, green: 0xbf / 255, blue: 0x24 / 255),
                danger: Color(red: 0xf8 / 255, green: 0x71 / 255, blue: 0x71 / 255))
    }
}

/// The palette the user chose, read inside a view body, so a toggle redraws
/// the panel as a change of text size does.
enum Tone {
    static var current: Palette { GaugeMirror.shared.lightAppearance ? .light : .dark }

    static var bg: Color { current.bg }
    static var ink: Color { current.ink }
    static var inkMuted: Color { current.inkMuted }
    static var inkDim: Color { current.inkDim }
    static var rule: Color { current.rule }
    static var box: Color { current.box }
    static var summaryBox: Color { current.summaryBox }
    static var meterTrack: Color { current.meterTrack }
    static var accent: Color { current.accent }
    static var success: Color { current.success }
    static var warning: Color { current.warning }
    static var danger: Color { current.danger }
}
