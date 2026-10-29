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
        for fill in [MapColors.ok, MapColors.hazardLow, MapColors.staleBadge] {
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

    /// The unpicked number disc is a 13 pt digit on a mid gray, as it was before D73: it holds 3:1, not 4.5:1.
    @Test func theUnpickedDiscKeepsItsContrast() {
        #expect(contrast(0xFFFFFF, Palette.unselectedDisc.light) >= 3)
    }

    @Test func aModeColourWithoutAlphaIsOpaque() {
        #expect(MapColors.ok.lightAlpha == 1 && MapColors.ok.darkAlpha == 1)
        #expect(Palette.surfaceTileFill.lightAlpha == 0.5 && Palette.surfaceTileFill.darkAlpha == 0.10)
    }
}
