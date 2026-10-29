import SwiftUI
import UIKit

/// The map's own named colours (D34) are Color Sets in Assets.xcassets/Colors: `ikutOK` (the stop pill's OK button
/// under a white label), `ikutPillBlue` (the planned-stop pill, and the accent for an icon on a glass surface in
/// dark; black glyph on it) and `destinationPin` (the lobby's destination pin, lifted in dark). Where a system colour
/// is the same thing (`.yellow`, `.orange`, `.green`) the code uses that instead.

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
