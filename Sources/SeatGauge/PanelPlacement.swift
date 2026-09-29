import AppKit

/// Where the panel goes, as functions over rectangles, so the rules can be read
/// without a second display plugged in.
enum PanelPlacement {
    /// The gap between the panel and the bottom of the portrait display.
    static let bottomInset: CGFloat = 24

    /// How much of the panel has to fall on a screen for it to count as
    /// visible. Less than this and it cannot be grabbed to drag it back.
    static let minimumVisible: CGFloat = 80

    /// Bottom-centre of the first portrait display, or `nil` when there is
    /// none, which the caller reads as "centre it".
    static func firstLaunchOrigin(contentSize: CGSize, visibleFrames: [CGRect]) -> CGPoint? {
        guard let portrait = visibleFrames.first(where: { $0.height > $0.width }) else { return nil }
        return CGPoint(x: portrait.midX - contentSize.width / 2,
                       y: portrait.minY + bottomInset)
    }

    /// An autosaved frame is eight numbers, the frame first. Anything else is
    /// not a frame and is discarded rather than guessed at.
    static func savedFrame(from text: String) -> CGRect? {
        let numbers = text.split(separator: " ").compactMap { Double($0) }
        guard numbers.count >= 4, numbers[2] > 0, numbers[3] > 0 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    /// A window shorter or narrower than the minimum counts when all of that
    /// side is on the screen: the empty state is
    /// under 80 points tall, and wholly visible is visible.
    static func isOnScreen(_ frame: CGRect, visibleFrames: [CGRect]) -> Bool {
        visibleFrames.contains { screen in
            let shared = screen.intersection(frame)
            return !shared.isNull && shared.width >= min(minimumVisible, frame.width)
                && shared.height >= min(minimumVisible, frame.height)
        }
    }

    /// A frame that grew for its content, moved back onto the screen it grew
    /// off, as far as it fits, so the top edge stays reachable. A frame that did
    /// not grow is where the user put it and is left there.
    static func grown(_ frame: CGRect, from old: CGSize, visible: CGRect) -> CGRect {
        guard frame.width > old.width + 0.5 || frame.height > old.height + 0.5 else { return frame }
        var kept = frame
        if kept.maxX > visible.maxX { kept.origin.x = max(visible.minX, visible.maxX - kept.width) }
        if kept.minY < visible.minY { kept.origin.y = min(visible.minY, visible.maxY - kept.height) }
        return kept
    }
}
