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

    static func make(_ machine: Machine, state: MachineState?, now: Date) -> MachineCard {
        let reading = state?.reading
        let lines = reading.map { reading in
            [Line(name: "CPU", used: reading.cpuUsed,
                  detail: "load \(Int((reading.load.first ?? 0).rounded()))"),
             Line(name: "RAM", used: reading.ramUsed, detail: "of \(gigabytes(reading.ramBytes, binary: true))"),
             Line(name: "DISK", used: reading.diskUsed, detail: "\(gigabytes(reading.diskFreeBytes)) left")]
        } ?? []
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
        return MachineCard(id: machine.id, label: machine.label, room: live ? reading?.room : nil,
                           lines: lines, note: note, dimmed: state != nil && !live)
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
        let cards = mirror.machines.map { MachineCard.make($0, state: mirror.machineStates[$0.id], now: Date()) }
        CardRow {
            ForEach(cards) { MachineCardView(card: $0) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct MachineCardView: View {
    let card: MachineCard

    var body: some View {
        VStack(alignment: .leading, spacing: CardMetrics.rowSpacing) {
            HStack(spacing: CardMetrics.headerSpacing) {
                Text(card.label.uppercased())
                    .font(Type.display(CardMetrics.Header.provider))
                    .tracking(CardMetrics.scaled(CardMetrics.Header.providerTracking))
                    .foregroundStyle(Tone.ink)
                    .lineLimit(1)
                Spacer(minLength: CardMetrics.Header.spacer)
                if let room = card.room {
                    Text(room.word)
                        .font(Type.mono(CardMetrics.Header.pickSize))
                        .tracking(CardMetrics.Header.pickTracking)
                        .foregroundStyle(room.color)
                }
            }
            .frame(minHeight: SeatMark.side(TextScale.current))
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
        .modifier(CardBox())
        .opacity(card.dimmed ? 0.6 : 1)
    }
}
