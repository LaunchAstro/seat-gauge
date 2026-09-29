import Foundation
import SeatGaugeCore

extension TextScale {
    /// The size the panel is drawn at, held on the mirror rather than in a
    /// global: `Type` and `CardMetrics` read it inside a view body, so the
    /// body tracks it like any other observed value.
    static var current: TextScale { GaugeMirror.shared.textScale }
}

/// The chosen size, kept in `state.json` beside the other small facts the app
/// holds between launches, so it survives a quit and a relaunch. A file that
/// cannot be read is the ordinary size, as every other field in that file is.
enum TextSizeStore {
    static func load(_ store: StateStore = StateStore()) -> TextScale {
        TextScale(step: store.load().textSizeStep)
    }

    static func save(_ scale: TextScale, to store: StateStore = StateStore()) throws {
        try store.update { $0.textSizeStep = scale.step }
    }
}

/// The light appearance toggle, kept in `state.json` beside the text size. A
/// file that cannot be read is the dark panel an untouched install opens on.
enum AppearanceStore {
    static func load(_ store: StateStore = StateStore()) -> Bool {
        store.load().lightAppearance
    }

    static func save(_ light: Bool, to store: StateStore = StateStore()) throws {
        try store.update { $0.lightAppearance = light }
    }
}
