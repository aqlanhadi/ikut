import SwiftUI

/// The Live Activity's colours and sizes. The card is always dark (the island is black either way), so these are fixed
/// values from LiveActivity.dc.html, not the app's light and dark Color Sets (those live in the app's asset catalog,
/// which the extension does not carry). Car colours come from the car itself.
enum ActivityPalette {
    static let accent = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)
    static let positive = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
    static let yellow = Color(red: 255 / 255, green: 204 / 255, blue: 0)
    static let orange = Color(red: 255 / 255, green: 159 / 255, blue: 10 / 255)
    static let grey = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)
    static let secondary = Color.white.opacity(0.6)
    static let line = Color.white.opacity(0.82)
    static let card = Color(red: 20 / 255, green: 20 / 255, blue: 24 / 255).opacity(0.86)
    static let smallCard = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    /// The gap the track's bar and car circles are drawn against.
    static let trackGap = Color(red: 20 / 255, green: 20 / 255, blue: 24 / 255)

    /// "#D9480F" as a colour; nil for anything else.
    static func hex(_ string: String) -> Color? {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return Color(red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255)
    }
}

/// Points: the card's margins and the glyph sizes the design fixes.
enum ActivitySize {
    static let cardRadius: CGFloat = 22
    static let cardInsets = EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16)
    static let gap: CGFloat = 10
    static let badge: CGFloat = 26
    static let expandedBadge: CGFloat = 28
    static let mark: CGFloat = 20
    static let compactGlyph: CGFloat = 18
    static let alertGlyph: CGFloat = 22
    static let minimalMark: CGFloat = 22
    static let minimalAlertGlyph: CGFloat = 20
    static let trackHeight: CGFloat = 20
}

/// The track's sizes, all from the bar's height so the bar, the dots and the marks read as one drawing (D3 note 18):
/// the end dots are the bar's own height and gap, car circles and the stop ring share one ring width and one base
/// size, my car is one size step bigger (a ring width more on every side), and the hazard diamond's corners reach the
/// same base size. `ActivityTrackMetricsTests` pins the rules.
enum ActivityTrackMetrics {
    /// The bar's thickness: the unit everything else is a multiple of.
    static let bar: CGFloat = 4
    /// The ring around a car, the stop ring's stroke: half the bar.
    static let ring: CGFloat = bar / 2
    /// The coloured disc of another car, inside its ring.
    static let disc: CGFloat = bar * 2.5
    /// Another car, the stop ring and the hazard diamond's corner to corner, rings included.
    static let base: CGFloat = disc + 2 * ring
    /// My car: one step bigger, the disc grown by the ring on every side.
    static let mine: CGFloat = base + 2 * ring
    /// The hazard diamond's side, so its corners reach `base`.
    static let diamondSide: CGFloat = base / 2.0.squareRoot()
    /// The row of dots at each end: the bar's height, the bar's gap, fading away from the bar.
    static let endDots = 3
    static let endDotSize: CGFloat = bar
    static let endSpacing: CGFloat = bar
    /// The unfilled bar's white, and each end dot's share of the bar colour it continues, nearest the bar first.
    static let trackOpacity = 0.2
    static let endFade: [Double] = [1, 0.7, 0.4]
    static let dimmedOpacity = 0.5

    static func carSize(isMine: Bool) -> CGFloat { isMine ? mine : base }
}

/// The bare ikut mark, no disc or tile (decision #713): the route, the followers, the joiner and the lead arrow, redrawn on
/// the 1024 grid of the app icon's source layers (`ikut.icon`: route, followers, joiner, lead-dark).
struct IkutMark: View {
    var size: CGFloat = ActivitySize.mark

    var body: some View {
        Canvas { context, canvas in
            let k = min(canvas.width, canvas.height) / 1024
            context.scaleBy(x: k, y: k)
            var route = Path()
            route.move(to: CGPoint(x: 332, y: 830))
            route.addLine(to: CGPoint(x: 332, y: 580))
            route.addQuadCurve(to: CGPoint(x: 388, y: 474), control: CGPoint(x: 332, y: 512))
            route.addLine(to: CGPoint(x: 684, y: 246))
            context.stroke(route, with: .color(ActivityPalette.accent), style: StrokeStyle(lineWidth: 30, lineCap: .round, lineJoin: .round))
            for (x, y, r, fill) in [
                (332.0, 680.0, 52.0, ActivityPalette.accent), (500, 388, 52, ActivityPalette.accent),
                (561, 711, 54, Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)),
            ] {
                let dot = Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                context.fill(dot, with: .color(fill))
                context.stroke(dot, with: .color(.white), lineWidth: 14)
            }
            context.fill(Path(ellipseIn: CGRect(x: 684 - 94, y: 246 - 94, width: 188, height: 188)), with: .color(.white))
            var arrow = Path()
            arrow.move(to: CGPoint(x: 12, y: 2))
            arrow.addLine(to: CGPoint(x: 20, y: 21))
            arrow.addLine(to: CGPoint(x: 12, y: 17))
            arrow.addLine(to: CGPoint(x: 4, y: 21))
            arrow.closeSubpath()
            var lead = context
            lead.translateBy(x: 684, y: 246)
            lead.rotate(by: .degrees(52))
            lead.scaleBy(x: 4.8, y: 4.8)
            lead.translateBy(x: -12, y: -11.5)
            lead.fill(arrow, with: .color(ActivityPalette.accent))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("ikut")
    }
}

/// A state's glyph in its colour, for the compact island, the minimal one and `.small`.
struct ActivityGlyph: View {
    let words: ActivityWords
    var size: CGFloat = ActivitySize.compactGlyph

    var body: some View {
        Image(systemName: words.symbol)
            .font(.system(size: size * 0.9, weight: .semibold))
            .foregroundStyle(words.tint)
            .frame(width: size, height: size)
    }
}

/// The filled round badge of the Lock Screen and the expanded island.
struct ActivityBadge: View {
    let words: ActivityWords
    var size: CGFloat = ActivitySize.badge

    var body: some View {
        Image(systemName: words.symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(words.onTint)
            .frame(width: size, height: size)
            .background(words.tint, in: Circle())
    }
}
