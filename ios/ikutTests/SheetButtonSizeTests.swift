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
