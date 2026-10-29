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
    /// Stale-car chip text: the warning red on light, a lighter orange on dark so it stays legible.
    static let staleChipText = warningText

    // MARK: Status

    /// Accent text and icons: a touch darker in light than the 0071E3 fill so it holds 4.5:1 on a screen and on its own 14% tint.
    static let accentText = ModeColor(light: 0x005FBF, dark: 0x2997FF)
    /// Positive status text, same test.
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
    /// The number disc of a stop suggestion that isn't picked, under a white digit (the neutral fill, 4.5:1).
    static let unselectedDisc = neutralFill

    // MARK: Report buttons (a white glyph on each)

    static let reportOrange = warningFill
    static let reportRed = criticalFill
    static let reportBrown = ModeColor(light: 0x8A6B45, dark: 0x8A6B45)
    static let reportGreen = MapColors.ok
    static let reportGray = neutralFill
    static let reportBlue = accentFill

    /// What a white glyph sits on; the contrast test walks these.
    static let underWhite: [ModeColor] = [
        accentFill, warningFill, criticalFill, neutralFill, MapColors.ok, reportOrange, reportRed, reportBrown, reportGreen, reportGray, reportBlue,
    ]
}

extension Color {
    static let ikutAccentFill = Palette.accentFill.color
    static let ikutRoute = Palette.route.color
    static let ikutRouteCasing = Palette.routeCasing.color
    static let ikutStaleChipText = Palette.staleChipText.color
    /// The system green.
    static let ikutLive = Color.green
    static let ikutJoining = Palette.joining.color
    static let ikutBannerDark = Palette.bannerDark.color
    static let surfaceTileFill = Palette.surfaceTileFill.color
    static let ikutUnselectedDisc = Palette.unselectedDisc.color
}

// MARK: - Elevation

/// A drop shadow, one case per value the app draws (they differ on purpose: a pin is not a panel).
enum Elevation: CaseIterable {
    /// The convoy panel and stop card before glass.
    case panel
    /// The trip pill, the map's buttons, the stop pill, the driving glance.
    case pill
    /// The welcome screen's card.
    case welcome
    /// The small round buttons on the home map.
    case homeButton
    /// A pin over the map (home, lobby).
    case pin
    /// A hazard marker and a car marker.
    case marker
    /// The hazard's inner dot.
    case hazardDot
    /// The floating dark banner.
    case banner
    /// A car's number badge in the convoy list.
    case badge
    /// A car marker's label chip.
    case label

    /// D78: two shadows. A marker-sized thing (pins, markers, badges, labels, the small round buttons) and a
    /// floating surface (panel, pill, banner, welcome card), each at the middle of what its group drew before.
    private var isMarker: Bool {
        switch self {
        case .homeButton, .pin, .marker, .hazardDot, .badge, .label: true
        case .panel, .pill, .welcome, .banner: false
        }
    }

    var opacity: Double { isMarker ? 0.175 : 0.15 }
    var radius: CGFloat { isMarker ? 2.5 : 11 }
    var y: CGFloat { isMarker ? 1 : 6 }
}

extension View {
    func elevation(_ e: Elevation) -> some View {
        shadow(color: .black.opacity(e.opacity), radius: e.radius, y: e.y)
    }
}

// MARK: - Tinted fills

/// How much of a colour a chip, banner or wash is filled with: one case per opacity the app uses.
enum TintFill {
    case wash, faint, soft, chip, onDark, strong

    /// D78: a wash (6%) and one tint (14%); the cases keep their names until the call sites are merged.
    var amount: Double { self == .wash ? 0.06 : 0.14 }
}

extension Color {
    func fill(_ amount: TintFill) -> Color { opacity(amount.amount) }
}
