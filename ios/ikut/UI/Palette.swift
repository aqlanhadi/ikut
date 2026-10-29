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
    static let staleChipText = ModeColor(light: 0xB02800, dark: 0xFF9F0A)

    // MARK: Status

    /// Teal of a car that is still joining the convoy; the meeting point wears it too.
    static let joining = ModeColor(light: 0x0F756E, dark: 0x2ED4BF)

    // MARK: Surfaces

    /// The floating banners (alert, report toast), dark in both modes: #1C1C1E on the canvas.
    static let bannerDark = ModeColor(light: 0x1C1C1C, dark: 0x1C1C1C)
    /// Light: a milky white; dark: a faint lift. Both let the glass behind show.
    static let surfaceTileFill = ModeColor(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.5, darkAlpha: 0.10)
    /// Secondary text on glass: black at 68% in light, white at 78% in dark (the system gray falls to about 3:1 there).
    static let surfaceSecondary = ModeColor(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.68, darkAlpha: 0.78)
    /// The number disc of a stop suggestion that isn't picked, under a white digit.
    static let unselectedDisc = ModeColor(light: 0x8F8F94, dark: 0x8F8F94)

    // MARK: Report buttons (a white glyph on each)

    static let reportOrange = ModeColor(light: 0xC93300, dark: 0xC93300)
    static let reportRed = ModeColor(light: 0xD60014, dark: 0xD60014)
    static let reportBrown = ModeColor(light: 0x8A6B45, dark: 0x8A6B45)
    static let reportGreen = ModeColor(light: 0x1F7A36, dark: 0x1F7A36)
    static let reportGray = ModeColor(light: 0x636366, dark: 0x636366)
    static let reportBlue = ModeColor(light: 0x0070E3, dark: 0x0070E3)

    /// What a white glyph sits on; the contrast test walks these.
    static let underWhite: [ModeColor] = [
        accentFill, reportOrange, reportRed, reportBrown, reportGreen, reportGray, reportBlue,
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

    var opacity: Double {
        switch self {
        case .panel: 0.16
        case .pill: 0.12
        case .welcome: 0.14
        case .homeButton: 0.15
        case .pin: 0.25
        case .marker: 0.25
        case .hazardDot: 0.15
        case .banner: 0.22
        case .badge: 0.2
        case .label: 0.12
        }
    }

    var radius: CGFloat {
        switch self {
        case .panel: 20
        case .pill: 12
        case .welcome: 9
        case .homeButton: 3
        case .pin: 3
        case .marker: 4
        case .hazardDot: 2
        case .banner: 10
        case .badge: 1.5
        case .label: 2
        }
    }

    var y: CGFloat {
        switch self {
        case .panel: 10
        case .pill: 6
        case .welcome: 3
        case .homeButton: 1
        case .pin: 2
        case .marker: 2
        case .hazardDot: 1
        case .banner: 6
        case .badge: 1
        case .label: 1
        }
    }
}

extension View {
    func elevation(_ e: Elevation) -> some View {
        shadow(color: .black.opacity(e.opacity), radius: e.radius, y: e.y)
    }
}

// MARK: - Tinted fills

/// How much of a colour a chip, banner or wash is filled with: one case per opacity the app uses.
enum TintFill: Double {
    case wash = 0.06
    case faint = 0.10
    case soft = 0.12
    case chip = 0.14
    case onDark = 0.16
    case strong = 0.18
}

extension Color {
    func fill(_ amount: TintFill) -> Color { opacity(amount.rawValue) }
}
