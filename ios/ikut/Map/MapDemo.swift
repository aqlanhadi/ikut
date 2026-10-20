#if DEBUG
import CoreLocation
import FirebaseFirestore
import SwiftUI

/// The Map.dc.html scenario on the real KL-Ipoh E1 route, for previews and the screenshot test:
/// three cars in the convoy near Tapah and Bidor (the last one stale), and Hafiz from Teluk Intan
/// joining at Bidor on his own route.
///
/// To see it in the simulator, run the `MapDemoScreenshot` test with
/// `TEST_RUNNER_IKUT_MAP_DEMO_HOLD=<seconds>`: it hosts `MapDemo.view()` in a window and waits, so
/// `xcrun simctl io <device> screenshot` can capture it. Nothing in the app launches it.
@MainActor
enum MapDemo {
    private struct FixedETA: ETAProviding {
        var seconds: TimeInterval
        func travelTime(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> TimeInterval { seconds }
    }

    /// E1 north: Tanjung Malim, Slim River, Sungkai, Bidor, Tapah, Gopeng, Ipoh.
    static let mainWaypoints: [CLLocationCoordinate2D] = [
        .init(latitude: 3.6800, longitude: 101.5200), .init(latitude: 3.8300, longitude: 101.4000),
        .init(latitude: 3.9900, longitude: 101.3100), .init(latitude: 4.1000, longitude: 101.2900),
        .init(latitude: 4.2000, longitude: 101.2600), .init(latitude: 4.4700, longitude: 101.1700),
        .init(latitude: 4.6000, longitude: 101.0900),
    ]

    /// Hafiz's route from Teluk Intan; its last point is on the main route at Bidor.
    static let joiningWaypoints: [CLLocationCoordinate2D] = [
        .init(latitude: 4.0250, longitude: 101.0210), .init(latitude: 4.0500, longitude: 101.1100),
        .init(latitude: 4.0800, longitude: 101.2000), .init(latitude: 4.0950, longitude: 101.2500),
        .init(latitude: 4.1000, longitude: 101.2900),
    ]

    /// Straight legs cut every ~`step` meters so projections and merge detection behave like a real route.
    static func densify(_ points: [CLLocationCoordinate2D], step: Double = 400) -> [CLLocationCoordinate2D] {
        var out: [CLLocationCoordinate2D] = []
        for (a, b) in zip(points, points.dropFirst()) {
            let n = max(1, Int(RouteLine.haversine(a, b) / step))
            for i in 0..<n {
                let t = Double(i) / Double(n)
                out.append(.init(
                    latitude: a.latitude + t * (b.latitude - a.latitude),
                    longitude: a.longitude + t * (b.longitude - a.longitude)))
            }
        }
        if let last = points.last { out.append(last) }
        return out
    }

    static func model(now: Date = Date(), fiveCars: Bool = false) -> TripMapModel {
        let main = RouteLine(densify(mainWaypoints))
        let own = RouteLine(densify(joiningWaypoints))
        let tapah = main.project(.init(latitude: 4.2000, longitude: 101.2600))?.offset ?? 0

        func car(_ id: String, _ name: String, _ color: String, number: Int, lead: Bool = false,
                 state: CarState = .convoy, route: String? = nil) -> Car {
            Car(id: id, name: name, color: color, trackerUserId: "u-\(id)", isLead: lead, route: route,
                mergeOffset: nil, state: state, number: number)
        }
        func onMain(_ offset: Double, speed: Double, age: TimeInterval) -> Position {
            let c = main.coordinate(atOffset: offset) ?? main.coordinates[0]
            let ahead = main.coordinate(atOffset: offset + 50) ?? c
            return Position(
                id: nil, location: GeoPoint(latitude: c.latitude, longitude: c.longitude), speed: speed,
                heading: bearing(c, ahead), routeOffset: offset, convoyOffset: offset, battery: 0.8,
                updatedAt: now.addingTimeInterval(-age))
        }

        var cars = [
            car("c1", "Aqlan’s Myvi", "#2563EB", number: 1, lead: true),
            car("c2", "Wyna’s X70", "#D9480F", number: 2),
            car("c3", "Hafiz’s Hilux", "#0F766E", number: 3, state: .joining, route: Polyline.encode(own.coordinates)),
            car("c4", "Daniel’s City", "#7C3AED", number: 4),
        ]
        if fiveCars { cars.append(car("c5", "Faiz’s car", "#BE185D", number: 5)) }
        // 12 km short of the merge point, at 84 km/h.
        let hafizOffset = max(0, (own.length) - 12_000)
        let hafizPoint = own.coordinate(atOffset: hafizOffset) ?? own.coordinates[0]
        let hafizAhead = own.coordinate(atOffset: hafizOffset + 50) ?? hafizPoint
        var positions: [String: Position] = [
            "c1": onMain(tapah, speed: 96 / 3.6, age: 4),
            "c2": onMain(tapah - 1_800, speed: 92 / 3.6, age: 6),
            "c4": onMain(tapah - 6_400, speed: 80 / 3.6, age: 125),
            "c3": Position(
                id: nil, location: GeoPoint(latitude: hafizPoint.latitude, longitude: hafizPoint.longitude),
                speed: 84 / 3.6, heading: bearing(hafizPoint, hafizAhead), routeOffset: hafizOffset,
                convoyOffset: nil, battery: 0.6, updatedAt: now.addingTimeInterval(-3)),
        ]
        if fiveCars { positions["c5"] = onMain(tapah - 8_000, speed: 90 / 3.6, age: 5) }
        let trip = Trip(
            id: "demo", name: "Balik kampung raya", code: "K7M2QX", organizerId: "u-c1",
            route: Polyline.encode(main.coordinates),
            destination: Destination(name: "Ipoh", coordinate: GeoPoint(latitude: 4.6, longitude: 101.09)),
            status: .active, createdAt: now, lastActivityAt: now, endedAt: nil)

        let convoy = ConvoyModel(provider: FixedETA(seconds: 3_000), clock: { now })
        let model = TripMapModel(session: nil, convoy: convoy)
        model.apply(trip: trip, myCar: cars[0], myCarId: "c1", positions: positions, isTracker: true)
        model.setCars(cars)
        // Debris 3 km ahead of the lead car, reported 4 minutes ago by Wyna.
        if let spot = main.coordinate(atOffset: tapah + 3_000) {
            var debris = TripEvent(
                type: .debris, location: GeoPoint(latitude: spot.latitude, longitude: spot.longitude),
                heading: 0, routeOffset: tapah + 3_000, authorId: "u-c2", carId: "c2",
                createdAt: now.addingTimeInterval(-240))
            debris.id = "demo-debris"
            model.setEvents([debris])
        }
        model.mode = .fit
        return model
    }

    static func view() -> some View {
        Backend.configure()
        let env = ProcessInfo.processInfo.environment
        let five = env["IKUT_MAP_DEMO_CARS"] == "5"
        let gallery = env["IKUT_MAP_DEMO_BANNERS"] != nil
        let model = model(fiveCars: five)
        return NavigationStack {
            TripMapView(
                session: TripSession(tripId: "demo", userId: "u-c1"), model: model,
                stopState: env["IKUT_MAP_DEMO_NO_STOP"] == nil && !gallery ? stopRequest(fiveCars: five) : nil,
                alerts: banner(env["IKUT_MAP_DEMO_ALERT"]))
                .overlay(alignment: .top) {
                    if gallery { BannerGallery(model: model).padding(.top, 72) }
                }
        }
    }

    /// The debris 3 km ahead as an approach alert.
    static let debrisAlert = TripAlert(
        id: "demo-debris@approach", eventId: "demo-debris", tripId: "demo", type: .debris, category: .hazard,
        severity: .high, distance: 500, title: "Debris ahead in 500 meters",
        body: "Debris reported by Wyna’s car", spoken: "")

    /// `IKUT_MAP_DEMO_ALERT=stop` or `debris` shows that banner at the top, to check it against the card.
    static func banner(_ kind: String?) -> AlertCenter {
        let center = AlertCenter(bannerDuration: .seconds(3_600))
        switch kind {
        case "stop":
            center.showForDemo(TripAlert(
                id: "demo-stop", eventId: "demo-stop", tripId: "demo", type: .stopFuel, category: .stopRequest,
                severity: .low, distance: nil, title: "Stop request", body: "Wyna’s car wants to stop for fuel",
                spoken: ""))
        case "debris":
            center.showForDemo(debrisAlert)
        default: break
        }
        return center
    }

    /// Wyna asks for a fuel stop and proposes a station; Aqlan (the lead) has agreed, the others haven't answered.
    static func stopRequest(now: Date = Date(), fiveCars: Bool = false) -> StopRequestState {
        let proposal = StopPlace(
            name: "Petronas Tapah R&R", coordinate: GeoPoint(latitude: 4.21, longitude: 101.26),
            routeOffset: 52_000, pinnedBy: nil)
        func row(_ id: String, _ n: Int, _ color: String, _ name: String, mine: Bool = false,
                 _ status: StopRequestState.VoteStatus) -> StopRequestState.Row {
            .init(carId: id, number: n, colorHex: color, name: name, isMine: mine, status: status, suggestion: nil)
        }
        return StopRequestState(
            eventId: "demo-stop", type: .stopFuel, requesterCarId: "c2", requesterNumber: 2,
            requesterName: "Wyna", askedAt: now.addingTimeInterval(-90),
            rows: [
                row("c1", 1, "#2563EB", "Aqlan’s Myvi (you)", mine: true, .waiting),
                row("c2", 2, "#D9480F", "Wyna’s X70", .agreed),
                row("c4", 4, "#7C3AED", "Daniel’s City", .waiting),
            ] + (fiveCars ? [row("c5", 5, "#BE185D", "Faiz’s car", .waiting)] : []),
            place: nil, proposal: proposal, alternatives: [], viewerAgrees: false, canPin: true,
            canResolve: false, viewerOffset: 40_000, isResolved: false)
    }

    private static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }
}

/// `IKUT_MAP_DEMO_BANNERS=1`: every dark banner the map can show, stacked under the trip pill so
/// they can be compared on one screen. The map's own top stack would only ever show some of them.
private struct BannerGallery: View {
    let model: TripMapModel
    @State private var alerts = MapDemo.banner("debris")
    @State private var toast: ReportToastModel = {
        let toast = ReportToastModel()
        toast.showForDemo(.reported(label: "debris", eventId: "demo-debris"))
        return toast
    }()

    var body: some View {
        VStack(spacing: 8) {
            AlertBannerView(center: alerts)
            ApproachPill(alert: MapDemo.debrisAlert, model: model) {}
            PassedBanner(text: "Passed the debris")
            ReportToastView(model: toast)
        }
        .padding(.horizontal, 12)
    }
}

#Preview("Convoy map") {
    MapDemo.view()
}
#endif
