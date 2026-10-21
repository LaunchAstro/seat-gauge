import Foundation
import SwiftUI
import Testing

@testable import SeatGauge

/// The side-scroll arrows: drawn only while the pointer is on the row, and
/// then only at an edge with more row past it.
@Suite @MainActor struct EdgeArrowTests {

    @Test func arrowsShowOnlyWhileTheRowIsHovered() {
        // A row of 600 in a viewport of 300, scrolled 100 in: room both ways.
        let middle = CardScroller<EmptyView>.arrows(hovered: true, offset: -100, width: 600, viewport: 300)
        #expect(middle.leading && middle.trailing)
        let passive = CardScroller<EmptyView>.arrows(hovered: false, offset: -100, width: 600, viewport: 300)
        #expect(!passive.leading && !passive.trailing)
        // At the start there is nothing to the left.
        let start = CardScroller<EmptyView>.arrows(hovered: true, offset: 0, width: 600, viewport: 300)
        #expect(!start.leading && start.trailing)
    }
}
