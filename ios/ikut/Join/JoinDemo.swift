#if DEBUG
import SwiftUI

/// Launch states for the Join ticket (`IKUT_SCREEN=join-stops`, `join-no-stops`).
@MainActor
enum JoinDemo {
    private struct API: JoinAPI {
        var withStops: Bool

        func preview(code: String) async throws -> TripPreview {
            TripPreview(
                tripId: "demo", name: "Balik kampung raya", destinationName: "Ipoh",
                cars: [
                    PreviewCar(id: "c1", name: "Aqlan’s Myvi", color: "#2563EB", hasTracker: true, number: 1),
                    PreviewCar(id: "c2", name: "Wyna’s X70", color: "#D9480F", hasTracker: true, number: 2),
                ],
                stops: withStops
                    ? [
                        PreviewStop(name: "Petronas Sungai Buloh", kind: .meet),
                        PreviewStop(name: "R&R Tapah", kind: .fuel, minutes: 20),
                        PreviewStop(name: "Kuala Kangsar", kind: .food, minutes: 60),
                    ] : [])
        }

        func join(code: String, displayName: String, car: JoinCarChoice, tracker: Bool) async throws -> JoinResult {
            JoinResult(tripId: "demo", carId: "c2", trackerTaken: false)
        }
    }

    static func ticket(withStops: Bool) -> some View {
        JoinTripView(model: JoinModel(displayName: "Daniel", initialCode: "K7M2QX", api: API(withStops: withStops))) { _, _ in }
    }
}
#endif
