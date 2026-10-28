#if DEBUG
import CoreLocation
import SwiftUI

/// Fixed-data trips for the join steps' launch states and previews.
@MainActor
enum JoinDemo {
    private struct API: JoinAPI {
        var withStops: Bool
        var withCoordinate = true
        var withRoute = false
        /// When set, the ticket can't be read and says this.
        var failure: String?
        /// The lookup, or the join, never answers: the spinner stays.
        var lookupHangs = false
        var joinHangs = false

        func preview(code: String) async throws -> TripPreview {
            if lookupHangs { try await Task.sleep(for: .seconds(86_400)) }
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
                        PreviewStop(
                            name: "Petronas Jalan Duta", kind: .meet,
                            coordinate: PreviewCoordinate(latitude: 3.1873, longitude: 101.6773),
                            meetAt: Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())),
                        PreviewStop(name: "R&R Tapah", kind: .fuel, minutes: 20,
                                    coordinate: PreviewCoordinate(latitude: 4.2, longitude: 101.26)),
                        PreviewStop(name: "Kuala Kangsar", kind: .food, minutes: 60,
                                    coordinate: PreviewCoordinate(latitude: 4.77, longitude: 100.94)),
                    ] : [],
                organizerName: withRoute ? "Aqlan" : nil,
                route: withRoute ? Polyline.encode(JoinDemo.route) : nil)
        }

        func join(code: String, displayName: String, car: JoinCarChoice, tracker: Bool) async throws -> JoinResult {
            if joinHangs { try await Task.sleep(for: .seconds(86_400)) }
            return JoinResult(tripId: "demo", carId: "c2", trackerTaken: false)
        }
    }

    /// From the meeting point north to Ipoh: the trip's line as the server sends it (never from anyone's start).
    private nonisolated static var route: [CLLocationCoordinate2D] { [
        (3.1873, 101.6773), (3.4, 101.62), (3.8, 101.5), (4.0, 101.38), (4.2, 101.26), (4.45, 101.12), (4.5975, 101.09),
    ].map { CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1) } }

    /// The fixed-data API, for previews: a ticket with stops for any code, or `failure` when set.
    static func api(withStops: Bool = false, failure: String? = nil) -> some JoinAPI {
        API(withStops: withStops, withCoordinate: false, failure: failure)
    }

    /// Home with the join steps over its map, for the launch states `join-h1-name`, `join-h2-location`, `join-h3-empty`, `join-h3-found`, `join-h3-found-drive`,
    /// `join-h3-not-found`, `join-h4-car`, `join-h4-copilot` and `join-h4-own` (D58). The found states look the trip up
    /// from the fixed-data API a moment after they open, as the real one does.
    static func home(_ state: String) -> TripsHomeView? {
        guard state.hasPrefix("join-h") || state == "join-location-off" else { return nil }
        let drive = state == "join-h3-found-drive"
            ? TicketDrive(distance: 185_000, travelTime: 2 * 3600 + 10 * 60) : nil
        let code: String? = state == "join-h3-empty" ? nil : "K7M2QX"
        let failure = state == "join-h3-not-found" ? JoinService.message(code: .notFound, serverMessage: "")
            : state == "join-h3-no-signal" ? JoinService.message(code: .unavailable, serverMessage: "") : nil
        let model = JoinModel(
            displayName: "Nurul", initialCode: code,
            api: API(withStops: true, withCoordinate: true, withRoute: true, failure: failure,
                     lookupHangs: state == "join-h3-looking", joinHangs: state == "join-h4-joining"),
            driveFromHere: { _ in drive })
        if state == "join-h1-name" { model.displayName = "" }
        // H1 and H2 come first for a person with no name and no answer to iOS yet; the other states are for someone with both.
        let plan = state == "join-h1-name" ? JoinPlan(needsName: true, needsLocation: true)
            : state == "join-h2-location" ? JoinPlan(needsName: false, needsLocation: true) : JoinPlan()
        let stepper = JoinStepper(model: model, plan: plan)
        if state.hasPrefix("join-h4") || state == "join-location-off" {
            stepper.show(.car)
            Task { @MainActor in
                for _ in 0..<100 where model.preview == nil { try? await Task.sleep(for: .milliseconds(50)) }
                switch state {
                case "join-h4-copilot": if let car = model.cars.first { model.select(car) }
                case "join-h4-own", "join-location-off": model.selectNewCar()
                case "join-h4-joining":
                    if let car = model.cars.first { model.select(car) }
                    _ = await model.join(sharing: false)
                default: break
                }
            }
        }
        return TripsHomeView(demo: [], routes: [], joining: stepper)
    }
}
#endif
