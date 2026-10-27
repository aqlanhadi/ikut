import CoreLocation
import SwiftUI
import Testing

@testable import ikut

/// Joining as steps in Home's sheet (D58): which steps there are, what each says, when it can go on, what the map
/// behind the card draws, and that the sheet keeps one height.
@MainActor
struct JoinStepperTests {
    private let myvi = PreviewCar(id: "c1", name: "Aqlan’s Myvi", color: TripService.palette[0], hasTracker: true, number: 1)
    private let x70 = PreviewCar(id: "c2", name: "Wyna’s X70", color: TripService.palette[1], hasTracker: false, number: 2)

    private func trip(stops: [PreviewStop] = [], coordinate: Bool = true, cars: [PreviewCar]? = nil) -> TripPreview {
        TripPreview(
            tripId: "t1", name: "Balik kampung raya", destinationName: "Ipoh",
            destinationCoordinate: coordinate ? PreviewCoordinate(latitude: 4.5975, longitude: 101.09) : nil,
            cars: cars ?? [myvi, x70], stops: stops)
    }

    private struct NotFoundAPI: JoinAPI {
        func preview(code: String) async throws -> TripPreview {
            throw JoinError(message: JoinService.message(code: .notFound, serverMessage: ""))
        }
        func join(code: String, displayName: String, car: JoinCarChoice, tracker: Bool) async throws -> JoinResult {
            throw JoinError(message: "no")
        }
    }

    private func stepper(code: String? = nil, preview: TripPreview? = nil, name: String = "Nurul") -> JoinStepper {
        JoinStepper(displayName: name, code: code, api: FakeJoinAPI(preview: preview ?? trip()))
    }

    // MARK: Steps

    @Test func theIndicatorCountsTheStepsPersonSees() {
        #expect(JoinSteps.sequence() == [.code, .car])
        #expect(JoinSteps.indicator(.code) == "Step 1 of 2")
        #expect(JoinSteps.indicator(.car) == "Step 2 of 2")
        #expect(JoinSteps.title(.code) == "Join a trip" && JoinSteps.title(.car) == "Your car")
    }

    @Test func stepsGoOnAndBackInOrder() {
        #expect(JoinSteps.next(after: .code) == .car)
        #expect(JoinSteps.next(after: .car) == nil)
        #expect(JoinSteps.previous(before: .car) == .code)
        #expect(JoinSteps.previous(before: .code) == nil)
    }

    @Test func theCodeStepGoesOnOnlyOnceTheTripIsFound() async {
        let s = stepper()
        #expect(!s.canContinue)
        s.goNext()
        #expect(s.step == .code)
        s.model.codeChanged("K7M2QX")
        await waitUntil { s.model.preview != nil }
        #expect(s.canContinue)
        s.goNext()
        #expect(s.step == .car)
        #expect(s.goBack() && s.step == .code)
        #expect(!s.goBack(), "Back on the first step is Close")
    }

    @Test func aCodeFromALinkLandsOnTheCodeStepWithTheCodeFilledIn() async {
        let s = stepper(code: "k7m-2qx")
        #expect(s.step == .code)
        #expect(s.model.code == "K7M2QX")
        s.model.start()
        await waitUntil { s.model.preview != nil }
        #expect(s.canContinue && s.step == .code)
    }

    @Test func aCodeNotFoundStaysOnTheCodeStepWithTheMessage() async {
        let s = JoinStepper(model: JoinModel(displayName: "Nurul", initialCode: "ZZZZZZ", api: NotFoundAPI()))
        s.model.start()
        await waitUntil { s.model.errorMessage != nil }
        #expect(s.model.errorMessage?.hasPrefix("No trip has that code") == true)
        #expect(!s.canContinue)
        s.goNext()
        #expect(s.step == .code)
    }

    @Test func aFullTripSaysSoOnTheCarStepAndStaysThere() async {
        struct FullAPI: JoinAPI {
            var trip: TripPreview
            func preview(code: String) async throws -> TripPreview { trip }
            func join(code: String, displayName: String, car: JoinCarChoice, tracker: Bool) async throws -> JoinResult {
                throw JoinError(message: JoinService.message(code: .resourceExhausted, serverMessage: ""))
            }
        }
        let s = JoinStepper(model: JoinModel(displayName: "Nurul", initialCode: "K7M2QX", api: FullAPI(trip: trip())))
        s.model.start()
        await waitUntil { s.model.preview != nil }
        s.goNext()
        s.model.selectNewCar()
        #expect(await s.model.join() == nil)
        #expect(s.step == .car)
        #expect(s.model.errorMessage == "This trip is full.")
    }

    @Test func theCarStepJoinsOnlyOncePicked() async {
        let s = stepper(code: "K7M2QX")
        s.model.start()
        await waitUntil { s.model.preview != nil }
        s.goNext()
        #expect(!s.canContinue)
        s.model.select(x70)
        #expect(s.canContinue)
        #expect(s.model.tracker, "nobody shares from the Wyna's X70 yet, so this phone does")
        s.model.select(myvi)
        #expect(!s.model.tracker, "someone already shares the Myvi: the co-pilot doesn't")
        s.model.selectNewCar()
        #expect(s.model.tracker && s.canContinue)
    }

    // MARK: Words

    @Test func theCardLines() {
        #expect(JoinSteps.toLine(trip()) == "To Ipoh · 2 cars in")
        #expect(JoinSteps.toLine(trip(cars: [myvi])) == "To Ipoh · 1 car in")
        #expect(JoinSteps.meetLine(trip()) == nil)
        let meet = PreviewStop(name: "Petronas Jalan Duta", kind: .meet)
        let fuel = PreviewStop(name: "R&R Tapah", kind: .fuel, minutes: 20)
        #expect(JoinSteps.meetLine(trip(stops: [meet])) == "Meets at Petronas Jalan Duta")
        #expect(JoinSteps.meetLine(trip(stops: [meet, fuel])) == "Meets at Petronas Jalan Duta · 1 stop")
        #expect(JoinSteps.meetLine(trip(stops: [meet, fuel, fuel])) == "Meets at Petronas Jalan Duta · 2 stops")
        #expect(JoinSteps.meetLine(trip(stops: [fuel])) == "1 stop")
    }

    @Test func theCardLinesWithTheOrganiserAndTheMeetingTime() {
        let t = tripWithRoute()
        #expect(JoinSteps.toLine(t) == "To Ipoh · Aqlan organises · 2 cars in")
        let tz = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        let noon = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: tz, year: 2026, month: 10, day: 27, hour: 12))!
        let meet = PreviewStop(name: "Petronas Jalan Duta", kind: .meet, meetAt: noon)
        let fuel = PreviewStop(name: "R&R Tapah", kind: .fuel, minutes: 20)
        #expect(JoinSteps.meetLine(trip(stops: [meet, fuel]), timeZone: tz) == "Meets at Petronas Jalan Duta, 12:00 · 1 stop")
        #expect(JoinSteps.meetLine(trip(stops: [meet]), timeZone: tz) == "Meets at Petronas Jalan Duta, 12:00")
        // An older server: no organiser, no time.
        #expect(JoinSteps.toLine(trip()) == "To Ipoh · 2 cars in")
        #expect(JoinSteps.meetLine(trip(stops: [PreviewStop(name: "Petronas Jalan Duta", kind: .meet)])) == "Meets at Petronas Jalan Duta")
    }

    @Test func theMainButtonNamesTheCarAndThePerson() {
        #expect(JoinSteps.joinLabel(car: myvi, ownCar: false, firstName: "Nurul") == "Join Aqlan’s Myvi as Nurul")
        #expect(JoinSteps.joinLabel(car: nil, ownCar: true, firstName: "Nurul") == "Join in my own car as Nurul")
        #expect(JoinSteps.joinLabel(car: nil, ownCar: false, firstName: "Nurul") == "Join trip")
    }

    // MARK: Map

    @Test func theMapDrawsOnlyWhereTheTripEndsWithoutTheNewFields() {
        let input = JoinSteps.map(for: trip())
        #expect(input.pins.count == 1 && input.pins.first?.kind == .destination)
        #expect(input.route.isEmpty && input.ownRoute.isEmpty && input.overlays.isEmpty && input.cars.isEmpty)
        #expect(input.layers.isDisjoint(with: [.route, .ownRoute, .overlays, .cars, .pastRoutes, .pickedRoute]))
        #expect(JoinSteps.map(for: nil).pins.isEmpty)
        #expect(JoinSteps.map(for: trip(coordinate: false)).pins.isEmpty)
    }

    private static let line = [(3.1873, 101.6773), (3.8, 101.5), (4.2, 101.26), (4.5975, 101.09)]
        .map { CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1) }

    private func tripWithRoute() -> TripPreview {
        var t = trip(stops: [
            PreviewStop(name: "Petronas Jalan Duta", kind: .meet, coordinate: PreviewCoordinate(latitude: 3.1873, longitude: 101.6773), meetAt: Date()),
            PreviewStop(name: "R&R Tapah", kind: .fuel, minutes: 20, coordinate: PreviewCoordinate(latitude: 4.2, longitude: 101.26)),
            PreviewStop(name: "No place", kind: .food),
        ])
        t.organizerName = "Aqlan"
        t.route = Polyline.encode(Self.line)
        return t
    }

    @Test func theMapDrawsTheRouteAndStopsAndNeverAStart() {
        let t = tripWithRoute()
        let input = JoinSteps.map(for: t)
        #expect(input.route.count == Self.line.count)
        // The meeting point, the numbered stop that has a place, and the end; a stop without a place is left out.
        #expect(input.pins.map(\.kind) == [.meeting, .stop(number: 1), .destination])
        #expect(input.layers.contains([.route, .pins]))
        #expect(input.layers.isDisjoint(with: [.ownRoute, .overlays, .cars, .pastRoutes, .pickedRoute]))
        #expect(!input.pins.contains { if case .join = $0.kind { true } else { false } }, "no start or join point")
        // The camera fits the whole line above the sheet.
        let region = JoinSteps.region(for: t, bottomObscured: 0.45, topObscured: 0.1)
        #expect(region != nil && (region?.span.latitudeDelta ?? 0) > 1.4)
        #expect(input.route.first.map { abs($0.latitude - 3.1873) < 0.001 } == true, "line begins where the server cut it")
    }

    @Test func aRouteTooShortToSendLeavesTheCaptionOnTheEnd() {
        var t = tripWithRoute()
        #expect(JoinSteps.mapCaption(t) == "The map shows the route and stops. Nobody’s start is shown.")
        t.route = nil
        #expect(JoinSteps.mapCaption(t) == "The map shows where the trip ends. Nobody’s start is shown.")
        #expect(JoinSteps.map(for: t).route.isEmpty)
    }

    @Test func theCameraKeepsTheEndAboveTheSheet() throws {
        let insets = HomeSheet.createInsets(mapHeight: 874, sheet: HomeSheet.joinHeight, compact: HomeSheet.compactHeight)
        let region = try #require(JoinSteps.region(for: trip(), bottomObscured: insets.bottom, topObscured: insets.top))
        // The centre sits south of the end, so the end shows in the part of the map above the sheet.
        #expect(region.center.latitude < 4.5975)
        #expect(JoinSteps.region(for: nil, bottomObscured: 0, topObscured: 0) == nil)
    }

    // MARK: Sheet

    @Test func theSheetAsksForTheSameDetentOnEveryStepAndSizeOfText() {
        let s = stepper()
        let asked = Set(JoinSteps.sequence().flatMap { step -> [PresentationDetent] in
            s.show(step)
            let mode = HomeSheet.mode(flow: nil, joining: true)
            // The keyboard isn't an input to the sheet's detents: it is the same call with it up or down.
            return [300.0, 360, 450].map { HomeSheet.detent(expanded: false, mode: mode, compact: $0) }
        })
        #expect(asked == [HomeSheet.short(HomeSheet.joinHeight)])
        #expect(HomeSheet.detents(.join, compact: 300) == [HomeSheet.short(HomeSheet.joinHeight), HomeSheet.tall])
    }

    @Test func aLinkOrQrCodeLandsOnTheCodeStepWithTheLookupStarted() async {
        let s = JoinStepper.begin(JoinStart(code: "k7m-2qx"), displayName: "Nurul", api: FakeJoinAPI(preview: trip()))
        #expect(s.step == .code && s.model.code == "K7M2QX")
        #expect(s.model.isLoadingPreview)
        await waitUntil { s.model.preview != nil }
        #expect(s.canContinue)
        let typed = JoinStepper.begin(JoinStart(code: nil), displayName: "Nurul", api: FakeJoinAPI(preview: trip()))
        #expect(typed.model.code.isEmpty && !typed.model.isLoadingPreview)
    }

    @Test func pickingACarNeverLeavesSharingHidden() async {
        let many = (1...5).map { PreviewCar(id: "c\($0)", name: "Car \($0)", color: TripService.palette[$0 % 3], hasTracker: $0 == 1, number: $0) }
        let s = stepper(code: "K7M2QX", preview: trip(cars: many))
        s.model.start()
        await waitUntil { s.model.preview != nil }
        #expect(JoinSteps.sharing(selectedCar: s.model.selectedCar, ownCar: false) == .none)
        for car in many {
            s.model.select(car)
            // Always a pinned switch, whichever of the five is picked, nobody-shares ones included.
            #expect(JoinSteps.sharing(selectedCar: s.model.selectedCar, ownCar: s.model.selection == .newCar) == .switchRow)
        }
        s.model.select(many[1])
        #expect(s.model.tracker)
        s.model.selectNewCar()
        #expect(JoinSteps.sharing(selectedCar: s.model.selectedCar, ownCar: s.model.selection == .newCar) == .ownCar)
    }

    @Test func joiningTakesOverFromEveryOtherMode() {
        #expect(HomeSheet.mode(flow: nil, leftTripPicked: true, joining: true) == .join)
        #expect(HomeSheet.mode(flow: nil, joining: false) == .list)
        #expect(!HomeSheet.drawsPastRoutes(.join))
        // A sheet pulled up on the list does not stay tall for Join.
        #expect(!HomeSheet.expanded(true, from: .list, to: .join))
    }

    // MARK: First run

    @Test func theStepsADifferentPersonSees() {
        let first = JoinSteps.plan(hasName: false, location: .notDetermined)
        #expect(first.steps == [.name, .location, .code, .car])
        #expect(JoinSteps.plan(hasName: true, location: .notDetermined).steps == [.location, .code, .car])
        #expect(JoinSteps.plan(hasName: false, location: .whenInUse).steps == [.name, .code, .car])
        #expect(JoinSteps.plan(hasName: true, location: .always).steps == [.code, .car])
        #expect(JoinSteps.plan(hasName: true, location: .denied).steps == [.code, .car])
        #expect(JoinSteps.indicator(.name, plan: first) == "Step 1 of 4")
        #expect(JoinSteps.indicator(.car, plan: first) == "Step 4 of 4")
        let named = JoinSteps.plan(hasName: true, location: .always)
        #expect(JoinSteps.indicator(.code, plan: named) == "Step 1 of 2")
        #expect(JoinSteps.title(.name) == "Welcome to ikut" && JoinSteps.title(.location) == "Location")
    }

    @Test func aLinkOnFirstRunGoesThroughNameAndLocationToTheCodeFilledIn() async {
        let plan = JoinSteps.plan(hasName: false, location: .notDetermined)
        let s = JoinStepper.begin(JoinStart(code: "k7m-2qx"), displayName: "", plan: plan, api: FakeJoinAPI(preview: trip()))
        #expect(s.step == .name && s.model.code == "K7M2QX")
        #expect(!s.model.isLoadingPreview, "no lookup before the name: the server wants a signed-in person")
        #expect(!s.canContinue)
        s.goNext()
        #expect(s.step == .name)
        s.model.displayName = "Nurul"
        #expect(s.canContinue)
        s.goNext()
        #expect(s.step == .location && s.canContinue)
        #expect(s.model.isLoadingPreview, "looked up once the name is in")
        s.goNext()
        #expect(s.step == .code && s.model.code == "K7M2QX")
        await waitUntil { s.model.preview != nil }
        #expect(s.canContinue)
        #expect(!s.canGoBack, "the name and the location ask are done once answered")
        s.goNext()
        #expect(s.step == .car && s.canGoBack)
    }

    @Test func whenLocationIsAskedInTheSheetAndWhenHomeStillGatesIt() {
        #expect(JoinSteps.sheetHostsLocation(status: .notDetermined, accuracy: .full))
        #expect(JoinSteps.sheetHostsLocation(status: .whenInUse, accuracy: .full))
        #expect(JoinSteps.sheetHostsLocation(status: .always, accuracy: .full))
        #expect(!JoinSteps.sheetHostsLocation(status: .denied, accuracy: .full))
        #expect(!JoinSteps.sheetHostsLocation(status: .whenInUse, accuracy: .reduced))
    }

    @Test func everyStepAsksForTheSameDetent() {
        let plan = JoinSteps.plan(hasName: false, location: .notDetermined)
        let s = JoinStepper(model: JoinModel(displayName: "", api: FakeJoinAPI(preview: trip())), plan: plan)
        let asked = Set(JoinStep.allCases.map { step -> PresentationDetent in
            s.show(step)
            return HomeSheet.detent(expanded: false, mode: HomeSheet.mode(flow: nil, joining: true), compact: 300)
        })
        #expect(asked == [HomeSheet.short(HomeSheet.joinHeight)])
    }

    /// A join that stays in flight until `finish` is called.
    private final class SlowJoin: JoinAPI, @unchecked Sendable {
        let trip: TripPreview
        private let gate = AsyncStream<Void>.makeStream()
        init(trip: TripPreview) { self.trip = trip }
        func finish() { gate.continuation.yield() }
        func preview(code: String) async throws -> TripPreview { trip }
        func join(code: String, displayName: String, car: JoinCarChoice, tracker: Bool) async throws -> JoinResult {
            for await _ in gate.stream { break }
            return JoinResult(tripId: "t1", carId: "c9", trackerTaken: false)
        }
    }

    @Test func aLinkMidJoinDoesNotReplaceTheSteps() async {
        #expect(JoinStepper.shouldReplace(nil))
        let api = SlowJoin(trip: trip())
        let s = JoinStepper(displayName: "Nurul", code: "K7M2QX", api: api)
        s.model.start()
        await waitUntil { s.model.preview != nil }
        #expect(JoinStepper.shouldReplace(s), "browsing: a new link replaces the steps")
        s.model.selectNewCar()
        let join = Task { await s.model.join() }
        await waitUntil { s.model.isJoining }
        #expect(s.model.isJoining && !JoinStepper.shouldReplace(s))
        api.finish()
        _ = await join.value
    }

    @Test func sharingNeedsLocationElseTheCoPilotJoinsWithTheLine() {
        let states: [LocationAccess.Status] = [.notDetermined, .denied, .whenInUse, .always]
        for state in states {
            // Not sharing never needs location and says nothing.
            let quiet = JoinSteps.tracker(wantsToShare: false, authorization: state)
            #expect(!quiet.tracker && quiet.note == nil)
            let wants = JoinSteps.tracker(wantsToShare: true, authorization: state)
            let allowed = state == .whenInUse || state == .always
            #expect(wants.tracker == allowed)
            #expect((wants.note == nil) == allowed)
        }
        #expect(JoinSteps.locationOffNote == "Location is off, so you’re joining as the co-pilot. Turn it on in Settings to share this car.")
    }

    @Test func joiningWithoutSharingSendsNoTracker() async {
        final class Spy: JoinAPI, @unchecked Sendable {
            var tracker: Bool?
            func preview(code: String) async throws -> TripPreview {
                TripPreview(tripId: "t", name: "T", destinationName: "Ipoh", cars: [])
            }
            func join(code: String, displayName: String, car: JoinCarChoice, tracker: Bool) async throws -> JoinResult {
                self.tracker = tracker
                return JoinResult(tripId: "t", carId: "c", trackerTaken: false)
            }
        }
        let spy = Spy()
        let s = JoinStepper(displayName: "Nurul", code: "K7M2QX", api: spy)
        s.model.start()
        await waitUntil { s.model.preview != nil }
        s.model.selectNewCar()
        #expect(s.model.tracker)
        _ = await s.model.join(sharing: false)
        #expect(spy.tracker == false, "my own car still made, with no tracker")
    }

    @Test func theButtonSaysCoPilotWhileTheLineShows() {
        #expect(JoinSteps.joinLabel(car: myvi, ownCar: false, firstName: "Nurul", coPilot: true) == "Join Aqlan’s Myvi as co-pilot")
        #expect(JoinSteps.joinLabel(car: nil, ownCar: true, firstName: "Nurul", coPilot: true) == "Join as co-pilot")
        // Allowed in Settings: no note, so the button is the sharing one again.
        #expect(JoinSteps.tracker(wantsToShare: true, authorization: .whenInUse).note == nil)
        #expect(JoinSteps.joinLabel(car: myvi, ownCar: false, firstName: "Nurul", coPilot: false) == "Join Aqlan’s Myvi as Nurul")
    }
}
