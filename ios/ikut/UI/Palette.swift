import SwiftUI
import UIKit

/// Every colour of ours that isn't in `Theme.swift` or `MapColors.swift`, as numbers (so a unit test can check
/// its contrast) and then as a named `Color`. D73: nothing here is drawn from a raw RGB literal at a call site.
/// Values that look alike stay separate on purpose (a green that differs in dark is a different token).
enum Palette {
    // MARK: Fills and lines on the map

    /// Fills under white labels (Report, the progress bar): the same blue in both modes on purpose, since the
    /// lighter dark-mode blue would put a white label under 4.5:1.
    static let accentFill = ModeColor(light: 0x0071E3, dark: 0x0071E3)
    /// The route line and its edge read against map imagery in both modes, so they stay one value.
    static let route = ModeColor(light: 0x0A84FF, dark: 0x0A84FF)
    static let routeCasing = ModeColor(light: 0x0060DF, dark: 0x0060DF)

    // MARK: Status

    /// Accent TEXT (not the brand accent, which stays 0071E3): a touch darker in light than the 0071E3 fill so it holds 4.5:1 on a screen and on its own 14% tint.
    static let accentText = ModeColor(light: 0x005FBF, dark: 0x2997FF)
    /// Positive TEXT (the brand green ikutPositive stays 1F7A35), same test.
    static let positiveText = ModeColor(light: 0x1D7031, dark: 0x30D158)
    /// Warning text (waiting, spread, the stale chip, the lobby warning title): one pair, 4.5:1 on a card, a
    /// screen and its own 14% tint in both modes.
    static let warningText = ModeColor(light: 0xB02800, dark: 0xFF9F0A)
    /// Warning fill under a white label, the same in both modes.
    static let warningFill = ModeColor(light: 0xC93300, dark: 0xC93300)
    /// Critical fill under a white label (the error banner, Report's red).
    static let criticalFill = ModeColor(light: 0xD60014, dark: 0xD60014)
    /// Neutral gray fill under a white glyph (low hazard, stale badge, the unpicked disc, Report's gray).
    static let neutralFill = ModeColor(light: 0x636366, dark: 0x6E6E73)

    /// Teal of a car that is still joining the convoy; the meeting point wears it too.
    static let joining = ModeColor(light: 0x0F756E, dark: 0x2ED4BF)

    // MARK: Surfaces

    /// The floating banners (alert, report toast), dark in both modes: #1C1C1E on the canvas.
    static let bannerDark = ModeColor(light: 0x1C1C1C, dark: 0x1C1C1C)
    /// Light: a milky white; dark: a faint lift. Both let the glass behind show.
    static let surfaceTileFill = ModeColor(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.5, darkAlpha: 0.10)
    /// Secondary text on glass: black at 68% in light, white at 78% in dark (the system gray falls to about 3:1 there).
    static let surfaceSecondary = ModeColor(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.68, darkAlpha: 0.78)

    // MARK: Report buttons (a white glyph on each)

    /// The other report tints are the shared fills: warningFill, criticalFill, MapColors.ok, neutralFill, accentFill.
    static let reportBrown = ModeColor(light: 0x8A6B45, dark: 0x8A6B45)

    /// What a white glyph sits on; the contrast test walks these.
    static let underWhite: [ModeColor] = [
        accentFill, warningFill, criticalFill, neutralFill, MapColors.ok, reportBrown,
    ]
}

extension Color {
    static let ikutAccentFill = Palette.accentFill.color
    static let ikutRoute = Palette.route.color
    static let ikutRouteCasing = Palette.routeCasing.color
    static let ikutJoining = Palette.joining.color
    static let ikutBannerDark = Palette.bannerDark.color
    static let surfaceTileFill = Palette.surfaceTileFill.color
}

// MARK: - Elevation

/// A drop shadow: two values. A marker-sized thing (pins, markers, badges, labels, the small round buttons) and a
/// floating surface (panel, pill, banner, welcome card).
enum Elevation: CaseIterable {
    case marker
    case floating

    var opacity: Double { self == .marker ? 0.175 : 0.15 }
    var radius: CGFloat { self == .marker ? 2.5 : 11 }
    var y: CGFloat { self == .marker ? 1 : 6 }
}

extension View {
    func elevation(_ e: Elevation) -> some View {
        shadow(color: .black.opacity(e.opacity), radius: e.radius, y: e.y)
    }
}

// MARK: - Tinted fills

/// How much of a colour a chip, banner or wash is filled with: a wash (6%) and one tint (14%).
enum TintFill {
    case wash, tint

    var amount: Double {
        switch self {
        case .wash: 0.06
        case .tint: 0.14
        }
    }
}

extension Color {
    func fill(_ amount: TintFill) -> Color { opacity(amount.amount) }
}
