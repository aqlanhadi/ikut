import Foundation
import Testing
import UIKit
@testable import ikut

struct MapTypeColourTests {
    /// D87: every colour is a Color Set in the catalog. These are today's values (the ones the code held as
    /// numbers before the move), the one place hex stays: name, light, dark, light alpha, dark alpha.
    static let expected: [(name: String, light: UInt32, dark: UInt32, lightAlpha: Double, darkAlpha: Double)] = [
        ("ikutAccent", 0x0071E3, 0x2997FF, 1, 1), ("ikutPositive", 0x1F7A35, 0x30D158, 1, 1),
        ("ikutWarning", 0xB02800, 0xFF9F0A, 1, 1), ("ikutAccentFill", 0x0071E3, 0x0071E3, 1, 1),
        ("ikutRoute", 0x0A84FF, 0x0A84FF, 1, 1), ("ikutRouteCasing", 0x0060DF, 0x0060DF, 1, 1),
        ("accentText", 0x005FBF, 0x2997FF, 1, 1), ("positiveText", 0x1D7031, 0x30D158, 1, 1),
        ("warningFill", 0xC93300, 0xC93300, 1, 1), ("criticalFill", 0xD60014, 0xD60014, 1, 1),
        ("neutralFill", 0x636366, 0x6E6E73, 1, 1), ("ikutJoining", 0x0F756E, 0x2ED4BF, 1, 1),
        ("ikutBannerDark", 0x1C1C1C, 0x1C1C1C, 1, 1), ("surfaceTileFill", 0xFFFFFF, 0xFFFFFF, 0.5, 0.10),
        ("glassSecondaryText", 0x000000, 0xFFFFFF, 0.68, 0.78), ("reportBrown", 0x8A6B45, 0x8A6B45, 1, 1),
        ("ikutOK", 0x1F7A35, 0x23823A, 1, 1), ("ikutPillBlue", 0x64B5FF, 0x64B5FF, 1, 1),
        ("destinationPin", 0x1C1C1E, 0x48484A, 1, 1),
        ("recapLead", 0xC93400, 0xC93400, 1, 1), ("recapFirstIn", 0x1F7A35, 0x1F7A35, 1, 1),
        ("recapReporter", 0xB25000, 0xB25000, 1, 1), ("recapStopCaller", 0xD70015, 0xD70015, 1, 1),
        ("recapSweeper", 0x5856D6, 0x5856D6, 1, 1), ("recapStopPin", 0xFF3B30, 0xFF3B30, 1, 1),
        ("recapHazardPin", 0xFFCC00, 0xFFCC00, 1, 1), ("recapRouteGlow", 0xF3D08A, 0xF3D08A, 1, 1),
    ]

    /// The colour as the app draws it in light or dark: resolved from the catalog, not from numbers in code.
    private func resolved(_ name: String, dark: Bool) -> (rgb: UInt32, alpha: Double)? {
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        guard let named = UIColor(named: name, in: Bundle.main, compatibleWith: traits) else { return nil }
        let c = named.resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard c.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        func byte(_ x: CGFloat) -> UInt32 { UInt32(min(max((x * 255).rounded(), 0), 255)) }
        return ((byte(r) << 16) | (byte(g) << 8) | byte(b), Double(a))
    }
    private func light(_ name: String) -> UInt32 { resolved(name, dark: false)?.rgb ?? 0xFF00FF }
    private func dark(_ name: String) -> UInt32 { resolved(name, dark: true)?.rgb ?? 0xFF00FF }

    @Test func everyNamedColourResolvesInBothModesToTheValueItHadInCode() {
        for e in Self.expected {
            let l = resolved(e.name, dark: false), d = resolved(e.name, dark: true)
            #expect(l != nil && d != nil, "\(e.name) resolves")
            #expect(l?.rgb == e.light, "\(e.name) light")
            #expect(d?.rgb == e.dark, "\(e.name) dark")
            #expect(abs((l?.alpha ?? -1) - e.lightAlpha) < 0.005, "\(e.name) light alpha")
            #expect(abs((d?.alpha ?? -1) - e.darkAlpha) < 0.005, "\(e.name) dark alpha")
        }
    }

    /// What a white glyph sits on; the contrast test walks these.
    private let underWhite = ["ikutAccentFill", "warningFill", "criticalFill", "neutralFill", "ikutOK", "reportBrown"]

    private func marker(stale: Bool, paused: Bool = false) -> MapMarker {
        MapMarker(
            id: "c", number: 1, name: "Car", colorHex: "#2563EB", coordinate: MapCoordinate(latitude: 4, longitude: 101),
            heading: nil, isStale: stale, ageText: nil, isLead: false, isJoining: false, isMine: false, isPaused: paused)
    }

    @Test func aMarkerFollowsTheTextSizeButStopsAtOneAndAHalfOrSo() {
        #expect(MarkerMetrics.scale(1) == 1)
        #expect(MarkerMetrics.scale(1.3) == 1.3)
        #expect(MarkerMetrics.scale(2.4) == MarkerMetrics.maxGrowth)
        #expect(MarkerMetrics.maxGrowth <= 1.6)
        // Smaller than the default never shrinks it below today's 32 pt.
        #expect(MarkerMetrics.scale(0.8) == 1)
    }

    @Test func theClockShowsOnlyOnAStaleCar() {
        #expect(MarkerMetrics.showsStaleBadge(marker(stale: true)))
        #expect(!MarkerMetrics.showsStaleBadge(marker(stale: false)))
        #expect(!MarkerMetrics.showsStaleBadge(marker(stale: true, paused: true)))
    }

    @Test func fromAndToWrapBeforeTheyShrink() {
        #expect(ConvoyEndName.lineLimit(accessibilitySize: false) == 2)
        #expect(ConvoyEndName.lineLimit(accessibilitySize: true) == 3)
        #expect(ConvoyEndName.minimumScale >= 0.7)
    }

    /// WCAG relative luminance contrast of two 0xRRGGBB colours.
    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func lum(_ v: UInt32) -> Double {
            func ch(_ c: UInt32) -> Double {
                let s = Double(c) / 255
                return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * ch((v >> 16) & 0xFF) + 0.7152 * ch((v >> 8) & 0xFF) + 0.0722 * ch(v & 0xFF)
        }
        let (hi, lo) = (max(lum(a), lum(b)), min(lum(a), lum(b)))
        return (hi + 0.05) / (lo + 0.05)
    }

    @Test func whiteGlyphsOnTheMapFillsReadInBothModes() {
        for fill in ["ikutOK", "neutralFill", "criticalFill"] {
            #expect(contrast(0xFFFFFF, light(fill)) >= 4.5, "\(fill) light")
            #expect(contrast(0xFFFFFF, dark(fill)) >= 4.5, "\(fill) dark")
        }
    }

    @Test func blackGlyphsOnTheBrightFillsReadInBothModes() {
        // System yellow (FFCC00 light, FFD60A dark), system orange (FF9500, FF9F0A) and the banner blue.
        for fill: UInt32 in [0xFFCC00, 0xFFD60A, 0xFF9500, 0xFF9F0A, // also the stop reason icon
             light("ikutPillBlue"), dark("ikutPillBlue")] {
            #expect(contrast(0x000000, fill) >= 4.5)
        }
    }

    @Test func whiteGlyphsOnThePaletteFillsReadInBothModes() {
        for fill in underWhite {
            #expect(contrast(0xFFFFFF, light(fill)) >= 4.5, "\(fill) light")
            #expect(contrast(0xFFFFFF, dark(fill)) >= 4.5, "\(fill) dark")
        }
    }

    /// D78: the unpicked disc, the low hazard and the stale badge draw the neutral fill, so it holds 4.5:1 like every other white-on-fill.
    @Test func theNeutralFillHoldsUnderWhite() {
        #expect(contrast(0xFFFFFF, light("neutralFill")) >= 4.5)
        #expect(contrast(0xFFFFFF, dark("neutralFill")) >= 4.5)
    }

    /// Mix `fg` over `bg` at `alpha`, per channel.
    private func over(_ fg: UInt32, _ bg: UInt32, _ alpha: Double) -> UInt32 {
        var out: UInt32 = 0
        for shift: UInt32 in [16, 8, 0] {
            let f = Double((fg >> shift) & 0xFF), b = Double((bg >> shift) & 0xFF)
            out |= UInt32((f * alpha + b * (1 - alpha)).rounded()) << shift
        }
        return out
    }

    /// Text tokens read on a card, on the screen and on their own 14% tint over either, in both modes.
    @Test func textTokensReadOnCardsScreensAndTheirOwnTint() {
        let texts = [("warning", "ikutWarning"), ("positive", "positiveText"), ("accent", "accentText")]
        let tint = TintFill.tint.amount
        #expect(tint == 0.14)
        for (name, token) in texts {
            for (fg, bgs) in [(light(token), [0xFFFFFF, 0xF2F2F7] as [UInt32]), (dark(token), [0x1C1C1E, 0x000000])] {
                for bg in bgs {
                    #expect(contrast(fg, bg) >= 4.5, "\(name) on \(String(bg, radix: 16))")
                    #expect(contrast(fg, over(fg, bg, tint)) >= 4.5, "\(name) on its tint over \(String(bg, radix: 16))")
                }
            }
        }
    }

    /// Known gap, recorded so it is visible: the brand accent and positive (light) are what the app draws as text
    /// today, and they miss 4.5:1 on the grey screen and on their own 14% tint. D79 moves text uses to
    /// accentText / positiveText, which pass.
    @Test func theBrandAccentAndPositiveKeepTheirValuesAndMissTheTextRatioInLight() {
        let tint = 0.14
        let accent: UInt32 = 0x0071E3, positive: UInt32 = 0x1F7A35
        #expect(abs(contrast(accent, 0xF2F2F7) - 4.21) < 0.01)
        #expect(abs(contrast(accent, over(accent, 0xF2F2F7, tint)) - 3.50) < 0.01)
        #expect(abs(contrast(positive, over(positive, 0xF2F2F7, tint)) - 4.01) < 0.01)
        #expect(light("accentText") != accent && light("positiveText") != positive)
        #expect(light("ikutAccent") == accent && light("ikutPositive") == positive)
        #expect(light("ikutAccentFill") == accent)
    }

    @Test func theTextTokensAreTheOnesTheAppDraws() {
        #expect(TintFill.wash.amount == 0.06 && TintFill.tint.amount == 0.14)
    }
}
