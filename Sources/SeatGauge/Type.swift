import SeatGaugeCore
import SwiftUI

/// The panel's type, with one swap point: a family that
/// registered is drawn with, and anything else falls back to the system font,
/// so a bundle missing a face is still a readable panel.
enum Type {
    static var registered: Set<String> = []

    /// The one weight the panel draws: the faces' lightest, their default
    /// instance. Their regular, in the ink on the dark ground, reads as bold
    /// beside it.
    static let weight = Font.Weight.light

    /// The display face, in the panel's weight unless the call names one.
    static func display(_ size: CGFloat, weight: Font.Weight = weight) -> Font {
        font("Funnel Display", size, weight, .default)
    }

    static func ui(_ size: CGFloat) -> Font {
        font("Funnel Sans", size, weight, .default)
    }

    static func mono(_ size: CGFloat) -> Font {
        font("Chivo Mono", size, weight, .monospaced)
    }

    /// Every size above is written at the ordinary text size and drawn at the
    /// one the user chose, so the whole panel scales from one place and the
    /// call sites keep saying what they meant.
    private static func font(_ family: String, _ size: CGFloat,
                             _ weight: Font.Weight, _ design: Font.Design) -> Font {
        let points = CGFloat(TextScale.current.scaled(Double(size)))
        guard let name = FontManifest.familyName(family, registered: registered) else {
            return .system(size: points, weight: weight, design: design)
        }
        return Font.custom(name, size: points).weight(weight)
    }
}
