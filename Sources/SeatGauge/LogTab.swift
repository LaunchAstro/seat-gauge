import SeatGaugeCore
import SwiftUI

struct LogTab: View {
    let log: SessionLogFile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if log.sessions.isEmpty {
                Text("Waiting for session observations").font(Type.display(12))
            }
            ForEach(log.problems.keys.sorted(), id: \.self) { machine in
                Text("\(machine): \(log.problems[machine] ?? "unreachable")")
                    .font(Type.mono(9)).foregroundStyle(Tone.inkMuted)
            }
            // SwiftUI's own scroll view, so the stack is lazy and lays out
            // the rows in sight: in AppKit's, every session was laid out on
            // every update, and a text size change left them where they were.
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(log.sessions) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(row.machine) · \(row.workspace) · \(row.pane)")
                                    .font(Type.display(11))
                                Text(row.status.uppercased()).font(Type.mono(9))
                                if row.stale || Date().timeIntervalSince(row.asOf) > 90 {
                                    Text("STALE").font(Type.mono(9)).foregroundStyle(Tone.warning)
                                }
                            }.fixedSize(horizontal: false, vertical: true)
                            Text([row.tool, row.model, row.effort, row.branch].compactMap { $0 }.joined(separator: " · "))
                                .font(Type.mono(10))
                            Text("\(row.repo ?? "unlabelled repo") · \(row.section ?? "no section") · \(row.seat ?? "no seat")")
                                .font(Type.mono(9)).foregroundStyle(Tone.inkMuted)
                            Text(tokenLine(row)).font(Type.mono(10))
                            Text(times(row)).font(Type.mono(9)).foregroundStyle(Tone.inkMuted)
                        }
                        .accessibilityElement(children: .combine)
                        Divider()
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func tokenLine(_ row: SessionRow) -> String {
        guard let tokens = row.tokens else { return "Tokens pending" }
        let total = tokens.input + tokens.output + tokens.cacheRead + tokens.cacheWrite5m + tokens.cacheWrite1h
        let price = row.usd.map { " · $\($0.formatted(.number.precision(.fractionLength(2)))) list price" } ?? ""
        return "\(total.formatted()) tokens · \(tokens.input.formatted()) in · \(tokens.output.formatted()) out" + price
    }

    private func times(_ row: SessionRow) -> String {
        let format = Date.FormatStyle(date: .abbreviated, time: .shortened)
        let start = row.startedAt.map { $0.formatted(format) } ?? "not observed working"
        let close = row.closedAt.map { " · closed \($0.formatted(format))" } ?? ""
        return "Start \(start)\(close) · as of \(row.asOf.formatted(date: .omitted, time: .shortened))"
    }
}
