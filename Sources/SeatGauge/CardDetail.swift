import Foundation
import SeatGaugeCore

/// Which face a card draws. Both are laid out, so the card is as tall as the
/// taller and a hover never moves it.
enum CardFace: Equatable {
    case glance, detail
}

struct DetailLine: Equatable {
    let text: String
    let tone: LineTone
}

/// The bars as shares of the tallest, or one line saying why there are none.
enum DetailPlot: Equatable {
    case bars([Double], selected: Int?)
    case line(DetailLine)
}

/// The range and measure the detail draws, kept in `state.json`.
struct DetailChoice: Equatable {
    var range: HistoryRange = .week
    var measure: Measure = .tokens
}

enum DetailChoiceStore {
    static func load(_ store: StateStore = StateStore()) -> DetailChoice {
        let state = store.load()
        return DetailChoice(range: state.historyRange, measure: state.measure)
    }
}

/// Everything the detail face draws for one card, as values.
struct CardDetail: Equatable {
    /// The selected bucket's read-out, else a partial or unavailable
    /// history's reason, else the pace or stale line.
    let status: DetailLine?
    let plot: DetailPlot
    let history: SeatHistory?

    static func make(card: CardModel, history: SeatHistory?, selected: Int?) -> CardDetail {
        let buckets = history?.outcome.buckets ?? []
        let picked = selected.flatMap { buckets.indices.contains($0) ? $0 : nil }
        let reason: DetailLine? = switch history?.outcome {
        case let .partial(_, reason): DetailLine(text: reason, tone: .dim)
        case let .unavailable(reason): DetailLine(text: reason, tone: .warning)
        default: nil
        }
        let status = picked.map { DetailLine(text: buckets[$0].readOut, tone: .ink) }
            ?? reason
            ?? card.pace.map { DetailLine(text: $0.text, tone: $0.tone) }
            ?? card.stale.map { DetailLine(text: $0, tone: .dim) }
        return CardDetail(status: status, plot: plot(history, picked), history: history)
    }

    var quiet: CardDetail {
        CardDetail(status: nil, plot: plot, history: history)
    }

    private static func plot(_ history: SeatHistory?, _ selected: Int?) -> DetailPlot {
        guard let history else { return .line(DetailLine(text: "spend record not read yet", tone: .warning)) }
        if history.noListPrice { return .line(DetailLine(text: "no list price for this seat", tone: .dim)) }
        switch history.outcome {
        case .empty: return .line(DetailLine(text: "no usage recorded in this range", tone: .dim))
        // Its reason is the status line, so the plot is left empty.
        case .unavailable: return .bars([], selected: nil)
        case let .available(buckets), let .partial(buckets, _):
            let tallest = buckets.map(\.amount).max() ?? 0
            return .bars(buckets.map { tallest > 0 ? ($0.amount / tallest).asDouble : 0 }, selected: selected)
        }
    }
}
