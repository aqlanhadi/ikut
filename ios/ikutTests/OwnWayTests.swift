import CoreLocation
import Foundation
import Testing
@testable import ikut

/// D26: the participant's own trip on the Join ticket and in the lobby.
@MainActor
struct OwnWayTests {
    /// Straight north, 3.0 to 4.0 degrees at longitude 101.0: about 111 km.
    private let mainCoords = MapDemo.densify([.init(latitude: 3.0, longitude: 101.0), .init(latitude: 4.0, longitude: 101.0)])
    private var main: RouteLine { RouteLine(mainCoords) }
    private let destination = CLLocationCoordinate2D(latitude: 4.0, longitude: 101.0)
    private let shahAlam = CLLocationCoordinate2D(latitude: 3.1, longitude: 100.8)

    private func car(route: [CLLocationCoordinate2D]?, mergeOffset: Double?, state: CarState = .joining) -> Car {
        Car.fixture(
            "c", name: "Wyna’s X70", number: .some(nil), state: state, color: "#D9480F", tracker: "u",
            route: route.map(Polyline.encode), mergeOffset: mergeOffset)
    }

    /// The route a car from the west would store: its start, then the main route 20 km along and 500 m past.
    private func mergingCar() -> Car {
        let plan = CarRouteLogic.makePlan(
            computed: MapDemo.densify([shahAlam, main.coordinate(atOffset: 20_000)!, main.coordinate(atOffset: 40_000)!]), main: main)!
        return car(route: Polyline.decode(plan.route!), mergeOffset: plan.mergeOffset, state: plan.state)
    }

    private func neverMergingCar() -> Car {
        let end = CLLocationCoordinate2D(latitude: 4.003, longitude: 101.0)
        let plan = CarRouteLogic.makePlan(computed: MapDemo.densify([.init(latitude: 3.5, longitude: 100.0), end]), main: main)!
        #expect(plan.kind == .neverMerges)
        return car(route: Polyline.decode(plan.route!), mergeOffset: plan.mergeOffset)
    }

    // MARK: From

    @Test func fromIsTheOwnRoutesFirstPoint() {
        let phone = CLLocationCoordinate2D(latitude: 9, longitude: 9)
        let start = OwnWayLogic.start(car: mergingCar(), phone: phone)
        #expect(abs(start!.latitude - shahAlam.latitude) < 0.0001 && abs(start!.longitude - shahAlam.longitude) < 0.0001)
    }

    @Test func fromIsThePhoneWhenTheCarHasNoRoute() {
        let phone = CLLocationCoordinate2D(latitude: 3.2, longitude: 101.0)
        let start = OwnWayLogic.start(car: car(route: nil, mergeOffset: 0, state: .convoy), phone: phone)
        #expect(start?.latitude == 3.2)
        #expect(OwnWayLogic.start(car: nil, phone: phone)?.latitude == 3.2)
    }

    @Test func fromIsNothingWithoutRouteOrPhone() {
        #expect(OwnWayLogic.start(car: car(route: nil, mergeOffset: nil), phone: nil) == nil)
    }

    // MARK: Join line

    @Test func mergingCarJoinsNearTheMergePoint() throws {
        let found = try #require(OwnWayLogic.join(car: mergingCar(), main: main))
        guard case .merges(let offset) = found.join else { Issue.record("not merges: \(found.join)"); return }
        #expect(abs(offset - 20_000) < 200)
        #expect(OwnWayLogic.joinLine(found.join, place: "Rawang", destination: "Ipoh") == "Joins the convoy near Rawang")
        #expect(OwnWayLogic.joinLine(found.join, place: nil, destination: "Ipoh") == "Joins the convoy")
        let at = try #require(OwnWayLogic.joinCoordinate(found.join, main: main))
        #expect(abs(at.latitude - main.coordinate(atOffset: 20_000)!.latitude) < 0.003)
    }

    @Test func carAtTheStartOfTheMainRouteStartsWithTheConvoy() throws {
        let found = try #require(OwnWayLogic.join(car: car(route: nil, mergeOffset: 300, state: .convoy), main: main))
        #expect(found.join == .startsWithConvoy)
        #expect(OwnWayLogic.joinLine(found.join, place: "KL", destination: "Ipoh") == "Starts with the convoy")
    }

    @Test func carParkedFarAlongTheMainRouteIsOnTheRoute() throws {
        let found = try #require(OwnWayLogic.join(car: car(route: nil, mergeOffset: 38_000, state: .convoy), main: main))
        #expect(found.join == .onRoute(offset: 38_000))
        #expect(OwnWayLogic.joinLine(found.join, place: "Rawang", destination: "Ipoh") == "Joins the convoy near Rawang")
    }

    @Test func carFromTheFarSideMeetsTheConvoyAtTheDestination() throws {
        let found = try #require(OwnWayLogic.join(car: neverMergingCar(), main: main))
        #expect(found.join == .meetsAtDestination)
        #expect(OwnWayLogic.joinLine(found.join, place: nil, destination: "Ipoh") == "Meets the convoy at Ipoh")
        #expect(OwnWayLogic.joinCoordinate(found.join, main: main) == nil)
    }

    @Test func noRouteYetMeansNoJoinLine() {
        #expect(OwnWayLogic.join(car: car(route: nil, mergeOffset: nil), main: main) == nil)
        #expect(OwnWayLogic.join(car: nil, main: main) == nil)
        #expect(OwnWayLogic.joinLine(nil, place: "Rawang", destination: "Ipoh") == nil)
    }

    // MARK: Distance

    @Test func mergingDistanceIsOwnRoutePlusRestOfMain() throws {
        let found = try #require(OwnWayLogic.join(car: mergingCar(), main: main))
        guard case .merges(let offset) = found.join else { return }
        let total = OwnWayLogic.distance(join: found.join, ownToJoin: found.ownToJoin, mainLength: main.length)
        #expect(abs(total - (found.ownToJoin + main.length - offset)) < 0.001)
        // From (3.1, 100.8) to the main route at 20 km: about 25 km, then 91 km on.
        #expect(abs(found.ownToJoin - 25_000) < 3_000)
        #expect(abs(total - 116_000) < 4_000)
    }

    @Test func onRouteDistanceIsWhatIsLeftOfTheMainRoute() {
        #expect(OwnWayLogic.distance(join: .onRoute(offset: 38_000), ownToJoin: 0, mainLength: 111_000) == 73_000)
        #expect(OwnWayLogic.distance(join: .startsWithConvoy, ownToJoin: 0, mainLength: 111_000) == 111_000)
    }

    @Test func neverMergingDistanceIsTheOwnRoute() throws {
        let found = try #require(OwnWayLogic.join(car: neverMergingCar(), main: main))
        #expect(OwnWayLogic.distance(join: found.join, ownToJoin: found.ownToJoin, mainLength: main.length) == found.ownToJoin)
    }

    // MARK: One drive request

    @Test func participantLobbyMakesOneDriveRequestNotTwo() async {
        var mainDrives = 0, ownDrives = 0
        let routeInfo = TripRouteInfo(drive: { _, _ in mainDrives += 1; return (1, 1, "E1") }, placeName: { _ in "KL" })
        await routeInfo.load(route: Polyline.encode(mainCoords), routeSeconds: nil, needsRoadName: true, ownTrip: true)
        #expect(mainDrives == 0)
        #expect(routeInfo.coordinates.count == mainCoords.count && routeInfo.distance != nil)

        let own = OwnWayInfo(
            drive: { _, _ in ownDrives += 1; return .init(distance: 185_000, travelTime: 7800, roadName: "E1") },
            place: { $0.longitude < 100.9 ? "Shah Alam" : "Rawang" })
        await own.load(main: main, destination: destination, destinationName: "Ipoh", car: mergingCar(), phone: { nil })
        #expect(ownDrives == 1)
        #expect(own.fromName == "Shah Alam" && own.joinPlace == "Rawang")
        #expect(own.joinLine == "Joins the convoy near Rawang")
        #expect(own.drive?.travelTime == 7800)
        #expect(own.ownRoute.count > 1 && own.joinCoordinate != nil)

        // The same car route again asks nothing more.
        await own.load(main: main, destination: destination, destinationName: "Ipoh", car: mergingCar(), phone: { nil })
        #expect(ownDrives == 1)
    }

    @Test func organizerStillGetsTheMainRouteDrive() async {
        var drives = 0
        let routeInfo = TripRouteInfo(drive: { _, _ in drives += 1; return (111_000, 5000, "E1") }, placeName: { _ in "KL" })
        await routeInfo.load(route: Polyline.encode(mainCoords), routeSeconds: nil, needsRoadName: true)
        #expect(drives == 1 && routeInfo.originName == "KL" && routeInfo.travelTime == 5000)
    }

    @Test func noRouteYetUsesThePhoneAndSaysYourLocationWhenItCanNotName() async {
        let phone = CLLocationCoordinate2D(latitude: 3.3, longitude: 100.9)
        var from: CLLocationCoordinate2D?
        let own = OwnWayInfo(
            drive: { f, _ in from = f; return .init(distance: 150_000, travelTime: 6000, roadName: "") },
            place: { _ in nil })
        await own.load(main: main, destination: destination, destinationName: "Ipoh", car: car(route: nil, mergeOffset: nil), phone: { phone })
        #expect(from?.latitude == 3.3)
        #expect(own.fromName == "Your location")
        #expect(own.joinLine == nil)
        #expect(own.distance == 150_000)
    }

    @Test func carOnTheRouteWithoutAPhoneFixDrivesFromItsPointOnTheRoute() async {
        var from: CLLocationCoordinate2D?
        let own = OwnWayInfo(drive: { f, _ in from = f; return .init(distance: 73_000, travelTime: 3000, roadName: "E1") }, place: { _ in "Rawang" })
        await own.load(main: main, destination: destination, destinationName: "Ipoh", car: car(route: nil, mergeOffset: 38_000, state: .convoy), phone: { nil })
        #expect(abs((from?.latitude ?? 0) - main.coordinate(atOffset: 38_000)!.latitude) < 0.0001)
        #expect(own.joinLine == "Joins the convoy near Rawang")
        #expect(abs((own.distance ?? 0) - (main.length - 38_000)) < 1)
    }

    // MARK: Drive that does not come back

    @Test func aFailedDriveLeavesWhatIsKnownAndAsksAgainNextTime() async {
        var asked = 0
        let own = OwnWayInfo(drive: { _, _ in asked += 1; throw RouteError.noRoute }, place: { _ in "Rawang" })
        #expect(own.totalState == .loading)
        await own.load(main: main, destination: destination, destinationName: "Ipoh", car: mergingCar(), phone: { nil })
        guard case .distanceOnly(let km) = own.totalState else { Issue.record("state \(own.totalState)"); return }
        #expect(km > 100_000)
        #expect(own.joinLine == "Joins the convoy near Rawang")
        await own.load(main: main, destination: destination, destinationName: "Ipoh", car: mergingCar(), phone: { nil })
        #expect(asked == 2)
    }

    @Test func nothingKnownSaysSoInsteadOfSpinning() async {
        let own = OwnWayInfo(drive: { _, _ in throw RouteError.noRoute }, place: { _ in nil })
        await own.load(main: main, destination: destination, destinationName: "Ipoh", car: car(route: nil, mergeOffset: nil), phone: { nil })
        #expect(own.totalState == .unknown)
    }

    @Test func aCancelledLoadStoresNothingAndRetries() async {
        var asked = 0
        let own = OwnWayInfo(drive: { _, _ in asked += 1; return .init(distance: 1, travelTime: 1, roadName: "") }, place: { _ in "X" })
        let task = Task { @MainActor in
            await own.load(main: main, destination: destination, destinationName: "Ipoh", car: mergingCar(),
                           phone: { try? await Task.sleep(for: .milliseconds(50)); return nil })
        }
        task.cancel()
        await task.value
        #expect(own.drive == nil && !own.settled)
        await own.load(main: main, destination: destination, destinationName: "Ipoh", car: mergingCar(), phone: { nil })
        #expect(own.drive != nil && asked == 1)
    }

    // MARK: Meeting point

    @Test func meetingPointCarJoinsAtTheStartAndDrivesToTheMeetingPoint() async throws {
        // Rawang (55 km along) back south along the main route to the meeting point at its start.
        let rawang = main.coordinate(atOffset: 55_000)!
        let meet = mainCoords[0]
        let own = car(route: MapDemo.densify([rawang, meet]), mergeOffset: 0)
        let found = try #require(OwnWayLogic.join(car: own, main: main, hasMeetingPoint: true))
        #expect(found.viaMeeting)
        #expect(found.join == .merges(offset: 0))
        #expect(abs(found.ownToJoin - 55_000) < 300)
        let total = OwnWayLogic.distance(join: found.join, ownToJoin: found.ownToJoin, mainLength: main.length)
        #expect(abs(total - (55_000 + main.length)) < 300)
        // Without a meeting point the same route is read as before.
        #expect(OwnWayLogic.join(car: own, main: main)?.viaMeeting == false)

        var target: CLLocationCoordinate2D?
        var asked = 0
        let info = OwnWayInfo(drive: { _, to in asked += 1; target = to; return .init(distance: 55_000, travelTime: 1_000, roadName: "E1") }, place: { _ in "X" })
        await info.load(main: main, destination: destination, destinationName: "Ipoh", car: own,
                        meetingPoint: meet, routeSeconds: 5_000, phone: { nil })
        #expect(asked == 1)
        #expect(target?.latitude == meet.latitude)
        #expect(info.drive?.travelTime == 6_000)
        #expect(abs((info.distance ?? 0) - (55_000 + main.length)) < 300)
    }

    // MARK: Join ticket

    @Test func ticketLineReadsFromYouWithDistance() {
        #expect(TicketDrive(distance: 185_000, travelTime: 7800).line == "About 2 h 10 min from you · 185 km")
        #expect(TicketDrive(distance: 30_000, travelTime: 2700).line == "About 45 min from you · 30 km")
    }

    @Test func parsesTheDestinationCoordinateAndIgnoresAnOutOfRangeOne() throws {
        var data: [String: Any] = [
            "tripId": "t1", "name": "Raya", "destinationName": "Ipoh", "cars": [] as [[String: Any]],
            "destinationCoordinate": ["latitude": 4.5975, "longitude": 101.09],
        ]
        #expect(try JoinService.parsePreview(data).destinationCoordinate == PreviewCoordinate(latitude: 4.5975, longitude: 101.09))
        data["destinationCoordinate"] = ["latitude": 400.0, "longitude": 101.09]
        #expect(try JoinService.parsePreview(data).destinationCoordinate == nil)
        data["destinationCoordinate"] = nil
        #expect(try JoinService.parsePreview(data).destinationCoordinate == nil)
    }

    private func ticketModel(coordinate: PreviewCoordinate?, drive: TicketDrive?) -> JoinModel {
        let preview = TripPreview(tripId: "t1", name: "Raya", destinationName: "Ipoh", destinationCoordinate: coordinate, cars: [])
        return JoinModel(displayName: "Sam", initialCode: "ABC234", api: FakeJoinAPI(preview: preview), driveFromHere: { _ in drive })
    }

    @Test func ticketGetsItsDriveOnceTheTripIsFound() async {
        let model = ticketModel(coordinate: .init(latitude: 4.6, longitude: 101.09), drive: TicketDrive(distance: 185_000, travelTime: 7800))
        model.start()
        await waitUntil(.seconds(2)) { model.ticketDrive != nil }
        #expect(model.ticketDrive?.line == "About 2 h 10 min from you · 185 km")
    }

    @Test func ticketHasNoDriveWithoutLocationOrDestination() async {
        let noLocation = ticketModel(coordinate: .init(latitude: 4.6, longitude: 101.09), drive: nil)
        noLocation.start()
        await waitUntil(.seconds(1)) { noLocation.preview != nil }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(noLocation.preview != nil && noLocation.ticketDrive == nil)

        let noDestination = ticketModel(coordinate: nil, drive: TicketDrive(distance: 1, travelTime: 1))
        noDestination.start()
        await waitUntil(.seconds(1)) { noDestination.preview != nil }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(noDestination.ticketDrive == nil)
    }
}
