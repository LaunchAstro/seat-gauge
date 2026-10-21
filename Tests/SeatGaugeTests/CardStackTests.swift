import CoreGraphics
import Testing

@testable import SeatGauge

/// Content that stacks: each row count is `card` tall a row at factor 1 and
/// `slope` more a row at factor 3, rows one rule apart.
@MainActor final class StackedMeasure: ContentMeasuring {
    let card: CGFloat
    let slope: CGFloat
    let maxRows: Int

    init(card: CGFloat = 100, slope: CGFloat = 40, maxRows: Int = 3) {
        self.card = card
        self.slope = slope
        self.maxRows = maxRows
    }

    func contentHeight(at factor: CGFloat, width: CGFloat) -> CGFloat {
        contentHeight(at: factor, rows: 1, width: width)
    }

    func contentHeight(at factor: CGFloat, rows: Int, width: CGFloat) -> CGFloat {
        CGFloat(rows) * (card + (factor - 1) / 2 * slope) + CGFloat(rows - 1) * PanelLayout.ruleWidth
    }
}

/// The cards stack into rows as the window is pulled taller, each row
/// growing to its tallest before another fits.
@Suite(.sharedMirror) @MainActor struct CardStackTests {

    static let width: CGFloat = 900
    static let room = CGFloat.greatestFiniteMagnitude

    @Test func theCardsSpreadEvenlyOverTheAskedRows() {
        #expect(PanelLayout.columns(cards: 5, rows: 1) == 5)
        #expect(PanelLayout.columns(cards: 5, rows: 2) == 3)
        #expect(PanelLayout.columns(cards: 5, rows: 3) == 2)
        #expect(PanelLayout.columns(cards: 5, rows: 5) == 1)
        // More rows than cards is one card a row.
        #expect(PanelLayout.columns(cards: 2, rows: 4) == 1)
    }

    @Test func aTallerHeightStretchesTheRowThenStacksAnother() {
        let height = PanelHeight(measuring: StackedMeasure())
        let one = height.contentChanged(width: Self.width, room: Self.room)
        #expect(one.rows == 1 && one.factor == 1 && one.lock == 100)
        #expect(one.range == 100...422)

        // Inside one row's span the cards grow.
        height.chosen = 120
        let taller = height.contentChanged(width: Self.width, room: Self.room)
        #expect(taller.rows == 1 && taller.factor == 2 && taller.lock == 120)

        // Past its top and short of two rows, one row at its tallest.
        height.chosen = 160
        let between = height.contentChanged(width: Self.width, room: Self.room)
        #expect(between.rows == 1 && between.factor == 3 && between.lock == 140)

        // Room for two rows stacks them, and they grow together.
        height.chosen = 201
        let two = height.contentChanged(width: Self.width, room: Self.room)
        #expect(two.rows == 2 && two.factor == 1 && two.lock == 201)
        height.chosen = 241
        let stretched = height.contentChanged(width: Self.width, room: Self.room)
        #expect(stretched.rows == 2 && stretched.factor == 2 && stretched.lock == 241)
    }

    @Test func rowsThatMeasureTheSameAsFewerAreNotTaken() {
        // One tab already wraps into two rows, so one and two start alike.
        final class Wrapped: ContentMeasuring {
            var maxRows: Int { 3 }
            func contentHeight(at factor: CGFloat, width: CGFloat) -> CGFloat { 201 }
            func contentHeight(at factor: CGFloat, rows: Int, width: CGFloat) -> CGFloat {
                rows < 3 ? 201 + (factor - 1) * 20 : 302 + (factor - 1) * 30
            }
        }
        let height = PanelHeight(measuring: Wrapped())
        height.chosen = 201
        #expect(height.contentChanged(width: Self.width, room: Self.room).rows == 1)
        height.chosen = 302
        #expect(height.contentChanged(width: Self.width, room: Self.room).rows == 3)
    }

    @Test func theScreenCapsTheStack() {
        let height = PanelHeight(measuring: StackedMeasure())
        height.chosen = 100_000
        let fit = height.contentChanged(width: Self.width, room: 250)
        #expect(fit.rows == 2)
        #expect(fit.range == 100...250)
    }
}
