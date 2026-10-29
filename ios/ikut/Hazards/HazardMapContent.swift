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
            .elevation(.marker)
            .background { if pinging { HazardPing(color: marker.tone.fill) } }
            .overlay(alignment: .leading) {
                if showsChip {
                    Text(marker.chipText)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, Spacing.s)
                        .padding(.vertical, Spacing.xs)
                        .background(.regularMaterial, in: Capsule())
                        .elevation(.marker)
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

/// Rings spreading out from the marker and fading, one after the other, for a few seconds after the approach pill
/// comes up (`HazardPingTiming`); then the marker stands still. With Reduce Motion, one ring that stays put.
private struct HazardPing: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var done = false

    var body: some View {
        if reduceMotion {
            ring(phase: 0.3)
        } else if !done {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                ZStack {
                    ForEach(Array(HazardPingTiming.rings(elapsed: context.date.timeIntervalSince(start)).enumerated()),
                            id: \.offset) { _, phase in ring(phase: phase) }
                }
            }
            // The timeline goes once the last ring has faded, so nothing keeps drawing (or keeps the app busy).
            .task {
                try? await Task.sleep(for: .seconds(HazardPingTiming.duration))
                done = true
            }
        }
    }

    /// 0 at the marker's edge, 1 at three times its size and gone.
    private func ring(phase: Double) -> some View {
        Circle()
            .fill(color.dimmed(.soft))
            .overlay(Circle().strokeBorder(color, lineWidth: 2))
            .scaleEffect(1 + 2 * phase)
            .opacity(1 - phase)
            .accessibilityHidden(true)
    }
}

/// When the hazard ping's rings show (D70): three pings of two rings, a ring every 0.8 s, each spreading for 1.6 s,
/// so the ping is over 5.6 s after the pill came up. Three pings draw the eye to the hazard as the pill arrives;
/// after that the pill and the marker say where it is, and a ring pulsing until the hazard is passed (up to a
/// minute or more) only pulls the eye back to the screen while driving.
enum HazardPingTiming {
    static let period: TimeInterval = 1.6
    static let ringsPerPeriod = 2
    static let pings = 3
    private static var ringCount: Int { pings * ringsPerPeriod }
    private static var gap: TimeInterval { period / Double(ringsPerPeriod) }
    /// From the first ring to the last one gone.
    static var duration: TimeInterval { Double(ringCount - 1) * gap + period }

    /// How far out each ring that shows is, 0 (at the marker) to under 1 (gone), `elapsed` seconds in.
    static func rings(elapsed: TimeInterval) -> [Double] {
        (0..<ringCount).compactMap { index in
            let phase = (elapsed - Double(index) * gap) / period
            return phase >= 0 && phase < 1 ? phase : nil
        }
    }
}

extension HazardTone {
    /// High is the hazard yellow (the lead star's too); medium the system orange; low a grey dark enough for a
    /// white glyph.
    var fill: Color {
        switch self {
        case .high: .yellow
        case .medium: .orange
        case .low: Color.neutralFill
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
