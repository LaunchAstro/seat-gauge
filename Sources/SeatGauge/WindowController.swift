import AppKit
import SwiftUI

/// The app's one window: an ordinary application window at the ordinary
/// level, with a title bar and a close button.
/// AppKit constrains a window to the screen it believes it is on when the
/// window is ordered front, and on a Mac with three displays that drags the
/// window to whichever display is active at the time. The controller decides
/// the frame, and refuses one that is off screen, so this window keeps what it
/// is given.
final class FramePreservingWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// The content has a widest sensible size; the window does not. AppKit
    /// reads this one when a drag is tracked, so widening it here is what lets
    /// the window be pulled across a display, while the content
    /// maximum beside it still describes the content.
    override var maxSize: NSSize {
        get { NSSize(width: .greatestFiniteMagnitude,
                     height: max(super.maxSize.height, frameHeight(contentHeights?.upperBound) ?? 0)) }
        set { super.maxSize = newValue }
    }

    /// The content heights the user can drag between. It
    /// only ever widens the content lock, so a stale range never holds the
    /// window under its cards.
    var contentHeights: ClosedRange<CGFloat>?

    override var minSize: NSSize {
        get { NSSize(width: super.minSize.width,
                     height: min(super.minSize.height,
                                 frameHeight(contentHeights?.lowerBound) ?? .greatestFiniteMagnitude)) }
        set { super.minSize = newValue }
    }

    /// A content height below the title bar, as a frame height: the content
    /// runs under the title bar, so the bar is added back.
    private func frameHeight(_ content: CGFloat?) -> CGFloat? {
        content.map { $0 + frame.height - contentLayoutRect.height }
    }

    /// AppKit answers `canBecomeMain` false for a window that is not on screen
    /// yet, which is a fact about the moment rather than about the window.
    /// This one is titled, closable and ordinary, so it is main whenever it is
    /// the front window.
    override var canBecomeMain: Bool { true }
    override var canBecomeKey: Bool { true }
}

/// The window follows its content. `NSHostingView` keeps the window's content
/// minimum and maximum at the SwiftUI content's size, but AppKit only reads
/// those on a user resize, so a window that came up on a saved frame, or whose
/// cards arrived after the empty state, stays at whatever height it had. That
/// leaves a strip of dead space under the cards.
/// The top edge is the one that stays put, so the window grows and shrinks
/// downwards rather than jumping.
/// The root is erased rather than carried as a type parameter: the release
/// optimiser crashes on a generic `NSHostingView` subclass, and there is one
/// root view in this app.
final class ContentSizedHostingView: NSHostingView<AnyView> {
    /// The controller that turns a dragged height into a factor.
    weak var fitter: WindowController?

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        fitter?.startDrag()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        fitter?.endDrag()
    }

    override func layout() {
        super.layout()
        guard let fitter else { return }
        fitter.layoutTitleBar()
        guard let window, window.isVisible else { return }
        // Mid-drag the height is the user's, not the content's.
        if window.inLiveResize {
            fitter.follow(shown: window.contentLayoutRect)
            return
        }
        // At rest the window is its content's height, at the width the window
        // is and the factor the user's height gave.
        guard let wanted = fitter.panelHeight.resting(width: bounds.width) else { return }
        if abs(window.contentMinSize.height - fitter.chrome - wanted) >= 1 { fitter.hold(wanted...wanted) }
        let shown = window.contentLayoutRect.height
        guard abs(shown - wanted) >= 1 else { return }
        var frame = window.frame
        frame.origin.y -= wanted - shown
        frame.size.height += wanted - shown
        window.setFrame(fitter.kept(frame), display: true)
        // A frame set inside a layout pass is not laid out by it; one more
        // pass places the content for the new height.
        DispatchQueue.main.async { [weak self] in self?.needsLayout = true }
    }
}

/// The real content: the adapter `PanelHeight` measures through, and the one
/// place the app reads a content height. The window's own hosting view
/// answers for the factor it is drawn at and the width it has; any other
/// question is laid out in a probe at a pinned factor.
struct HostingProbe: ContentMeasuring {
    weak var host: NSView?
    let root: (CGFloat) -> AnyView

    func contentHeight(at factor: CGFloat, width: CGFloat) -> CGFloat {
        if let host, factor == GaugeMirror.shared.verticalFactor, abs(host.bounds.width - width) < 0.5 {
            // The window's own host runs under the title bar and counts it.
            return host.intrinsicContentSize.height - host.safeAreaInsets.top
        }
        let probe = NSHostingView(rootView: root(factor))
        probe.frame = NSRect(x: 0, y: 0, width: width, height: 100)
        probe.layoutSubtreeIfNeeded()
        return probe.intrinsicContentSize.height
    }
}

final class WindowController {
    let window: NSWindow

    /// True when the window came up on a frame it had saved, false when it was
    /// parked as it is on a first launch.
    private(set) var restoredSavedFrame = false

    private let hostingView: ContentSizedHostingView

    /// The height the content asks for at the width the window is. The window's
    /// content minimum is the height at the content's narrowest, where the
    /// cards are at their tallest, so it is not the height that leaves no
    /// strip of empty space under the cards. This is, because it
    /// is measured at the width the view has.
    var contentHeight: CGFloat { panelHeight.resting(width: hostingView.bounds.width) ?? 0 }

    /// The content size the window opens at, kept so a saved frame that is
    /// refused can be refused whole rather than leaving its width behind.
    private let defaultContent: NSSize

    /// The height rule: the chosen height, and the factor and lock every
    /// event gives.
    let panelHeight: PanelHeight

    /// Turns a mouse wheel's vertical turn into a sideways one, so a row too
    /// wide for the window scrolls under a wheel as it does under a trackpad.
    private var wheel: Any?

    /// The most boxes the window has widened for, so a width the user
    /// pulled in is kept until more boxes arrive.
    private var widenedFor = 0

    init<Content: View>(autosaveName: String = "SeatGaugePanel",
                        defaultWidth: CGFloat = 520,
                        rootView: Content) {
        window = FramePreservingWindow(
            contentRect: NSRect(x: 0, y: 0, width: defaultWidth, height: 120),
            // The content runs under a transparent title bar, which carries
            // the app's own row.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Seat Gauge"
        // The Dock icon and Cmd-Tab hand the window back, so the object has to
        // outlive the close that put it away.
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.isOpaque = true

        // Default sizingOptions plus fixedSize on the root keeps the height at
        // the content's and leaves the width free.
        let host = ContentSizedHostingView(
            rootView: AnyView(rootView.fixedSize(horizontal: false, vertical: true)))
        panelHeight = PanelHeight(measuring: HostingProbe(host: host) { factor in
            AnyView(rootView.environment(\.pinnedVerticalFactor, factor)
                .fixedSize(horizontal: false, vertical: true))
        })
        hostingView = host
        window.contentView = host
        // Laid out at the window's width first: before that the hosting view
        // has no width to measure a height against, and no constraints to
        // lock the window's content to. A content that cannot be read opens at
        // the height the window has.
        host.updateConstraintsForSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        let content = NSSize(width: max(defaultWidth, window.contentMinSize.width),
                             height: panelHeight.resting(width: defaultWidth) ?? window.contentLayoutRect.height)
        defaultContent = content
        installTitleBar()
        window.setContentSize(NSSize(width: content.width, height: content.height + chrome))
        host.fitter = self
        applyAppearance()
        // The frame height that content sizes to, kept before the autosave
        // name is applied, since naming the window moves it.
        let frameHeight = window.frame.height

        // The saved frame is read before the window is named, because naming it
        // applies that entry itself, and applies it against whichever display
        // is active rather than the one it was saved on: on a Mac with three
        // screens that lands the window somewhere nobody put it. So the name
        // goes on first, for the saving it does from here on, and the frame
        // this controller decided is set over whatever the naming did.
        let saved = UserDefaults.standard.string(forKey: "NSWindow Frame \(autosaveName)")
        let screens = NSScreen.screens.map(\.visibleFrame)
        window.setFrameAutosaveName(autosaveName)
        if let text = saved, let frame = PanelPlacement.savedFrame(from: text),
           let kept = fitted(frame, frameHeight: frameHeight),
           PanelPlacement.isOnScreen(kept, visibleFrames: screens) {
            restoredSavedFrame = true
            panelHeight.restored(savedContent: frame.height - chrome,
                                 opensAt: content.height)
            window.setFrame(kept, display: false)
        } else {
            park(on: screens, content: defaultContent)
        }
        wheel = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak window] event in
            guard event.window === window, let sideways = Self.sideways(event) else { return event }
            return sideways
        }
    }

    isolated deinit {
        if let wheel { NSEvent.removeMonitor(wheel) }
    }

    /// A wheel's line-step turn with no sideways part, as the same turn
    /// sideways. Nothing in the window scrolls up and down, so the turn is
    /// never wanted as it came. A trackpad scrolls sideways on its own, so its
    /// precise turns are left alone.
    static func sideways(_ event: NSEvent) -> NSEvent? {
        guard !event.hasPreciseScrollingDeltas, event.scrollingDeltaX == 0, event.scrollingDeltaY != 0,
              let turned = event.cgEvent?.copy() else { return nil }
        let pairs: [(CGEventField, CGEventField)] = [
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2),
            (.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2),
            (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2),
        ]
        for (vertical, horizontal) in pairs {
            turned.setIntegerValueField(horizontal, value: turned.getIntegerValueField(vertical))
            turned.setIntegerValueField(vertical, value: 0)
        }
        return NSEvent(cgEvent: turned)
    }

    /// A saved frame is worth restoring for its origin and its width. Its
    /// height is yesterday's content, so today's is used and the top edge is
    /// the one that stays put. A width the content cannot be drawn in is not
    /// restored at all, which is the fails-closed rule.
    private func fitted(_ frame: CGRect, frameHeight: CGFloat) -> CGRect? {
        guard frame.width >= window.contentMinSize.width else { return nil }
        return CGRect(x: frame.minX, y: frame.maxY - frameHeight,
                      width: frame.width, height: frameHeight)
    }

    /// Bottom-centre of the portrait display on a first launch, centre when
    /// there is none, and the same when a saved frame cannot be read, has gone
    /// off screen with the display it was saved on, or no longer fits.
    /// Naming the window applies the saved entry itself, size and all, so the
    /// default size is set again here: a frame that was refused is refused
    /// whole rather than leaving its width behind.
    private func park(on screens: [CGRect], content: NSSize) {
        window.setContentSize(NSSize(width: content.width, height: content.height + chrome))
        if let origin = PanelPlacement.firstLaunchOrigin(contentSize: window.frame.size,
                                                         visibleFrames: screens) {
            window.setFrameOrigin(origin)
        } else {
            window.center()
        }
    }

    /// The text size changed under the window, so the content now asks for a
    /// size the frame is not at. The top edge stays put, as it does when the
    /// cards arrive after the empty state, and a window narrower than the
    /// content can be drawn in is widened rather than clipping a card.
    /// The caller names the event and the controller keeps its schedule, so no
    /// caller schedules a fit: the height SwiftUI asks for is not known until
    /// it has drawn at it.
    func refit(_ event: Refit = .now) {
        if event != .drawn { fit() }
        if event != .now { DispatchQueue.main.async { [weak self] in self?.fit() } }
    }

    /// When an event's content can be measured.
    enum Refit {
        /// Back on screen, or asked for directly: fitted at once.
        case now
        /// Cards or a launch: drawn a turn from now, and fitted then.
        case drawn
        /// A text size: fitted at once and again once drawn at it.
        case textSize
    }

    private func fit() {
        // Measured again, not read back: the cached height is the one asked
        // for at the width last proposed, which at launch is the default one
        // rather than the saved frame's, and a card's lines wrap at it.
        hostingView.invalidateIntrinsicContentSize()
        hostingView.layoutSubtreeIfNeeded()
        var frame = window.frame
        var narrowest = window.contentMinSize.width
        // With no frame of the user's, the window widens for every box as
        // boxes arrive, up to the screen's width, since past that the row
        // scrolls. A saved width, or one the user pulled in since, is theirs.
        let cards = GaugeMirror.shared.model(at: Date()).columns
        if !restoredSavedFrame, cards > widenedFor {
            widenedFor = cards
            let screen = visibleScreen?.width ?? .greatestFiniteMagnitude
            narrowest = max(narrowest, min(PanelLayout.minimumContentWidth(cards: cards), screen))
        }
        if frame.width < narrowest { frame.size.width = narrowest }
        let width = window.contentRect(forFrameRect: frame).width
        settle(panelHeight.contentChanged(width: width, room: room), frame: frame)
    }

    /// One event's fit applied to the window: the factor drawn before the
    /// height is read, then the lock and the frame. A fit with a range and no
    /// lock is a drag's, held open over the range; one with neither keeps the
    /// frame.
    private func settle(_ fit: HeightFit, frame proposed: CGRect? = nil) {
        var frame = proposed ?? window.frame
        (window as? FramePreservingWindow)?.contentHeights = fit.range
        if GaugeMirror.shared.verticalFactor != fit.factor {
            GaugeMirror.shared.verticalFactor = fit.factor
            hostingView.invalidateIntrinsicContentSize()
            hostingView.layoutSubtreeIfNeeded()
        }
        if let lock = fit.lock {
            // The lock moves before the frame does: AppKit holds a set frame
            // to the content maximum, so a taller window is refused until the
            // number it is locked to is today's.
            hold(lock...lock)
            let shown = window.contentLayoutRect.height
            frame.origin.y -= lock - shown
            frame.size.height += lock - shown
        } else if let range = fit.range {
            hold(range)
        }
        frame = kept(frame)
        // A window already at the size it wants is left alone, so a reopen
        // with nothing changed does no display work.
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true)
    }

    /// A frame the content grew, back on the window's screen.
    func kept(_ frame: CGRect) -> CGRect {
        guard let screen = visibleScreen else { return frame }
        return PanelPlacement.grown(frame, from: window.frame.size, visible: screen)
    }

    /// The usable part of the window's screen, or the main one's.
    private var visibleScreen: CGRect? { (window.screen ?? NSScreen.main)?.visibleFrame }

    /// The content held between two heights: one height at rest, the drag's
    /// range mid-drag.
    /// The window's content runs under the title bar, so its bounds carry it.
    func hold(_ heights: ClosedRange<CGFloat>) {
        let low = heights.lowerBound + chrome, high = heights.upperBound + chrome
        if window.contentMinSize.height != low { window.contentMinSize.height = low }
        if window.contentMaxSize.height != high { window.contentMaxSize.height = high }
    }

    /// The content heights the window can be dragged over: factor 1 up to
    /// the top of the range or the screen, whichever is lower.
    func heightBounds() -> ClosedRange<CGFloat> {
        panelHeight.range(width: window.contentLayoutRect.width, room: room) ?? 0...0
    }

    /// The content height the screen has room for under the title bar.
    private var room: CGFloat {
        let screen = visibleScreen?.height ?? .greatestFiniteMagnitude
        return screen - chrome
    }

    /// A drag begins: the range is measured and opened before AppKit reads it.
    func startDrag() {
        settle(panelHeight.dragStarted(width: window.contentLayoutRect.width, room: room))
    }

    /// Each step of a drag holds the content open at the range.
    func follow(shown: CGRect) {
        settle(panelHeight.dragStepped(width: shown.width, room: room))
    }

    /// The drag's height is the user's; the window settles on the content.
    func endDrag() {
        let shown = window.contentLayoutRect
        settle(panelHeight.dragEnded(shown: shown.height, width: shown.width, room: room))
        DispatchQueue.main.async { [weak self] in self?.fit() }
    }

    /// Dark or light: the window's appearance, which the marks read, and its
    /// ground.
    func applyAppearance() {
        window.appearance = NSAppearance(named: GaugeMirror.shared.lightAppearance ? .aqua : .darkAqua)
        window.backgroundColor = NSColor(Tone.bg)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: false)
    }
}
