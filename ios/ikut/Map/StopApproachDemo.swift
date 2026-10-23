#if DEBUG
import CoreLocation
import FirebaseFirestore
import SwiftUI

/// `IKUT_SCREEN=stop-approach`: the map with the planned-stop pill up, 1.9 km short of R&R Tapah (fuel,
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
            TripMapView(session: TripSession(tripId: "demo", userId: "u-c1"), model: model,
                        stopService: DemoStopService())
        }
    }
}
#endif
