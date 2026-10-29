import Foundation
import Testing
@testable import ikut

struct MapTypeColourTests {
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
        for fill in [MapColors.ok, MapColors.hazardLow, MapColors.staleBadge, MapColors.errorBanner] {
            #expect(contrast(0xFFFFFF, fill.light) >= 4.5)
            #expect(contrast(0xFFFFFF, fill.dark) >= 4.5)
        }
    }

    @Test func blackGlyphsOnTheBrightFillsReadInBothModes() {
        // System yellow (FFCC00 light, FFD60A dark), system orange (FF9500, FF9F0A) and the banner blue.
        for fill: UInt32 in [0xFFCC00, 0xFFD60A, 0xFF9500, 0xFF9F0A, // also the stop reason icon
             MapColors.pillBlue.light, MapColors.pillBlue.dark] {
            #expect(contrast(0x000000, fill) >= 4.5)
        }
    }

    @Test func whiteGlyphsOnThePaletteFillsReadInBothModes() {
        for fill in Palette.underWhite {
            #expect(contrast(0xFFFFFF, fill.light) >= 4.5)
            #expect(contrast(0xFFFFFF, fill.dark) >= 4.5)
        }
    }

    /// D78: the unpicked disc is the neutral fill now, so it holds 4.5:1 like every other white-on-fill.
    @Test func theUnpickedDiscHoldsTheNeutralFill() {
        #expect(Palette.unselectedDisc == Palette.neutralFill)
        #expect(contrast(0xFFFFFF, Palette.unselectedDisc.light) >= 4.5)
        #expect(contrast(0xFFFFFF, Palette.unselectedDisc.dark) >= 4.5)
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
        let texts: [(String, ModeColor)] = [
            ("warning", Palette.warningText),
            ("positive", Palette.positiveText),
            ("accent", Palette.accentText),
        ]
        let tint = TintFill.chip.amount
        #expect(tint == 0.14)
        for (name, t) in texts {
            for (fg, bgs) in [(t.light, [0xFFFFFF, 0xF2F2F7] as [UInt32]), (t.dark, [0x1C1C1E, 0x000000])] {
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
        #expect(Palette.accentText.light != accent && Palette.positiveText.light != positive)
        #expect(Palette.accentFill.light == accent)
    }

    @Test func theTextTokensAreTheOnesTheAppDraws() {
        #expect(MapColors.warningTitle == Palette.warningText)
        #expect(Palette.staleChipText == Palette.warningText)
        #expect(MapColors.errorBanner == Palette.criticalFill)
        #expect(Palette.reportRed == Palette.criticalFill)
        #expect(MapColors.hazardLow == Palette.neutralFill && MapColors.staleBadge == Palette.neutralFill)
        #expect(MapColors.glassAccentDark == MapColors.pillBlue)
    }

    @Test func aModeColourWithoutAlphaIsOpaque() {
        #expect(MapColors.ok.lightAlpha == 1 && MapColors.ok.darkAlpha == 1)
        #expect(Palette.surfaceTileFill.lightAlpha == 0.5 && Palette.surfaceTileFill.darkAlpha == 0.10)
    }
}
