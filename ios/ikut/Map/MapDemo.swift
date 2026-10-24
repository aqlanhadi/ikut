#if DEBUG
import CoreLocation
import FirebaseFirestore
import SwiftUI

/// The Map.dc.html scenario on the real KL-Ipoh E1 route, for previews and the screenshot test:
/// three cars in the convoy near Tapah and Bidor (the last one stale), and Hafiz from Teluk Intan
/// joining at Bidor on his own route.
///
/// To see it in the simulator, launch a debug build with `IKUT_SCREEN=road-panel-short` (or another `road-panel-*`
/// state, see `DemoScreens`); `MapDemo.view()` hosts it. Nothing else in the app launches it.
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

    /// No-op announcer, so the demo's alerts show without sound.
    private final class SilentAnnouncer: AlertAnnouncing {
        func announce(event: TripEvent, distance: Double?) async -> Bool { false }
        func announce(alert: TripAlert) -> Bool { true }
    }

    /// `parked` (D26, `IKUT_MAP_DEMO_PARKED`): "far" adds Mei, parked 30 km ahead of the lead near Gopeng;
    /// "catchup" makes the viewer Mei, parked 3.1 km ahead of the convoy, with "Aqlan’s car is behind you".
    /// The viewer is Hafiz, whose car is still joining (D26 panel header): driving to the merge point, parked at
    /// home, or on a route that never meets the main one.
    enum Joiner { case moving, parked, never }

    static func model(now: Date = Date(), fiveCars: Bool = false, parked: String? = nil, joiner: Joiner? = nil) -> TripMapModel {
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
        if parked != nil { cars.append(car("c6", "Mei’s Saga", "#DB2777", number: 6)) }
        // 12 km short of the merge point, at 84 km/h.
        let hafizOffset = max(0, (own.length) - 12_000)
        let hafizPoint = own.coordinate(atOffset: hafizOffset) ?? own.coordinates[0]
        let hafizAhead = own.coordinate(atOffset: hafizOffset + 50) ?? hafizPoint
        cars[0].mergeOffset = 0
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
        // Mei parked ahead: 30 km on, or (for the heads-up) 15 km on until the lead is 3.1 km from her.
        if let parked { positions["c6"] = onMain(tapah + (parked == "far" ? 30_000 : 15_000), speed: 0, age: 3) }
        // Where Hafiz's own road meets the main route, for a stop measured from there (D25 4d-2).
        if joiner != nil { cars[2].mergeOffset = main.mergeOffset(of: own, tolerance: CarRouteLogic.mergeTolerance)?.mainOffset }
        switch joiner {
        case .parked:
            positions["c3"]?.speed = 0
        case .never:
            // Penang to Ipoh: the whole route is Hafiz's own and ends off the main route, 60 km on.
            let penang = CLLocationCoordinate2D(latitude: 5.4141, longitude: 100.3288)
            let end = CLLocationCoordinate2D(latitude: 4.6005, longitude: 101.09)
            let far = RouteLine(densify([penang, end]))
            cars[2].route = Polyline.encode(far.coordinates)
            cars[2].mergeOffset = main.length
            let at = far.coordinate(atOffset: max(0, far.length - 60_000)) ?? penang
            positions["c3"]?.location = GeoPoint(latitude: at.latitude, longitude: at.longitude)
            positions["c3"]?.routeOffset = max(0, far.length - 60_000)
        case .moving, nil:
            break
        }
        let trip = Trip(
            id: "demo", name: "Balik kampung raya", code: "K7M2QX", organizerId: "u-c1",
            route: Polyline.encode(main.coordinates),
            destination: Destination(name: "Ipoh", coordinate: GeoPoint(latitude: 4.6, longitude: 101.09)),
            status: .active, createdAt: now, lastActivityAt: now, endedAt: nil)

        let convoy = ConvoyModel(provider: FixedETA(seconds: 3_000), clock: { now }, placeNamer: { _ in "Gopeng" })
        let model = TripMapModel(session: nil, convoy: convoy)
        let viewer = parked == "catchup" ? cars.count - 1 : joiner != nil ? 2 : 0
        if parked == "catchup" { model.startHazardAlerts(announcer: SilentAnnouncer(), userId: "u-c6", tripId: "demo") }
        model.apply(trip: trip, myCar: cars[viewer], myCarId: cars[viewer].id, positions: positions, isTracker: true)
        model.setCars(cars)
        if parked == "catchup" {
            // The convoy drives on until the lead is 3.1 km behind Mei: just under 2 minutes at 96 km/h.
            for id in ["c1", "c2", "c4"] {
                if let p = positions[id], let offset = p.convoyOffset {
                    positions[id] = onMain(offset + 15_000 - 3_100, speed: p.speed, age: 1)
                }
            }
            model.apply(trip: trip, myCar: cars[viewer], myCarId: cars[viewer].id, positions: positions, isTracker: true)
        }
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

    static func view(expanded: Bool = false, online: Bool = true, fiveCars: Bool = false, selected: String? = nil) -> some View {
        Backend.configure()
        let env = ProcessInfo.processInfo.environment
        let five = fiveCars || env["IKUT_MAP_DEMO_CARS"] == "5"
        let gallery = env["IKUT_MAP_DEMO_BANNERS"] != nil
        let model = model(fiveCars: five, parked: env["IKUT_MAP_DEMO_PARKED"])
        model.networkUp = online
        // IKUT_MAP_DEMO_STOP picks what the stop screens show (see `stopBoard`); IKUT_MAP_DEMO_NO_STOP
        // shows none. IKUT_MAP_DEMO_CARD opens the stop card (or one of its screens), and
        // IKUT_MAP_DEMO_EXPANDED=1 unfolds the panel, IKUT_MAP_DEMO_DRIVING=1 puts the phone in driving mode.
        let board = env["IKUT_MAP_DEMO_NO_STOP"] == nil && !gallery
            ? stopBoard(env["IKUT_MAP_DEMO_STOP"] ?? "lead", fiveCars: five) : StopBoard.empty
        return NavigationStack {
            TripMapView(
                session: TripSession(tripId: "demo", userId: "u-c1"), model: model,
                stopBoard: board, alerts: banner(env["IKUT_MAP_DEMO_ALERT"]),
                demoCard: env["IKUT_MAP_DEMO_CARD"], demoDriving: env["IKUT_MAP_DEMO_DRIVING"] != nil,
                demoExpanded: expanded || env["IKUT_MAP_DEMO_EXPANDED"] != nil,
                demoError: env["IKUT_MAP_DEMO_ERROR"] == nil ? nil : "Could not reach the convoy. Try again in a moment.",
                demoSelected: selected ?? env["IKUT_MAP_DEMO_SELECTED"],
                stopService: DemoStopService())
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

    /// The stop screens' scenes. Wyna (car 2) asks for fuel; the viewer is Aqlan (car 1, the lead):
    /// `lead` (Wyna's request with a message, Aqlan has not said OK and may say We've stopped),
    /// `message` (the same, nobody else said OK), `responder` (no message), `asker` (Aqlan asked),
    /// `two` (a second request from Daniel, food).
    static func stopBoard(_ scene: String, now: Date = Date(), fiveCars: Bool = false) -> StopBoard {
        func request(
            id: String = "demo-stop", type: EventType = .stopFuel, by requester: (String, Int, String) = ("c2", 2, "Wyna"),
            asked: TimeInterval = -90, oks: Set<String> = [], message: String? = nil,
            canMarkStopped: Bool, author: Bool = false
        ) -> StopRequestState {
            func row(_ id: String, _ n: Int, _ color: String, _ name: String, mine: Bool = false) -> StopRequestState.Row {
                .init(
                    carId: id, number: n, colorHex: color, name: name, isMine: mine,
                    status: id == requester.0 || oks.contains(id) ? .ok : .waiting)
            }
            let rows = [
                row("c1", 1, "#2563EB", "Aqlan’s Myvi (you)", mine: true),
                row("c2", 2, "#D9480F", "Wyna’s X70"),
                row("c3", 3, "#0F766E", "Hafiz’s Hilux"),
                row("c4", 4, "#7C3AED", "Daniel’s City"),
            ] + (fiveCars ? [row("c5", 5, "#BE185D", "Faiz’s car")] : [])
            return StopRequestState(
                eventId: id, type: type, requesterCarId: requester.0, requesterNumber: requester.1,
                requesterName: requester.2, askedAt: now.addingTimeInterval(asked), message: message, rows: rows,
                canMarkStopped: canMarkStopped, isAuthor: author)
        }
        let note = "Low on fuel, next R&R please"
        switch scene {
        case "responder":
            return StopBoard(requests: [request(oks: ["c3"], canMarkStopped: false)])
        case "message":
            return StopBoard(requests: [request(message: note, canMarkStopped: false)])
        case "asker":
            return StopBoard(requests: [request(
                by: ("c1", 1, "Aqlan"), oks: ["c3"], message: note, canMarkStopped: true, author: true)])
        case "two":
            return StopBoard(requests: [
                request(oks: ["c3"], canMarkStopped: false),
                request(id: "demo-food", type: .stopFood, by: ("c4", 4, "Daniel"), asked: -30, canMarkStopped: false),
            ])
        default:
            return StopBoard(requests: [request(oks: ["c3"], message: note, canMarkStopped: true)])
        }
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

/// `IKUT_MAP_DEMO_ERROR=1` on the map shows the error line with its Close button (it stays until closed).
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
            GlanceErrorBanner(message: "Could not reach the convoy. Try again in a moment.") {}
        }
        .padding(.horizontal, 12)
    }
}

#Preview("Convoy map") {
    MapDemo.view()
}
#endif
