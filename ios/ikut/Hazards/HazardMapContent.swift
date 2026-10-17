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

    private static let size: CGFloat = 32

    var body: some View {
        Image(systemName: marker.symbol)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(marker.tone.symbolColor)
            .frame(width: Self.size, height: Self.size)
            .background(marker.tone.fill, in: Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .overlay(alignment: .leading) {
                if showsChip {
                    Text(marker.chipText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                        // To the left of the circle, as in the mockup: a zero-width box at the circle's
                        // leading edge, with the chip hanging off its trailing side.
                        .padding(.trailing, 8)
                        .frame(width: 0, alignment: .trailing)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(marker.accessibilityLabel)
    }
}

extension HazardTone {
    /// High is the mockup's hazard yellow; medium orange; low grey.
    var fill: Color {
        switch self {
        case .high: Color(red: 1, green: 0.8, blue: 0)
        case .medium: Color(red: 1, green: 0.58, blue: 0)
        case .low: Color(red: 0.56, green: 0.56, blue: 0.58)
        }
    }

    var symbolColor: Color {
        switch self {
        case .high: .black
        case .medium, .low: .white
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
