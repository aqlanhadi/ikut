#if DEBUG
import SwiftUI

/// Launch states for the Join ticket (`IKUT_SCREEN=join-stops`, `join-no-stops`, `join-with-location`, `join-without-location`).
@MainActor
enum JoinDemo {
    private struct API: JoinAPI {
        var withStops: Bool
        var withCoordinate = true
        /// When set, the ticket can't be read and says this.
        var failure: String?

        func preview(code: String) async throws -> TripPreview {
            if let failure { throw JoinError(message: failure) }
            return TripPreview(
                tripId: "demo", name: "Balik kampung raya", destinationName: "Ipoh",
                destinationCoordinate: withCoordinate ? PreviewCoordinate(latitude: 4.5975, longitude: 101.09) : nil,
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

    /// The fixed-data API, for previews: a ticket with stops for any code, or `failure` when set.
    static func api(withStops: Bool = false, failure: String? = nil) -> some JoinAPI {
        API(withStops: withStops, withCoordinate: false, failure: failure)
    }

    /// `drive` is what MapKit would answer from the phone's location; nil is a phone without location.
    static func ticket(withStops: Bool, drive: TicketDrive? = nil) -> some View {
        JoinTripView(
            model: JoinModel(
                displayName: "Daniel", initialCode: "K7M2QX", api: API(withStops: withStops, withCoordinate: drive != nil),
                driveFromHere: { _ in drive })
        ) { _, _ in }
    }
}
#endif
