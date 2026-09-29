import AppKit
import SeatGaugeCore
import SwiftUI

/// What the title bar's one line says: the problem that outranks the others,
/// in the warning tone, or when the numbers were read, dim.
struct TitleStatus: Equatable {
    let text: String
    let isProblem: Bool

    /// `problems` in rank order: config, spend record, attribution
    /// record, time zone. The first one present takes the slot; the right
    /// click menu lists them all.
    static func of(updated: String, problems: [String]) -> TitleStatus {
        problems.first.map { TitleStatus(text: $0, isProblem: true) } ?? TitleStatus(text: updated, isProblem: false)
    }
}

/// The title bar's sizes and widths, written at the ordinary text size. Its
/// text follows the user's size up to step 4 and holds there, so the row
/// always fits the system's title bar.
enum TitleBarMetrics {
    static let title = "SEAT GAUGE"
    static let titleSize: CGFloat = 12
    /// The title's letter spacing, at the title bar's scale.
    static let titleTracking: CGFloat = 1.5
    static let textSize: CGFloat = 10
    static let topStep = 4
    static let gap: CGFloat = 10
    /// A status narrower than this says nothing, so it hides instead.
    static let statusFloor: CGFloat = 40

    static var scale: TextScale { TextScale(step: min(TextScale.current.step, topStep)) }

    /// The title's cap height, which the app icon beside it is drawn at.
    static var capHeight: CGFloat {
        let size = points(titleSize)
        let face = FontManifest.familyName("Funnel Display", registered: Type.registered).flatMap {
            NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: size)
        } ?? .systemFont(ofSize: size)
        return face.capHeight.rounded()
    }

    /// A written size, drawn at the title bar's scale.
    static func points(_ base: CGFloat) -> CGFloat { CGFloat(scale.scaled(Double(base))) }

    /// The trailing accessory's width and whether it shows the status: the
    /// controls never give, the status truncates to what is left, and under
    /// the floor it goes.
    static func trail(available: CGFloat, controls: CGFloat, status: CGFloat) -> (width: CGFloat, showsStatus: Bool) {
        let left = available.isFinite ? available - controls - gap : 0
        guard left >= statusFloor, status > 0 else { return (controls, false) }
        return (min(status, left) + gap + controls, true)
    }

    /// Whether the title has room between the traffic lights and the
    /// controls, with the gaps between and after them.
    static func showsTitle(width: CGFloat, buttons: CGFloat, title: CGFloat, controls: CGFloat) -> Bool {
        width >= buttons + gap + title + gap * 2 + controls + gap
    }

    /// The narrowest the row can be: the traffic lights, a gap and the
    /// controls, which carry their own trailing padding. The title gives way,
    /// as the status does, so the window can narrow to one card.
    static func minimumWidth(buttons: CGFloat, controls: CGFloat) -> CGFloat {
        buttons + gap + controls
    }

    /// The traffic lights' trailing edge, or where it usually is when the
    /// window has no zoom button to read.
    static func buttonsEdge(zoom: CGRect?) -> CGFloat { zoom?.maxX ?? 68 }
}

extension Type {
    /// The mono face at the title bar's scale rather than the panel's.
    static func titleMono(_ size: CGFloat) -> Font {
        mono(size * CGFloat(TitleBarMetrics.scale.factor / TextScale.current.factor))
    }

    static func titleDisplay(_ size: CGFloat) -> Font {
        display(size * CGFloat(TitleBarMetrics.scale.factor / TextScale.current.factor), weight: .semibold)
    }
}

/// The title, at the title bar's leading edge, when the window has room.
struct TitleLead: View {
    var mirror = GaugeMirror.shared

    var body: some View {
        if mirror.titleShown {
            TitleText().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

struct StatusText: View {
    let status: TitleStatus

    var body: some View {
        Text(status.text).font(Type.titleMono(TitleBarMetrics.textSize))
            .foregroundStyle(status.isProblem ? Tone.warning : Tone.inkDim)
    }
}

/// The app icon's gauge, then the title. The gauge is as tall as the
/// title's capitals, a point above the baseline so it sits optically
/// centred on them.
struct TitleText: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: TitleBarMetrics.points(4).rounded()) {
            GaugeMark(height: TitleBarMetrics.capHeight).offset(y: -1).accessibilityHidden(true)
            Text(TitleBarMetrics.title).font(Type.titleDisplay(TitleBarMetrics.titleSize))
                .tracking(TitleBarMetrics.points(TitleBarMetrics.titleTracking))
                .foregroundStyle(Tone.ink)
        }
        .fixedSize()
    }
}

/// The gauge from the app icon without its tile, drawn from the geometry in
/// `scripts/make-icon.swift`: the track, the reading and the needle on the
/// icon's 1024 point canvas, y up, in the panel's tones so it reads on either
/// ground.
struct GaugeMark: View {
    let height: CGFloat

    /// The drawing's bounds on that canvas: the arc's outer edge and round
    /// caps, which take in the needle and the hub.
    static let bounds = CGRect(x: 210, y: 303, width: 604, height: 469)
    static let centre = CGPoint(x: 512, y: 470)
    static let radius: CGFloat = 270
    static let start: CGFloat = 210, end: CGFloat = -30, reading: CGFloat = 66

    var body: some View {
        let scale = height / Self.bounds.height
        let tones = (track: Tone.inkDim, reading: Tone.accent, needle: Tone.ink, ground: Tone.bg)
        Canvas { context, _ in
            func polar(_ degrees: CGFloat, _ length: CGFloat) -> CGPoint {
                let angle = degrees * .pi / 180
                return CGPoint(x: (Self.centre.x + cos(angle) * length - Self.bounds.minX) * scale,
                               y: (Self.bounds.maxY - Self.centre.y - sin(angle) * length) * scale)
            }
            func arc(to end: CGFloat) -> Path {
                Path { path in
                    path.move(to: polar(Self.start, Self.radius))
                    for step in 1...48 {
                        path.addLine(to: polar(Self.start + (end - Self.start) * CGFloat(step) / 48, Self.radius))
                    }
                }
            }
            func dot(_ radius: CGFloat) -> Path {
                let hub = polar(0, 0)
                return Path(ellipseIn: CGRect(x: hub.x - radius * scale, y: hub.y - radius * scale,
                                              width: radius * 2 * scale, height: radius * 2 * scale))
            }
            let band = StrokeStyle(lineWidth: 64 * scale, lineCap: .round, lineJoin: .round)
            context.stroke(arc(to: Self.end), with: .color(tones.track), style: band)
            context.stroke(arc(to: Self.reading), with: .color(tones.reading), style: band)
            context.stroke(Path { $0.move(to: polar(0, 0)); $0.addLine(to: polar(Self.reading, 210)) },
                           with: .color(tones.needle), style: StrokeStyle(lineWidth: 30 * scale, lineCap: .round))
            context.fill(dot(48), with: .color(tones.needle))
            context.fill(dot(18), with: .color(tones.ground))
        }
        .frame(width: (Self.bounds.width * scale).rounded(), height: height)
    }
}

/// The synced line and the controls, at the trailing edge. The status takes
/// what the window leaves and truncates; the controls never give.
struct TitleTrail: View {
    var mirror = GaugeMirror.shared

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: PanelClock.nextMinute(after: Date()), by: 60)) { tick in
            HStack(spacing: TitleBarMetrics.gap) {
                if mirror.statusShown {
                    StatusText(status: TitleStatus.of(updated: mirror.model(at: tick.date).updated,
                                                      problems: mirror.problems))
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                TitleControls()
            }
        }
    }
}

/// Sync all and the tab words: the only things in the title bar that take a
/// click. Appearance is switched from Settings and the right-click menu.
struct TitleControls: View {
    var mirror = GaugeMirror.shared

    var body: some View {
        HStack(spacing: TitleBarMetrics.gap) {
            SyncButton(busy: !mirror.syncing.isEmpty, label: "Sync all",
                       side: TitleBarMetrics.points(TitleBarMetrics.textSize)) { mirror.syncAll() }
            ForEach(Tab.allCases, id: \.title) { one in
                if one != Tab.allCases.first { Text("·").foregroundStyle(Tone.inkDim) }
                Text(one.title)
                    .foregroundStyle(one == mirror.tab ? Tone.ink : Tone.inkDim)
                    .onTapGesture { mirror.tab = one }
            }
        }
        .font(Type.titleMono(TitleBarMetrics.textSize))
        .fixedSize()
        .padding(.trailing, TitleBarMetrics.gap)
        .frame(maxHeight: .infinity)
    }
}

/// What a click on the title bar's text does: one click drags the window, two
/// do what the user set for a double click in System Settings.
enum TitleBarClick: Equatable {
    case drag, zoom, minimise, nothing

    static func action(clickCount: Int, setting: String?) -> TitleBarClick {
        guard clickCount == 2 else { return .drag }
        switch setting {
        case "Minimize": return .minimise
        case "None": return .nothing
        default: return .zoom
        }
    }
}

/// A title bar accessory's host. Its text moves the window as the bar
/// around it does; the controls' host lets SwiftUI take the clicks.
final class TitleBarHost: NSHostingView<AnyView> {
    var passesClicks = false

    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if passesClicks { return super.mouseDown(with: event) }
        switch TitleBarClick.action(clickCount: event.clickCount,
                                    setting: UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")) {
        case .drag: window?.performDrag(with: event)
        case .zoom: window?.zoom(nil)
        case .minimise: window?.miniaturize(nil)
        case .nothing: break
        }
    }
}

extension WindowController {
    /// The row in the title bar: the title after the traffic lights, the
    /// synced line and the controls at the far end, the system's own title
    /// hidden.
    func installTitleBar() {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        for (root, side, clicks) in [(AnyView(TitleLead()), NSLayoutConstraint.Attribute.left, false),
                                     (AnyView(TitleTrail()), .right, true)] {
            let host = TitleBarHost(rootView: root)
            host.sizingOptions = []
            host.passesClicks = clicks
            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = host
            accessory.layoutAttribute = side
            window.addTitlebarAccessoryViewController(accessory)
        }
        layoutTitleBar()
    }

    /// A view's width at its ideal size. Widths only: the height rule reads
    /// the content through `ContentMeasuring` alone.
    static func width<V: View>(of view: V) -> CGFloat {
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: CGFloat.infinity, height: .infinity)).width
    }

    var titleBarHosts: [TitleBarHost] {
        window.titlebarAccessoryViewControllers.compactMap { $0.view as? TitleBarHost }
    }

    /// The title bar's height, as the window reports it.
    var chrome: CGFloat { max(0, window.frame.height - window.contentLayoutRect.height) }

    var buttonsEdge: CGFloat { TitleBarMetrics.buttonsEdge(zoom: window.standardWindowButton(.zoomButton)?.frame) }

    /// Widths for the two accessories at the window's width, and the row's
    /// minimum handed to the content so the window is never narrower.
    func layoutTitleBar() {
        let hosts = titleBarHosts
        guard hosts.count == 2 else { return }
        let height = max(chrome, 1)
        let controls = Self.width(of: TitleControls())
        let mirror = GaugeMirror.shared
        let full = Self.width(of: TitleText())
        let shows = TitleBarMetrics.showsTitle(width: window.frame.width, buttons: buttonsEdge, title: full,
                                               controls: controls)
        if mirror.titleShown != shows { mirror.titleShown = shows }
        let title = shows ? full : 0
        if hosts[0].frame.width != title { hosts[0].setFrameSize(NSSize(width: title, height: height)) }
        let said = TitleStatus.of(updated: mirror.model(at: Date()).updated, problems: mirror.problems)
        let status = Self.width(of: StatusText(status: said).fixedSize())
        let available = window.frame.width - buttonsEdge - TitleBarMetrics.gap * 2 - title
        let trail = TitleBarMetrics.trail(available: available, controls: controls, status: status)
        if mirror.statusShown != trail.showsStatus { mirror.statusShown = trail.showsStatus }
        if hosts[1].frame.width != trail.width { hosts[1].setFrameSize(NSSize(width: trail.width, height: height)) }
        let minimum = TitleBarMetrics.minimumWidth(buttons: buttonsEdge, controls: controls)
        if GaugeMirror.shared.chromeMinimum != minimum { GaugeMirror.shared.chromeMinimum = minimum }
    }
}
