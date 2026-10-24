import SwiftUI
import UIKit

/// A colour that has one value in light and one in dark, as 0xRRGGBB. Kept as numbers so a unit test can
/// check the contrast of a white (or black) glyph on it in both modes.
struct ModeColor: Equatable {
    var light: UInt32
    var dark: UInt32

    var color: Color {
        func ui(_ v: UInt32) -> UIColor {
            UIColor(
                red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        let (light, dark) = (ui(light), ui(dark))
        return Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

/// The map's own named colours (D34). Where a system colour is the same thing (`.yellow`, `.orange`,
/// `.green`) the code uses that instead; these are the ones that need a value of ours.
enum MapColors {
    /// The stop pill's OK button, under a white label: 4.5:1 or better in both modes.
    static let ok = ModeColor(light: 0x1F7A35, dark: 0x23823A)
    /// A low-severity hazard, under a white glyph.
    static let hazardLow = ModeColor(light: 0x636366, dark: 0x6E6E73)
    /// The stale-car clock badge, under a white glyph.
    static let staleBadge = ModeColor(light: 0x636366, dark: 0x6E6E73)
    /// The planned-stop pill's blue. Its banner is dark in both modes, so the value is the same in both;
    /// the glyph on it is black.
    static let pillBlue = ModeColor(light: 0x64B5FF, dark: 0x64B5FF)
}

extension Color {
    /// OK green under a white label.
    static let ikutOK = MapColors.ok.color
    static let ikutPillBlue = MapColors.pillBlue.color
    /// The designated lead's star and a high-severity hazard: one yellow, the system's.
    static let ikutLeadYellow = Color.yellow
}

/// How far a map marker may grow with the person's text size: it follows Dynamic Type, but a marker at the
/// largest accessibility size stays a marker, not a card.
enum MarkerMetrics {
    static let maxGrowth: CGFloat = 1.6

    /// `raw` is a `@ScaledMetric` of 1 (what the text size does to a point); the factor to draw with.
    static func scale(_ raw: CGFloat) -> CGFloat { min(max(raw, 1), maxGrowth) }

    /// The small clock on a car that has gone quiet (not one that paused sharing: it says so in words), so "stale" doesn't rest on the fade alone.
    static func showsStaleBadge(_ marker: MapMarker) -> Bool { marker.isStale && !marker.isPaused }
}

/// From / To on the convoy panel: a text style (not a fixed 30 pt) that wraps to two lines before it ever
/// truncates, and shrinks only as the last resort.
enum ConvoyEndName {
    static let minimumScale: CGFloat = 0.7

    static func lineLimit(accessibilitySize: Bool) -> Int { accessibilitySize ? 3 : 2 }
}

// MARK: - Palette

enum MapPalette {
    /// Fills under white labels (Report, the progress bar): the same blue in both modes on purpose, since the
    /// lighter dark-mode blue would put a white label under 4.5:1.
    static let accent = Color(red: 0, green: 113 / 255, blue: 227 / 255)
    /// The route line and its edge read against map imagery in both modes, so they stay one value.
    static let route = Color(red: 10 / 255, green: 132 / 255, blue: 1)
    static let routeCasing = Color(red: 0, green: 96 / 255, blue: 223 / 255)
    /// The system green (the same 34C759 in light, a lighter one in dark).
    static let live = Color.green
    /// The warning orange-red, with the lighter orange in dark that the rest of the app uses.
    static let warning = Color.ikutWarning
    /// Stale-car chip text: the warning red on light, a lighter orange on dark so it stays legible.
    static let staleChipText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 159 / 255, blue: 10 / 255, alpha: 1)
            : UIColor(red: 176 / 255, green: 40 / 255, blue: 0, alpha: 1)
    })
}
