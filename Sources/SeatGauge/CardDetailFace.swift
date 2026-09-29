import SeatGaugeCore
import SwiftUI

private typealias Base = CardDetailMetrics.Base

/// The card's detail face: the header naming the account, the status line,
/// the plot filling what the glance face's height leaves, and the controls.
/// It never asks for more than its floor, so the glance face sets the card's
/// height.
struct DetailFace: View {
    let card: CardModel
    let detail: CardDetail
    @Environment(\.pinnedVerticalFactor) private var pinned

    var body: some View {
        let factor = pinned ?? VerticalFit.current
        let gap = { (base: CGFloat) in Spacer().frame(height: CardDetailMetrics.gap(base, factor)) }
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(card: card, face: .detail)
            gap(Base.headerToStatus)
            Self.row(detail.status)
            gap(Base.statusToPlot)
            PlotView(plot: detail.plot)
                .frame(minHeight: CardDetailMetrics.plotFloor, idealHeight: CardDetailMetrics.plotFloor,
                       maxHeight: .infinity)
            gap(Base.plotToControls)
            ControlsRow(choice: GaugeMirror.shared.choice).frame(height: CardDetailMetrics.lineHeight)
        }
    }

    /// One line, kept whether or not it says anything, cut in the middle.
    static func row(_ line: DetailLine?) -> some View {
        Text(line?.text ?? " ")
            .font(Type.mono(CardDetailMetrics.Base.text))
            .foregroundStyle(line?.tone.color ?? Tone.inkDim)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, minHeight: CardDetailMetrics.lineHeight,
                   maxHeight: CardDetailMetrics.lineHeight, alignment: .leading)
    }
}

/// The bars, or the one line that stands in for them. The pointer's x picks
/// the bar whose centre is nearest, so every bucket is reachable; the status
/// line above names it.
struct PlotView: View {
    let plot: DetailPlot

    var body: some View {
        GeometryReader { space in
            ZStack(alignment: .bottomLeading) {
                switch plot {
                case let .bars(shares, selected):
                    Bars(shares: shares, only: nil).fill(Tone.inkMuted)
                    if let selected { Bars(shares: shares, only: selected).fill(Tone.ink) }
                case let .line(line):
                    DetailFace.row(line).frame(maxHeight: .infinity)
                }
            }
            .frame(width: space.size.width, height: space.size.height, alignment: .bottomLeading)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard case let .active(point) = phase, case let .bars(shares, _) = plot
                else { return GaugeMirror.shared.select(nil) }
                GaugeMirror.shared.select(CardDetailMetrics.bucket(at: point.x, count: shares.count,
                                                                   width: space.size.width))
            }
        }
    }
}

/// A read-out in a small box, drawn over the Spend graph.
struct Callout: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Type.mono(CardDetailMetrics.Base.text))
            .foregroundStyle(Tone.ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, CardDetailMetrics.Base.calloutPadding)
            .frame(height: CardDetailMetrics.lineHeight)
            .background(Rectangle().fill(Tone.bg))
            .overlay(Rectangle().stroke(Tone.inkDim, lineWidth: 0.5))
    }
}

/// Each share as a bar from the bottom; `only` draws one bar, for the ink.
struct Bars: Shape {
    let shares: [Double]
    let only: Int?

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let bars = MainActor.assumeIsolated { CardDetailMetrics.bars(count: shares.count, width: rect.width) }
        guard let bars else { return path }
        for (index, share) in shares.enumerated() where only == nil || only == index {
            let height = rect.height * CGFloat(min(1, max(0, share)))
            path.addRect(CGRect(x: rect.minX + CGFloat(index) * (bars.bar + bars.gap), y: rect.maxY - height,
                                width: bars.bar, height: height))
        }
        return path
    }
}

/// `W · M · 6M · Y` and `TOKENS · $`, the chosen word of each in ink.
struct ControlsRow: View {
    let choice: DetailChoice

    static let rangeWords: [(HistoryRange, String)] = [(.week, "W"), (.month, "M"), (.halfYear, "6M"), (.year, "Y")]
    static let measureWords: [(Measure, String)] = [(.tokens, "TOKENS"), (.usd, "$")]

    static func words(for choice: DetailChoice) -> (ranges: [DetailLine], measures: [DetailLine]) {
        (rangeWords.map { DetailLine(text: $0.1, tone: $0.0 == choice.range ? .ink : .dim) },
         measureWords.map { DetailLine(text: $0.1, tone: $0.0 == choice.measure ? .ink : .dim) })
    }

    var body: some View {
        let words = Self.words(for: choice)
        HStack(spacing: 0) {
            ForEach(Array(Self.rangeWords.enumerated()), id: \.offset) { index, pair in
                if index > 0 { dot }
                word(words.ranges[index]) { try? GaugeMirror.shared.choose(range: pair.0) }
            }
            Spacer(minLength: CardDetailMetrics.controlsSpacing)
            ForEach(Array(Self.measureWords.enumerated()), id: \.offset) { index, pair in
                if index > 0 { dot }
                word(words.measures[index]) { try? GaugeMirror.shared.choose(measure: pair.0) }
            }
        }
    }

    private var dot: some View {
        Label(text: "·", color: Tone.inkDim, size: CardDetailMetrics.Base.text)
            .fixedSize()
            .frame(width: CardDetailMetrics.controlsSpacing)
    }

    private func word(_ line: DetailLine, _ pick: @escaping () -> Void) -> some View {
        Label(text: line.text, color: line.tone.color, size: CardDetailMetrics.Base.text)
            .fixedSize()
            .contentShape(Rectangle())
            .onTapGesture(perform: pick)
    }
}
