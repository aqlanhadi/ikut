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

@Suite("IkutButtonLook")
struct IkutButtonLookTests {
    private let face = IkutButtonFace(fill: .gray, foreground: .white)

    @Test func glassIsOnlyOnAGlassSurfaceWhenGlassIsShowing() {
        #expect(IkutButtonLook.resolve(role: .primary, face: nil, surface: .glass, glassActive: true).kind == .glassProminent)
        #expect(IkutButtonLook.resolve(role: .secondary, face: nil, surface: .glass, glassActive: true).kind == .glass)
        #expect(IkutButtonLook.resolve(role: .primary, face: nil, surface: .plain, glassActive: true).kind == .borderedProminent)
        #expect(IkutButtonLook.resolve(role: .secondary, face: nil, surface: .plain, glassActive: true).kind == .bordered)
    }

    @Test func withoutGlassTheFilledStylesAreUsed() {
        let primary = IkutButtonLook.resolve(role: .primary, face: nil, surface: .glass, glassActive: false)
        #expect(primary.kind == .borderedProminent)
        let secondary = IkutButtonLook.resolve(role: .secondary, face: nil, surface: .glass, glassActive: false)
        #expect(secondary.kind == .bordered)
    }

    @Test func theStopCardFaceIsFlatBeforeGlass() {
        let look = IkutButtonLook.resolve(role: .primary, face: face, surface: .glass, glassActive: false)
        #expect(look.kind == .flat)
        #expect(IkutButtonLook.resolve(role: .secondary, face: face, surface: .glass, glassActive: true).kind == .glass)
    }

    @Test func aLinkNeverGoesGlass() {
        for surface in [IkutSurface.plain, .glass] {
            let look = IkutButtonLook.resolve(role: .link, face: nil, surface: surface, glassActive: true)
            #expect(look.kind == .borderless)
        }
    }

    @Test func mapPickStaysFilledEvenWhenOpenedFromAGlassSheet() {
        #expect(MapPickView.surface == .plain)
    }
}

@Suite("Round icon buttons")
struct RoundButtonSizeTests {
    @Test func theStandardRoundSizeIsTheHitTarget() {
        #expect(SheetButtonSize.hit == 44)
        #expect(SheetButtonSize.capped(44, base: SheetButtonSize.hit) == 44)
    }

    @Test func roundButtonsStopAt70PointsAtTheLargestAccessibilitySize() {
        // accessibility3 scales a 44 pt base to about 100; the cap is 1.6 times the base.
        #expect(SheetButtonSize.capped(100, base: SheetButtonSize.hit) == 70.4)
    }

    @Test func aLargerBaseKeepsItsOwnCap() {
        #expect(SheetButtonSize.capped(200, base: 50) == 80)
    }
}
