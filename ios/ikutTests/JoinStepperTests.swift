import CoreLocation
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

    @Test func theMainButtonNamesTheCarAndThePerson() {
        #expect(JoinSteps.joinLabel(car: myvi, ownCar: false, firstName: "Nurul") == "Join Aqlan’s Myvi as Nurul")
        #expect(JoinSteps.joinLabel(car: nil, ownCar: true, firstName: "Nurul") == "Join in my own car as Nurul")
        #expect(JoinSteps.joinLabel(car: nil, ownCar: false, firstName: "Nurul") == "Join trip")
    }

    // MARK: Map

    @Test func theMapDrawsOnlyWhereTheTripEndsAndNeverAStart() {
        let input = JoinSteps.map(for: trip())
        #expect(input.pins.count == 1 && input.pins.first?.kind == .destination)
        #expect(input.route.isEmpty && input.ownRoute.isEmpty && input.overlays.isEmpty && input.cars.isEmpty)
        #expect(input.layers.isDisjoint(with: [.route, .ownRoute, .overlays, .cars, .pastRoutes, .pickedRoute]))
        #expect(JoinSteps.map(for: nil).pins.isEmpty)
        #expect(JoinSteps.map(for: trip(coordinate: false)).pins.isEmpty)
    }

    @Test func theCameraKeepsTheEndAboveTheSheet() throws {
        let insets = HomeSheet.createInsets(mapHeight: 874, sheet: HomeSheet.joinHeight, compact: HomeSheet.compactHeight)
        let region = try #require(JoinSteps.region(for: trip(), bottomObscured: insets.bottom, topObscured: insets.top))
        // The centre sits south of the end, so the end shows in the part of the map above the sheet.
        #expect(region.center.latitude < 4.5975)
        #expect(JoinSteps.region(for: nil, bottomObscured: 0, topObscured: 0) == nil)
    }

    // MARK: Sheet

    @Test func theSheetKeepsOneHeightForEveryStepAndTheKeyboard() {
        let s = stepper()
        let mode = HomeSheet.mode(flow: nil, joining: true)
        #expect(mode == .join)
        // The mode, and so the height, doesn't read the step, the code, the preview or the keyboard.
        for step in JoinSteps.sequence() {
            s.show(step)
            #expect(HomeSheet.mode(flow: nil, joining: true) == .join)
            #expect(HomeSheet.height(.join, compact: 300) == HomeSheet.joinHeight)
        }
        // At every text size the short detent is the same (it doesn't follow the list's).
        for compact in [300.0, 360, 450] {
            #expect(HomeSheet.height(.join, compact: compact) == HomeSheet.joinHeight)
        }
        #expect(HomeSheet.detents(.join, compact: 300) == [HomeSheet.short(HomeSheet.joinHeight), HomeSheet.tall])
    }

    @Test func joiningTakesOverFromEveryOtherMode() {
        #expect(HomeSheet.mode(flow: nil, leftTripPicked: true, joining: true) == .join)
        #expect(HomeSheet.mode(flow: nil, joining: false) == .list)
        #expect(!HomeSheet.drawsPastRoutes(.join))
        // A sheet pulled up on the list does not stay tall for Join.
        #expect(!HomeSheet.expanded(true, from: .list, to: .join))
    }
}
