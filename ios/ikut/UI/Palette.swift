import SwiftUI
import UIKit

// Every colour of ours is a named Color Set in Assets.xcassets/Colors (D87): a value for light and one for dark,
// drawn through the generated asset symbols (`Color.ikutAccent`, `Color.neutralFill`, ...). Nothing in Swift holds
// a colour number. The contrast tests read the resolved values back out of the catalog.

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

// MARK: - Dimmed

/// How faded a thing is when it is fainter than its neighbours (a muted line on a dark banner, a track, a halo, a
/// waiting dot): three steps, so nothing invents its own number. Colours of the system's own hierarchy
/// (`.secondary`, `.tertiary`) are used first; this is for the rest.
enum Dimmed {
    /// A track, a halo, a ring behind a marker.
    case soft
    /// A muted line or circle on a dark surface, a pressed-looking fill.
    case faded
    /// Almost full: a label's backing, a casing, a tile.
    case strong

    var amount: Double {
        switch self {
        case .soft: 0.3
        case .faded: 0.7
        case .strong: 0.9
        }
    }
}

extension Color {
    func dimmed(_ level: Dimmed) -> Color { opacity(level.amount) }
}

extension View {
    func dimmed(_ level: Dimmed) -> some View { opacity(level.amount) }
}
