import CoreGraphics
import Testing
@testable import ikut

@Suite("SheetButtonSize caps")
struct SheetButtonSizeTests {
    @Test func neverUnderTheHitTarget() {
        // At the smallest text size a 44 pt button would scale below 44; it stays tappable.
        #expect(SheetButtonSize.capped(38, base: SheetButtonSize.hit) == SheetButtonSize.hit)
    }

    @Test func scalesWithinTheCap() {
        #expect(SheetButtonSize.capped(52, base: SheetButtonSize.hit) == 52)
    }

    @Test func neverOutgrowsTheCap() {
        let cap = SheetButtonSize.hit * SheetButtonSize.maxScale
        #expect(SheetButtonSize.capped(200, base: SheetButtonSize.hit) == cap)
    }

    @Test func aSmallBaseStillKeepsTheHitTarget() {
        #expect(SheetButtonSize.capped(30, base: SheetButtonSize.tile) == SheetButtonSize.hit)
    }
}

@Suite("IkutButtonSize")
struct IkutButtonSizeTests {
    @Test func standardIs44AndMainIs50AtTheDefaultTextSize() {
        #expect(IkutButtonSize.standard.height(scaled: 44) == 44)
        #expect(IkutButtonSize.main.height(scaled: 50) == 50)
    }

    @Test func neverUnder44AndCappedAtOnePointSixTimesTheBase() {
        #expect(IkutButtonSize.standard.height(scaled: 30) == 44)
        #expect(IkutButtonSize.standard.height(scaled: 200) == 44 * 1.6)
        #expect(IkutButtonSize.main.height(scaled: 200) == 50 * 1.6)
    }

    @Test func theLabelMakesUpWhatTheStyleDoesNotAdd() {
        #expect(IkutButtonSize.labelMinHeight(total: 44, addsPadding: true) == 30)
        #expect(IkutButtonSize.labelMinHeight(total: 50, addsPadding: true) == 36)
        #expect(IkutButtonSize.labelMinHeight(total: 44, addsPadding: false) == 44)
        #expect(IkutButtonSize.labelMinHeight(total: 10, addsPadding: true) == 0)
    }
}
