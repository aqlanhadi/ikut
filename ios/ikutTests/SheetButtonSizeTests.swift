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

@Suite("IkutButtonLook")
struct IkutButtonLookTests {
    private let face = IkutButtonFace(fill: .gray, foreground: .white)

    @Test func glassIsOnlyOnAGlassSurfaceWhenGlassIsShowing() {
        #expect(IkutButtonLook.resolve(role: .primary, face: nil, surface: .glass, glassActive: true).kind == .glassProminent)
        #expect(IkutButtonLook.resolve(role: .secondary, face: nil, surface: .glass, glassActive: true).kind == .glass)
        #expect(IkutButtonLook.resolve(role: .primary, face: nil, surface: .plain, glassActive: true).kind == .borderedProminent)
        #expect(IkutButtonLook.resolve(role: .secondary, face: nil, surface: .plain, glassActive: true).kind == .bordered)
    }

    @Test func withoutGlassTheFilledStylesAreUsedAndPadded() {
        let primary = IkutButtonLook.resolve(role: .primary, face: nil, surface: .glass, glassActive: false)
        #expect(primary.kind == .borderedProminent)
        #expect(primary.addsPadding)
        let secondary = IkutButtonLook.resolve(role: .secondary, face: nil, surface: .glass, glassActive: false)
        #expect(secondary.kind == .bordered)
        #expect(secondary.addsPadding)
    }

    @Test func theStopCardFaceIsFlatAndUnpaddedBeforeGlass() {
        let look = IkutButtonLook.resolve(role: .primary, face: face, surface: .glass, glassActive: false)
        #expect(look.kind == .flat)
        #expect(!look.addsPadding)
        #expect(IkutButtonLook.resolve(role: .secondary, face: face, surface: .glass, glassActive: true).kind == .glass)
    }

    @Test func aLinkNeverPadsAndNeverGoesGlass() {
        for surface in [IkutSurface.plain, .glass] {
            let look = IkutButtonLook.resolve(role: .link, face: nil, surface: surface, glassActive: true)
            #expect(look.kind == .borderless)
            #expect(!look.addsPadding)
        }
    }

    @Test func mapPickStaysFilledEvenWhenOpenedFromAGlassSheet() {
        #expect(MapPickView.surface == .plain)
    }
}
