import SeatGaugeCore
import SwiftUI

/// One machine as its LOAD card draws it: a meter each for CPU, memory and
/// disk, the room word in the header, and the agents under the meters.
struct MachineCard: Equatable, Identifiable {
    struct Line: Equatable, Identifiable {
        let name: String
        let used: Int
        /// The column a seat card gives its countdown: the load average,
        /// the memory size, the disk space left.
        let detail: String
        var id: String { name }
        var tone: MeterTone { .of(usedPercent: used) }
    }

    let id: String
    let label: String
    let room: Room?
    let lines: [Line]
    let note: String
    let dimmed: Bool

    /// CPU and memory are the 30-second averages, with an arrow when they
    /// are rising or falling; the hover chart has the second-by-second.
    static func make(_ machine: Machine, state: MachineState?, samples: [LoadSample] = [], now: Date) -> MachineCard {
        let reading = state?.reading
        let summary = reading.map { MachineSummary(reading: $0, samples: samples, now: now) }
        let lines = reading.flatMap { reading in summary.map { summary in
            [Line(name: "CPU", used: summary.cpu,
                  detail: arrow(summary.cpuTrend) + "load \(Int((reading.load.first ?? 0).rounded()))/\(reading.cores)"),
             Line(name: "RAM", used: summary.ram,
                  detail: arrow(summary.ramTrend) + "of \(gigabytes(reading.ramBytes, binary: true))"),
             Line(name: "DISK", used: reading.diskUsed, detail: "\(gigabytes(reading.diskFreeBytes)) left")]
        } } ?? []
        let note: String
        switch state {
        case .none:
            note = "reading…"
        case let .live(reading):
            note = agents(reading.agents)
        case let .unreachable(reason, last):
            note = last.map { "unreachable, read \(Countdown.text(until: now, now: $0.takenAt)) ago" } ?? reason
        }
        let live: Bool = if case .live = state { true } else { false }
        return MachineCard(id: machine.id, label: machine.label, room: live ? summary?.room : nil,
                           lines: lines, note: note, dimmed: state != nil && !live)
    }

    static func arrow(_ trend: Trend?) -> String {
        switch trend {
        case .rising: "↑ "
        case .falling: "↓ "
        case .steady, .none: ""
        }
    }

    /// What herdr says the agents are doing. Blocked ones come first, since
    /// they are waiting on a person.
    static func agents(_ count: AgentCount?) -> String {
        guard let count else { return "no herdr agents found" }
        guard count.total > 0 else { return "no agents" }
        return ([count.blocked > 0 ? "\(count.blocked) blocked" : nil,
                 "\(count.working) working", "\(count.idle) idle"] as [String?])
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Whole gigabytes: memory in the binary ones macOS sells it in, disk in
    /// the decimal ones Finder counts it in.
    static func gigabytes(_ bytes: Int64, binary: Bool = false) -> String {
        "\(Int((Double(bytes) / (binary ? 1_073_741_824 : 1e9)).rounded()))G"
    }
}

extension Room {
    var word: String { rawValue.uppercased() }

    var color: Color {
        switch self {
        case .free: Tone.success
        case .busy: Tone.warning
        case .full: Tone.danger
        }
    }
}

/// The LOAD tab: one card per machine in `seats.json` order, in the seat
/// cards' boxes and columns.
struct LoadTab: View {
    var mirror = GaugeMirror.shared

    var body: some View {
        let cards = mirror.machines.map {
            MachineCard.make($0, state: mirror.machineStates[$0.id], samples: mirror.machineHistory[$0.id] ?? [], now: Date())
        }
        // As the seat row does: the cards fill the width while they fit, and
        // scroll sideways at their minimum when they do not.
        ViewThatFits(in: .horizontal) {
            row(cards).frame(idealWidth: PanelLayout.minimumContentWidth(cards: cards.count))
            CardScroller(ids: cards.map(\.id)) { row(cards) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ cards: [MachineCard]) -> some View {
        CardRow {
            ForEach(cards) { MachineCardView(card: $0, history: mirror.machineHistory[$0.id] ?? []).id($0.id) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The glance face, and on hover the chart over it at the same size, so a
/// hover never moves the card.
struct MachineCardView: View {
    let card: MachineCard
    var history: [LoadSample] = []
    @State private var hovering = false

    var body: some View {
        glance
            .opacity(hovering ? 0 : 1)
            .overlay(alignment: .top) {
                if hovering {
                    VStack(alignment: .leading, spacing: CardMetrics.rowSpacing) {
                        header(legend: true)
                        LoadChart(samples: history, now: Date())
                    }
                }
            }
            .animation(.easeInOut(duration: CardDetailMetrics.fade), value: hovering)
            .modifier(CardBox())
            .opacity(card.dimmed ? 0.6 : 1)
            .onHover { hovering = $0 }
    }

    private func header(legend: Bool) -> some View {
        HStack(spacing: CardMetrics.headerSpacing) {
                Text(card.label.uppercased())
                    .font(Type.display(CardMetrics.Header.provider))
                    .tracking(CardMetrics.scaled(CardMetrics.Header.providerTracking))
                    .foregroundStyle(Tone.ink)
                    .lineLimit(1)
                Spacer(minLength: CardMetrics.Header.spacer)
                if legend {
                    Text("CPU \(card.lines.first?.used ?? 0)%").foregroundStyle(LoadChart.cpuColor)
                    Text("RAM \(card.lines.dropFirst().first?.used ?? 0)%").foregroundStyle(LoadChart.ramColor)
                    Text("10 MIN").foregroundStyle(Tone.inkDim)
                } else if let room = card.room {
                    Text(room.word)
                        .foregroundStyle(room.color)
                }
            }
            .font(Type.mono(CardMetrics.Header.pickSize))
            .tracking(CardMetrics.Header.pickTracking)
            .frame(minHeight: SeatMark.side(TextScale.current))
    }

    private var glance: some View {
        VStack(alignment: .leading, spacing: CardMetrics.rowSpacing) {
            header(legend: false)
            ForEach(card.lines) { line in
                CardLine {
                    Label(text: line.name, size: CardMetrics.Glance.label)
                        .frame(width: CardMetrics.nameWidth, alignment: .leading)
                    Meter(fill: Double(line.used) / 100, color: line.tone.color)
                    Text(line.detail)
                        .font(Type.mono(CardMetrics.Glance.label)).foregroundStyle(Tone.inkMuted)
                        .fixedSize()
                        .modifier(RowGap())
                        .frame(minWidth: CardMetrics.countdownWidth, alignment: .trailing)
                    Text("\(line.used)%")
                        .font(Type.mono(CardMetrics.Glance.percent)).foregroundStyle(Tone.inkMuted)
                        .tracking(CardMetrics.digitTracking)
                        .fixedSize()
                        .frame(minWidth: CardMetrics.percentWidth, alignment: .trailing)
                }
            }
            Text(card.note)
                .font(Type.mono(CardMetrics.Glance.note))
                .foregroundStyle(Tone.inkDim)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// CPU and memory over the last ten minutes, 0 to 100 percent, newest at
/// the right edge. A gap in the reads draws as a straight line across it.
struct LoadChart: View {
    let samples: [LoadSample]
    let now: Date

    static var cpuColor: Color { Tone.current.accent }
    static var ramColor: Color { Tone.ink }

    var body: some View {
        GeometryReader { space in
            let size = space.size
            ZStack {
                ForEach([25, 50, 75], id: \.self) { line in
                    Path { path in
                        let y = size.height * (1 - Double(line) / 100)
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    .stroke(Tone.meterTrack.opacity(0.6), lineWidth: 1)
                }
                trace(\.ram, in: size).stroke(Self.ramColor, lineWidth: 1)
                trace(\.cpu, in: size).stroke(Self.cpuColor, lineWidth: 1.5)
            }
        }
        .frame(minHeight: 20, maxHeight: .infinity)
        .accessibilityLabel("CPU and memory over the last ten minutes")
    }

    private func trace(_ value: KeyPath<LoadSample, Int>, in size: CGSize) -> Path {
        Path { path in
            for (index, sample) in samples.enumerated() {
                let age = now.timeIntervalSince(sample.at)
                let point = CGPoint(x: size.width * max(0, 1 - age / LoadSample.span),
                                    y: size.height * (1 - Double(sample[keyPath: value]) / 100))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }
}
