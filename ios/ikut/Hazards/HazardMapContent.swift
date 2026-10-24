import FirebaseFirestore
import SwiftUI

/// What the map draws for one hazard: a symbol in a severity-coloured circle, with a chip
/// ("Debris · 4 min ago") to its left. Use inside `Annotation`:
///
///     Annotation(marker.label, coordinate: marker.coordinate) { HazardMapContent(marker: marker) }
///
/// The chip is an overlay, so the circle stays centred on the coordinate (the default anchor).
struct HazardMapContent: View {
    let marker: HazardMarker
    var showsChip = true
    /// Rings spread out from it while its approach alert is up.
    var pinging = false

    @ScaledMetric(relativeTo: .subheadline) private var textScale: CGFloat = 1
    private var scale: CGFloat { MarkerMetrics.scale(textScale) }
    private var size: CGFloat { 32 * scale }

    var body: some View {
        Image(systemName: marker.symbol)
            .font(.system(size: 14 * scale, weight: .bold))
            .foregroundStyle(marker.tone.symbolColor)
            .frame(width: size, height: size)
            .background(marker.tone.fill, in: Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .background { if pinging { HazardPing(color: marker.tone.fill) } }
            .overlay(alignment: .leading) {
                if showsChip {
                    Text(marker.chipText)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, Spacing.s)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                        // To the left of the circle, as in the mockup: a zero-width box at the circle's
                        // leading edge, with the chip hanging off its trailing side.
                        .padding(.trailing, Spacing.s)
                        .frame(width: 0, alignment: .trailing)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(marker.accessibilityLabel)
    }
}

/// Two rings spreading out from the marker and fading, one after the other. With Reduce Motion,
/// one ring that stays put.
private struct HazardPing: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let period = 1.6

    var body: some View {
        if reduceMotion {
            ring(phase: 0.3)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate / Self.period
                ZStack {
                    ring(phase: phase.truncatingRemainder(dividingBy: 1))
                    ring(phase: (phase + 0.5).truncatingRemainder(dividingBy: 1))
                }
            }
        }
    }

    /// 0 at the marker's edge, 1 at three times its size and gone.
    private func ring(phase: Double) -> some View {
        Circle()
            .fill(color.opacity(0.3))
            .overlay(Circle().strokeBorder(color, lineWidth: 2))
            .scaleEffect(1 + 2 * phase)
            .opacity(1 - phase)
            .accessibilityHidden(true)
    }
}

extension HazardTone {
    /// High is the hazard yellow (the lead star's too); medium the system orange; low a grey dark enough for a
    /// white glyph.
    var fill: Color {
        switch self {
        case .high: .ikutLeadYellow
        case .medium: .orange
        case .low: MapColors.hazardLow.color
        }
    }

    /// Black on the bright fills, white on the grey: 4.5:1 or better in both modes.
    var symbolColor: Color {
        switch self {
        case .high, .medium: .black
        case .low: .white
        }
    }
}

#Preview {
    func marker(_ type: EventType, _ severity: Severity, minutes: Int) -> HazardMarker {
        let now = Date()
        var event = TripEvent(
            type: type, location: GeoPoint(latitude: 3, longitude: 101), heading: 0, routeOffset: 0,
            authorId: "u", carId: "c", createdAt: now.addingTimeInterval(TimeInterval(-minutes * 60)))
        event.severity = severity
        return HazardMarker(event: event, mainOffset: nil, now: now)
    }
    return HStack(alignment: .top, spacing: 36) {
        HazardMapContent(marker: marker(.debris, .high, minutes: 4))
        HazardMapContent(marker: marker(.heavyRain, .medium, minutes: 1))
        HazardMapContent(marker: marker(.message, .low, minutes: 20), showsChip: false)
    }
    .padding(.horizontal, 60)
    .padding(.vertical, 60)
    .background(Color(.systemGray5))
}
