#if DEBUG
import SwiftUI

/// Fixed-data trips for the join steps' launch states and previews.
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

    /// Home with the join steps over its map, for the launch states `join-h3-empty`, `join-h3-found`, `join-h3-found-drive`,
    /// `join-h3-not-found`, `join-h4-car`, `join-h4-copilot` and `join-h4-own` (D58). The found states look the trip up
    /// from the fixed-data API a moment after they open, as the real one does.
    static func home(_ state: String) -> TripsHomeView? {
        guard state.hasPrefix("join-h") else { return nil }
        let drive = state == "join-h3-found-drive"
            ? TicketDrive(distance: 185_000, travelTime: 2 * 3600 + 10 * 60) : nil
        let code: String? = state == "join-h3-empty" ? nil : "K7M2QX"
        let failure = state == "join-h3-not-found" ? JoinService.message(code: .notFound, serverMessage: "") : nil
        let model = JoinModel(
            displayName: "Nurul", initialCode: code,
            api: API(withStops: true, withCoordinate: true, failure: failure), driveFromHere: { _ in drive })
        let stepper = JoinStepper(model: model)
        if state.hasPrefix("join-h4") {
            stepper.show(.car)
            Task { @MainActor in
                for _ in 0..<100 where model.preview == nil { try? await Task.sleep(for: .milliseconds(50)) }
                switch state {
                case "join-h4-copilot": if let car = model.cars.first { model.select(car) }
                case "join-h4-own": model.selectNewCar()
                default: break
                }
            }
        }
        return TripsHomeView(demo: [], routes: [], joining: stepper)
    }
}
#endif
