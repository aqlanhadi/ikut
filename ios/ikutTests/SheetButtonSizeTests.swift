import CoreGraphics
import SwiftUI
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

@MainActor
@Suite("Tap areas")
struct TapAreaTests {
    private final class Box { var size = CGSize.zero }

    /// The size the view lays out at, read from SwiftUI's own geometry after the host has run a layout pass.
    private func size<V: View>(_ view: V, _ type: DynamicTypeSize) -> CGSize {
        let box = Box()
        let probe = view.environment(\.dynamicTypeSize, type).fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { box.size = $0 }
        let host = UIHostingController(rootView: AnyView(probe))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return box.size
    }

    @Test func everyRoundButtonIsAtLeast44AtEverySize() {
        for type in [DynamicTypeSize.large, .accessibility3] {
            for style in [RoundGlassIconButton.Style.glass, .quiet, .bare] {
                let s = size(RoundGlassIconButton(systemImage: "chevron.left", label: "Back", style: style) {}, type)
                #expect(s.width >= 44 && s.height >= 44, "\(style) \(type): \(s)")
            }
        }
    }

    @Test func quietAndBareRoundButtonsGrowWithTheTextSizeToTheCap() {
        for style in [RoundGlassIconButton.Style.quiet, .bare] {
            let small = size(RoundGlassIconButton(systemImage: "xmark", label: "Close", style: style) {}, .large)
            let big = size(RoundGlassIconButton(systemImage: "xmark", label: "Close", style: style) {}, .accessibility3)
            #expect(small.height == 44)
            #expect(big.height > 44 && big.height <= 44 * SheetButtonSize.maxScale)
        }
    }

    @Test func aLinkIsAtLeast44TallAtEverySize() {
        for type in [DynamicTypeSize.large, .accessibility3] {
            let s = size(Button {} label: { Text("Copy").frame(maxWidth: .infinity) }.ikutButton(.link), type)
            #expect(s.height >= 44, "\(type): \(s)")
        }
    }
}
