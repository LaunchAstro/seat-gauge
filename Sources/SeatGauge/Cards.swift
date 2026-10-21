import SeatGaugeCore
import SwiftUI

/// The combo layout over `PanelModel`: cards side by side, each in its own box on one ground,
/// one tight line per window. A seat's glance face carries no pace line; its
/// verdict is on the detail face. The ALL card draws its own while hovered.

struct Meter: View {
    let fill: Double
    let color: Color
    @Environment(\.pinnedVerticalFactor) private var pinned

    init(line: WindowLine) { self.init(fill: line.fill, color: line.tone.color) }

    init(fill: Double, color: Color) {
        self.fill = fill
        self.color = color
    }

    var body: some View {
        // The user's extra height draws a thicker meter.
        let factor = pinned ?? VerticalFit.current
        let height = VerticalFit.meterHeight(factor)
        GeometryReader { space in
            ZStack(alignment: .leading) {
                Rectangle().fill(Tone.meterTrack)
                Rectangle().fill(color)
                    .frame(width: space.size.width * fill)
            }
        }
        // The meter is the one column that stretches, and the floor under it
        // is what keeps a narrow window readable.
        .frame(minWidth: CardMetrics.minimumMeter, minHeight: height, maxHeight: height)
    }
}

/// The user's extra height as space between window lines, on the countdown,
/// the tallest thing on a line, so all of it moves the next line down.
struct RowGap: ViewModifier {
    @Environment(\.pinnedVerticalFactor) private var pinned

    func body(content: Content) -> some View {
        content.padding(.vertical, VerticalFit.rowGap(pinned ?? VerticalFit.current) / 2)
    }
}

struct Label: View {
    let text: String
    var color: Color = Tone.inkMuted
    var size: CGFloat = 10

    var body: some View {
        Text(text.uppercased())
            .font(Type.mono(size))
            .tracking(0.3)
            .foregroundStyle(color)
    }
}

/// A card: both faces in one box, the one not shown at no opacity. The
/// detail face fills the glance face's height and asks for no more than its
/// floor, so the glance face sets the card and a hover never moves it.
struct CardView: View {
    let card: CardModel
    var detail: CardDetail?
    var face = CardFace.glance

    var body: some View {
        ZStack(alignment: .top) {
            Self.glance(card).opacity(face == .glance ? 1 : 0)
            DetailFace(card: card, detail: detail ?? CardDetail.make(card: card, history: nil, selected: nil))
                .opacity(face == .detail ? 1 : 0)
        }
        .animation(.easeInOut(duration: CardDetailMetrics.fade), value: face)
        // Dropped on another card, a card takes its place.
        .draggable(card.id.rawValue)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            GaugeMirror.shared.move(SeatID(rawValue: id), to: card.id)
            return true
        }
        .modifier(CardBox())
        .opacity(card.isDimmed ? 0.6 : 1)
        .onHover { inside in
            let mirror = GaugeMirror.shared
            if inside { mirror.hover(card.id) } else if mirror.hovered == card.id { mirror.hover(nil) }
        }
    }

    /// The glance face: the header, one line per window and a stale card's
    /// age, one even gap apart, and the subscription date on the card's
    /// floor, so every card's date sits on one line across the row. The pace
    /// line is the detail face's.
    static func glance(_ card: CardModel) -> some View {
        VStack(alignment: .leading, spacing: CardMetrics.rowSpacing) {
            CardHeader(card: card)
            ForEach(card.lines) { line in lineView(line) }
            if let note = card.stale ?? card.dated {
                HStack(spacing: CardMetrics.headerSpacing) {
                    Text(note).font(Type.mono(CardMetrics.Glance.note)).foregroundStyle(Tone.inkDim)
                    if card.signsIn {
                        Spacer(minLength: 0)
                        SignInButton(card: card)
                    }
                }
            }
            if let billing = card.billing {
                Spacer(minLength: 0)
                Text(billing.text).font(Type.mono(CardMetrics.Glance.note)).foregroundStyle(billing.tone.color)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// One window line, as every glance face and the ALL card draw it. A
    /// run-out countdown reads in the warning tone.
    static func lineView(_ line: WindowLine) -> some View {
        CardLine {
            Label(text: line.name, size: CardMetrics.Glance.label)
                .frame(width: CardMetrics.nameWidth, alignment: .leading)
            Meter(line: line)
            // Fixed size first, so a long countdown takes the room it
            // needs instead of being truncated at a wide window.
            Text(line.countdown)
                .font(Type.display(CardMetrics.Glance.countdown)).monospacedDigit()
                .tracking(CardMetrics.digitTracking)
                .foregroundStyle(line.runsOut ? Tone.warning : Tone.ink)
                .fixedSize()
                .modifier(RowGap())
                .frame(minWidth: CardMetrics.countdownWidth, alignment: .trailing)
                .accessibilityLabel(line.runsOut ? "runs out in \(line.countdown)" : "resets in \(line.countdown)")
            Text("\(line.usedPercent)%")
                .font(Type.mono(CardMetrics.Glance.percent)).foregroundStyle(Tone.inkMuted)
                .tracking(CardMetrics.digitTracking)
                .fixedSize()
                .frame(minWidth: CardMetrics.percentWidth, alignment: .trailing)
        }
    }
}

/// The ALL card: its mark and label, the seat cards' lines and, while the
/// pointer is over it, the weekly verdict in its tone under them, in a
/// lighter box. The header is as tall as a seat card's so the lines sit level
/// across the row. The verdict's row is always laid out, so a hover never
/// moves the card.
struct SummaryCard: View {
    let summary: SummaryModel
    @State private var hovering = false

    var body: some View {
        Self.face(summary, showsPace: hovering)
            .animation(.easeInOut(duration: CardDetailMetrics.fade), value: hovering)
            .onHover { hovering = $0 }
    }

    static func face(_ summary: SummaryModel, showsPace: Bool) -> some View {
        VStack(alignment: .leading, spacing: CardMetrics.rowSpacing) {
            HStack(spacing: CardMetrics.headerSpacing) {
                SummaryMarkView()
                Text(SummaryModel.label)
                    .font(Type.display(CardMetrics.Header.provider))
                    .tracking(CardMetrics.scaled(CardMetrics.Header.providerTracking))
                    .foregroundStyle(Tone.ink)
            }
            .frame(minHeight: SeatMark.side(TextScale.current))
            ForEach(summary.lines) { line in CardView.lineView(line) }
            if let pace = summary.pace {
                Text(pace.text)
                    .font(Type.mono(CardMetrics.Glance.note))
                    .foregroundStyle(pace.tone.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .opacity(showsPace ? 1 : 0)
                    .accessibilityHidden(!showsPace)
            }
        }
        .modifier(CardBox(fill: Tone.summaryBox))
    }
}

struct GlanceFace: View {
    let card: CardModel
    var body: some View { CardView.glance(card) }
}

/// A card's header, provider first and the seat after it, then the pick, the
/// plan and the sync icon at the far end. Short of room, the plan gives way
/// before the seat. `CardMetrics.headerWidth` is its width, box
/// included. On the detail face the seat reads as its account.
struct CardHeader: View {
    let card: CardModel
    var face = CardFace.glance

    var body: some View {
        HStack(spacing: CardMetrics.headerSpacing) {
            // Provider first, seat second: the mark when there is one, the
            // provider in the display face, the seat in the smaller muted Label face. The
            // provider never truncates; an overlong seat name does.
            HStack(spacing: CardMetrics.headerSpacing) {
                SeatMarkView(provider: card.mark)
                HStack(alignment: .firstTextBaseline, spacing: CardMetrics.headerSpacing) {
                    Text(card.provider.uppercased())
                        .font(Type.display(CardMetrics.Header.provider))
                        .tracking(CardMetrics.scaled(CardMetrics.Header.providerTracking))
                        .foregroundStyle(Tone.ink)
                        .fixedSize()
                    Text(card.seat(on: face))
                        .font(Type.mono(CardMetrics.Header.seat))
                        .tracking(CardMetrics.scaled(CardMetrics.Header.seatTracking))
                        .foregroundStyle(Tone.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(card.opens ? card.openLabel : card.heading)
            .modifier(OpensSeat(card: card))
            // Laid out first, so a narrow card cuts the plan before the seat.
            .layoutPriority(1)
            Spacer(minLength: CardMetrics.Header.spacer)
            if card.isBest {
                Text(CardMetrics.Header.pick)
                    .font(Type.mono(CardMetrics.Header.pickSize))
                    .tracking(CardMetrics.Header.pickTracking)
                    .foregroundStyle(Tone.ink)
                    .fixedSize()
            }
            if let plan = card.plan {
                Text(plan)
                    .font(Type.mono(CardMetrics.Header.plan))
                    .tracking(CardMetrics.scaled(CardMetrics.Header.seatTracking))
                    .foregroundStyle(Tone.inkDim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            SyncButton(busy: card.isSyncing, label: "Sync \(card.heading)") { GaugeMirror.shared.sync(card.id) }
        }
    }
}

/// Sign in, on the stale line of a card whose seat says it is not logged
/// in, waiting while one runs.
struct SignInButton: View {
    let card: CardModel

    var body: some View {
        let busy = GaugeMirror.shared.signingIn.contains(card.id)
        Button(busy ? "Signing in" : "Sign in") { GaugeMirror.shared.signIn(card.id) }
            .buttonStyle(.plain)
            .font(Type.mono(CardMetrics.Glance.note))
            .foregroundStyle(Tone.ink)
            .fixedSize()
            .disabled(busy)
            .accessibilityLabel("Sign in \(card.heading)")
    }
}

/// The header's mark and name as the way to open the seat, when it has an
/// `open` command: a pointing hand over them, a click that runs it, and a
/// button VoiceOver can press. A tap rather than a `Button`, so a drag that
/// starts on the name still moves the card. The cursor is set on every move
/// rather than pushed, so a face that fades out mid hover leaves no stack.
struct OpensSeat: ViewModifier {
    let card: CardModel

    func body(content: Content) -> some View {
        if card.opens {
            content
                .contentShape(Rectangle())
                .onTapGesture { GaugeMirror.shared.open(card.id) }
                .onContinuousHover { phase in
                    if case .active = phase { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { GaugeMirror.shared.open(card.id) }
        } else {
            content
        }
    }
}

/// The sync icon, at the favicon's size so the header reads as one row, or a
/// spinner in its place while the seat is being read.
struct SyncButton: View {
    let busy: Bool
    let label: String
    var side = SeatMark.side(TextScale.current)
    /// The cards' icons are dim; the title bar's is a step lighter.
    var tone: Color?
    let action: () -> Void

    static let symbol = "arrow.triangle.2.circlepath"

    var body: some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView().controlSize(.mini).scaleEffect(side / 16)
                } else {
                    Image(systemName: Self.symbol).resizable().scaledToFit().foregroundStyle(tone ?? Tone.inkDim)
                }
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(label)
    }
}

/// Every card's box: square corners, one padding, one tint from `Tone` and ground
/// round it, so twenty seats read as twenty panes and the best is told only by
/// its pick.
struct CardBox: ViewModifier {
    var fill = Tone.box
    @Environment(\.pinnedVerticalFactor) private var pinned

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, CardMetrics.horizontalPadding)
            .padding(.vertical, VerticalFit.boxPadding(pinned ?? VerticalFit.current))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Rectangle().fill(fill))
            .padding(PanelLayout.boxInset)
            .frame(minWidth: CardMetrics.minimumWidth, maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The seat cards in rows: as many as the user's height asks for, and more
/// when the window is too narrow for a row of them at their minimum.
struct ComboLayout: View {
    let cards: [CardModel]
    var summary: SummaryModel?
    var details: [SeatID: CardDetail] = [:]
    var hovered: SeatID?
    @Environment(\.pinnedCardRows) private var pinned
    @Environment(\.pinnedPanelWidth) private var pinnedWidth

    var body: some View {
        CardGrid(rows: pinned ?? VerticalFit.rows, width: pinnedWidth) {
            if let summary { SummaryCard(summary: summary).id(SummaryModel.label) }
            ForEach(cards) { card in
                CardView(card: card, detail: details[card.id], face: card.id == hovered ? .detail : .glance)
                    .id(card.id)
            }
        }
    }
}
