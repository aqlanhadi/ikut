#if DEBUG
import CoreLocation
import FirebaseFirestore
import SwiftUI

/// `IKUT_SCREEN=slot-stop-approach`: the map with the planned-stop pill up, 1.9 km short of R&R Tapah (fuel,
/// 20 min). `stop-approach-food` is the same for a food stop in a town ("Lunch, Ipoh Lama"). No sound.
@MainActor
enum StopApproachDemo {
    private final class Silent: AlertAnnouncing {
        func announce(event: TripEvent, distance: Double?) async -> Bool { false }
        func announce(alert: TripAlert) -> Bool { true }
    }

    private static var announcer: Silent?

    static func view(food: Bool = false) -> some View {
        Backend.configure()
        let model = MapDemo.model()
        let main = RouteLine(MapDemo.densify(MapDemo.mainWaypoints))
        let lead = model.convoy.convoy.first?.convoyOffset ?? 0
        let spot = main.coordinate(atOffset: lead + 1_900) ?? main.coordinates[0]
        let stop = PlannedStop(
            id: "demo-stop", name: food ? "Lunch, Ipoh Lama" : "R&R Tapah",
            coordinate: GeoPoint(latitude: spot.latitude, longitude: spot.longitude), routeOffset: lead + 1_900,
            kind: food ? .food : .fuel, minutes: food ? 45 : 20, order: 0)
        let silent = Silent()
        announcer = silent
        model.startHazardAlerts(announcer: silent, userId: "u-c1", tripId: "demo")
        model.setStops([stop])
        model.setCars(model.cars)
        return NavigationStack {
            TripScreenHost(mode: .driving) { TripMapView(session: TripSession(tripId: "demo", userId: "u-c1"), model: model,
                        stopService: DemoStopService()) }
        }
    }

    /// The organizer's map once the route was rebuilt mid-trip (D25 4d), or while the rebuild waits for signal.
    static func routeNotice(waiting: Bool) -> some View {
        Backend.configure()
        let model = MapDemo.model()
        model.setCars(model.cars)
        let session = TripSession(tripId: "demo", userId: "u-c1")
        session.rebuilder.showForDemo(RouteRebuilder.Notice(
            text: waiting ? RouteRebuilder.waitingLine : RouteRebuild.sentence(through: ["R&R Tapah", "Ipoh"]),
            waiting: waiting))
        return NavigationStack {
            TripScreenHost(mode: .driving) { TripMapView(session: session, model: model, stopService: DemoStopService()) }
        }
    }
}
#endif
