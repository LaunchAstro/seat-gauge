import Charts
import SeatGaugeCore
import SwiftUI

/// The Spend tab: one line per account plus the total, over the last 28 local
/// days, in tokens or list-price dollars. Two boxes like the seat cards: the
/// family totals on the left, the graph and its legend on the right.
struct SpendTab: View {
    let chart: SpendChart
    private var mirror: GaugeMirror { .shared }

    /// The totals' label and figure sizes, and the legend's.
    static let headingLabelSize: CGFloat = 9
    static let headingFigureSize: CGFloat = 10
    static let legendSize: CGFloat = 11

    /// The lines hover puts behind the focused one. A focus that names no
    /// drawn line dims nothing.
    static func dimmed(_ series: [SpendSeries], focus: String?) -> [String] {
        guard let focus, series.contains(where: { $0.key == focus }) else { return [] }
        return series.map(\.key).filter { $0 != focus }
    }

    /// A point's day and figure, for the callout over it; nothing for a point
    /// the chart does not draw.
    static func callout(for point: SpendPoint, in chart: SpendChart) -> String? {
        guard chart.series.contains(where: { $0.points.contains(point) }) else { return nil }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_AU")
        day.dateFormat = "EEE d MMM"
        return "\(day.string(from: point.day)) · \(chart.measure.figure(point.amount))"
    }

    static func lineTone(dimmed: Bool) -> Color { dimmed ? Tone.inkDim : Tone.ink }

    /// A legend name: dim when hover or the user has put its line away.
    static func legendTone(off: Bool, dimmed: Bool) -> Color { off || dimmed ? Tone.inkDim : Tone.inkMuted }

    /// A partial record's reason, dim, beside the legend. Nothing when the
    /// record is whole, and nothing when none of it was readable, since that
    /// reason stands in for the graph.
    static func reason(_ chart: SpendChart) -> String? {
        chart.unreadable == nil ? chart.note : nil
    }

    /// An unavailable record's reason is a warning; "no spend recorded yet" is not.
    static func messageIsWarning(_ chart: SpendChart) -> Bool { chart.unreadable != nil }

    /// Account lines take the palette in name order, hidden or not, so
    /// turning one off never recolours the rest; the total is the accent.
    private func colour(_ series: SpendSeries) -> Color {
        guard !series.isTotal else { return Tone.accent }
        let palette = [Tone.ink, Tone.success, Tone.warning, Tone.danger, Tone.inkMuted]
        let index = chart.series.firstIndex { $0.key == series.key } ?? 0
        return palette[index % palette.count]
    }

    /// A line's colour, or the dim tone while hover has put it behind another.
    private func tone(_ series: SpendSeries, dimmed: Bool) -> Color {
        dimmed ? Self.lineTone(dimmed: true) : colour(series)
    }

    private var visible: [SpendSeries] { chart.visible(hiding: mirror.hiddenLines) }

    /// The chart's floor and the gap under it, written at the ordinary size
    /// and scaled with the text. The chart fills the rest, so the tab fits
    /// inside the Seats content rather than raising it.
    static let chartFloor: CGFloat = 24
    static let gap: CGFloat = 4

    /// Two boxes side by side, which scroll sideways in a window narrowed
    /// to one card, as the Seats row does.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            boxes
            ScrollView(.horizontal) { boxes.frame(width: PanelLayout.minimumContentWidth(cards: 2)) }
                .scrollIndicators(.never)
                .frame(minWidth: CardMetrics.minimumWidth)
        }
    }

    private var boxes: some View {
        HStack(alignment: .top, spacing: 0) {
            totals.modifier(CardBox()).frame(width: CardMetrics.minimumWidth)
            graph.modifier(CardBox())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The measure switch over the family totals. The list asks for no
    /// height of its own, so the graph sets the tab's, and it scrolls when
    /// the panel is too short to show every family.
    private var totals: some View {
        VStack(alignment: .leading, spacing: CardMetrics.scaled(Self.gap)) {
            measureSwitch.fixedSize()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: CardMetrics.scaled(Self.gap) / 2) {
                    ForEach(chart.totals, id: \.group) { heading($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 0, idealHeight: 0, maxHeight: .infinity)
        }
    }

    private var graph: some View {
        VStack(alignment: .leading, spacing: CardMetrics.scaled(Self.gap)) {
            if let message = chart.emptyMessage {
                Text(message).font(Type.display(13))
                    .foregroundStyle(Self.messageIsWarning(chart) ? Tone.warning : Tone.ink)
                if let reason = Self.reason(chart) {
                    Text(reason).font(Type.mono(9)).foregroundStyle(Tone.inkDim).lineLimit(1)
                }
                Spacer(minLength: 0)
            } else {
                lines
                HStack(spacing: 8) {
                    // The names keep their room; the reason gives way.
                    legend.lineLimit(1).layoutPriority(1)
                    Spacer(minLength: 0)
                    if let reason = Self.reason(chart) {
                        Text(reason).font(Type.mono(9)).foregroundStyle(Tone.inkDim)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
            }
        }
    }

    /// `TOKENS · $`, the chosen one in ink and the other dim.
    private var measureSwitch: some View {
        HStack(spacing: 8) {
            ForEach([(Measure.tokens, "TOKENS"), (Measure.usd, "$")], id: \.1) { measure, word in
                if measure == .usd { Text("·").foregroundStyle(Tone.inkDim) }
                Text(word).foregroundStyle(mirror.measure == measure ? Tone.ink : Tone.inkDim)
                    .onTapGesture { mirror.measure = measure }
            }
        }
        .font(Type.mono(10))
    }

    private var lines: some View {
        let dimmed = Set(Self.dimmed(visible, focus: mirror.spendFocus))
        return Chart {
            ForEach(visible, id: \.key) { series in
                ForEach(series.points, id: \.day) { point in
                    LineMark(x: .value("Day", point.day, unit: .day),
                             y: .value(chart.measure == .usd ? "USD" : "Tokens", point.amount.asDouble),
                             series: .value("Account", series.key))
                        .foregroundStyle(tone(series, dimmed: dimmed.contains(series.key)))
                        .lineStyle(StrokeStyle(lineWidth: series.isTotal ? 2 : 1))
                }
            }
            if let point = mirror.spendPoint, let focus = mirror.spendFocus, !mirror.hiddenLines.contains(focus),
               let callout = Self.callout(for: point, in: chart) {
                RuleMark(x: .value("Day", point.day, unit: .day))
                    .foregroundStyle(Tone.inkMuted)
                    .lineStyle(StrokeStyle(lineWidth: 0.5))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Callout(text: callout)
                    }
            }
        }
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(Tone.rule)
                // `10M`, not `1.0e7`: the shared figure without its unit.
                AxisValueLabel { Text(axis(value.as(Double.self) ?? 0)) }
            }
        }
        .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
        .chartOverlay { proxy in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(at):
                        let near = nearest(at, proxy)
                        mirror.spendFocus = near?.name
                        mirror.spendPoint = near?.point
                    case .ended:
                        mirror.spendFocus = nil
                        mirror.spendPoint = nil
                    }
                }
        }
        .frame(minHeight: CardMetrics.scaled(Self.chartFloor), idealHeight: CardMetrics.scaled(Self.chartFloor),
               maxHeight: .infinity)
        .font(Type.mono(9))
    }

    private func axis(_ value: Double) -> String {
        guard chart.measure == .tokens else { return "\(Int(value))" }
        return chart.measure.figure(Decimal(value)).replacingOccurrences(of: " tokens", with: "")
    }

    /// The drawn line closest to the pointer, at its point whose day is
    /// drawn nearest the pointer's x.
    private func nearest(_ at: CGPoint, _ proxy: ChartProxy) -> (name: String, point: SpendPoint)? {
        guard let instant: Date = proxy.value(atX: at.x) else { return nil }
        return visible.compactMap { series -> (String, SpendPoint, CGFloat)? in
            guard let point = SpendChart.point(nearest: instant, in: series.points),
                  let y = proxy.position(forY: point.amount.asDouble) else { return nil }
            return (series.key, point, abs(y - at.y))
        }.min { $0.2 < $1.2 }.map { ($0.0, $0.1) }
    }

    /// Every line's name, drawn or not, after a square that reads as its
    /// toggle. A click turns its line off or back on; an off entry is dim,
    /// struck through and its square an empty outline.
    private var legend: some View {
        let dimmed = Set(Self.dimmed(visible, focus: mirror.spendFocus))
        return HStack(spacing: 10) {
            ForEach(chart.series, id: \.key) { series in
                let off = mirror.hiddenLines.contains(series.key)
                let dim = dimmed.contains(series.key)
                HStack(spacing: 4) {
                    Rectangle().fill(off ? .clear : tone(series, dimmed: dim))
                        .overlay { if off { Rectangle().strokeBorder(Tone.inkDim, lineWidth: 1) } }
                        .frame(width: CardMetrics.scaled(7), height: CardMetrics.scaled(7))
                    Text(series.name).strikethrough(off).foregroundStyle(Self.legendTone(off: off, dimmed: dim))
                }
                .contentShape(Rectangle())
                .onTapGesture { try? mirror.toggle(line: series.key) }
                .onHover { inside in
                    if inside, !off { mirror.spendFocus = series.key } else if mirror.spendFocus == series.key { mirror.spendFocus = nil }
                }
            }
        }
        .font(Type.mono(Self.legendSize))
    }

    /// A family's range total, its name at the left and its figure at the
    /// right. Unpriced counts responses, because it has no dollars to show
    /// and hiding it would make the total look whole.
    private func heading(_ total: SpendGroupTotal) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(total.group.uppercased()).font(Type.mono(Self.headingLabelSize)).foregroundStyle(Tone.inkDim)
            Spacer(minLength: 4)
            Text(total.amount.map(chart.measure.figure) ?? "\(total.responses) unpriced")
                .font(Type.mono(Self.headingFigureSize)).foregroundStyle(Tone.ink)
        }
        .lineLimit(1)
    }
}
