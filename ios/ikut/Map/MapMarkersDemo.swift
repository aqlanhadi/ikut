#if DEBUG
import FirebaseFirestore
import SwiftUI

/// The map's markers on a grey ground (D34, `IKUT_SCREEN=road-markers`): a car of every kind (lead, joining,
/// stale with its clock, paused, arrived), a hazard of each severity with its chip, the planned-stop pill's
/// OK button, and the planned-stop banner's blue. Check at the default and an accessibility text size, in
/// light and dark.
struct MapMarkersDemo: View {
    private func car(_ id: String, _ number: Int?, _ name: String, _ color: String, heading: Double? = 20,
                     stale: Bool = false, age: String? = nil, lead: Bool = false, joining: Bool = false,
                     mine: Bool = false, paused: Bool = false, arrived: Bool = false) -> MapMarker {
        MapMarker(
            id: id, number: number, name: name, colorHex: color,
            coordinate: MapCoordinate(latitude: 4.2, longitude: 101.26), heading: heading, isStale: stale,
            ageText: age, isLead: lead, isJoining: joining, isMine: mine, isPaused: paused, hasArrived: arrived)
    }

    private func hazard(_ type: EventType, _ severity: Severity, minutes: Int) -> HazardMarker {
        let now = Date()
        var event = TripEvent(
            type: type, location: GeoPoint(latitude: 3, longitude: 101), heading: 0, routeOffset: 0,
            authorId: "u", carId: "c", createdAt: now.addingTimeInterval(TimeInterval(-minutes * 60)))
        event.severity = severity
        return HazardMarker(event: event, mainOffset: nil, now: now)
    }

    var body: some View {
        let cars = [
            car("c1", 1, "Aqlan’s Myvi", "#2563EB", lead: true, mine: true),
            car("c2", 2, "Wyna’s X70", "#D9480F", heading: 200),
            car("c3", 3, "Hafiz’s Hilux", "#0F766E", heading: 90, joining: true),
            car("c4", 4, "Daniel’s City", "#7C3AED", stale: true, age: "2 min ago"),
            car("c5", 5, "Siti’s Bezza", "#CA8A04", heading: nil, stale: true, paused: true),
            car("c6", 6, "Aisha’s Ativa", "#0891B2", heading: nil, arrived: true),
        ]
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                ForEach(cars) { MapMarkerView(marker: $0, cameraHeading: 0, containerWidth: 390) }
                HStack(spacing: 120) {
                    HazardMapContent(marker: hazard(.debris, .high, minutes: 4))
                    HazardMapContent(marker: hazard(.heavyRain, .medium, minutes: 1))
                }
                .padding(.leading, 100)
                HazardMapContent(marker: hazard(.message, .low, minutes: 20))
                    .padding(.leading, 100)
                Text("OK")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(Color.ikutOK, in: Capsule())
                Image(systemName: "fuelpump.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(width: 40, height: 40)
                    .background(Color.ikutPillBlue, in: Circle())
                    .padding(Spacing.s)
                    .background(Color(white: 0.11), in: Capsule())
                StopReasonIcon(symbol: "fork.knife", size: 40)
            }
            .padding(Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.systemGray5))
    }
}
#endif
