import CoreLocation
import Testing

@testable import ikut

/// Where to? and New trip over Home's map (D48): search, preview, create; Back and Close; the name rule; pins.
@MainActor
struct NewTripFlowTests {
    private let ipoh = DestinationResult(name: "Ipoh", subtitle: "City in Perak, Malaysia", coordinate: .init(latitude: 4.5975, longitude: 101.0901))
    private let parade = DestinationResult(name: "Ipoh Parade", subtitle: "Perak", coordinate: .init(latitude: 4.6, longitude: 101.07))
    private let station = DestinationResult(name: "Ipoh station", subtitle: "Perak", coordinate: .init(latitude: 4.59, longitude: 101.09))
    private let kl = CLLocationCoordinate2D(latitude: 3.139, longitude: 101.687)

    private struct Boom: Error, LocalizedError { var errorDescription: String? { "Maps took too long." } }

    /// A flow whose route builds count their calls, with three results showing.
    private func makeFlow(failing: Bool = false) -> (NewTripFlow, Counter) {
        let counter = Counter()
        let search = CreateTripModel(route: { coordinate in
            counter.builds += 1
            if failing { throw Boom() }
            return BuiltRoute(distance: 205_400, travelTime: 9_600, name: "E1",
                              polyline: Polyline.encode([.init(latitude: 3.139, longitude: 101.687), coordinate]))
        })
        search.showForDemo(query: "Ipoh", results: [ipoh, parade, station], origin: kl, originName: "Kuala Lumpur")
        return (NewTripFlow(search: search), counter)
    }

    @MainActor final class Counter { var builds = 0; var created: [(String, DestinationResult, BuiltRoute)] = [] }

    @Test func pickingBuildsTheRouteOnceAndWritesNothing() async {
        let (flow, counter) = makeFlow()
        await flow.pick(ipoh)
        #expect(counter.builds == 1)
        #expect(flow.ready?.place == ipoh)
        #expect(flow.ready?.route.distance == 205_400)
        #expect(counter.created.isEmpty)
    }

    @Test func createUsesThePreviewedRouteWithoutBuildingAnother() async {
        let (flow, counter) = makeFlow()
        await flow.pick(ipoh)
        let route = flow.ready?.route
        let id = await flow.create { name, place, route in
            counter.created.append((name, place, route))
            return "trip-1"
        }
        #expect(id == "trip-1")
        #expect(counter.builds == 1)
        #expect(counter.created.count == 1)
        #expect(counter.created.first?.2 == route)
        #expect(counter.created.first?.1 == ipoh)
    }

    @Test func backKeepsTheQueryAndResults() async {
        let (flow, _) = makeFlow()
        await flow.pick(parade)
        flow.back()
        #expect(flow.ready == nil)
        #expect(flow.search.query == "Ipoh")
        #expect(flow.search.results == [ipoh, parade, station])
        #expect(flow.search.showingResults)
        #expect(flow.pins.count == 3)
    }

    @Test func closeGoesBackToHomesList() async {
        #expect(HomeSheet.mode(flow: nil) == .list)
        let (flow, _) = makeFlow()
        #expect(HomeSheet.mode(flow: flow) == .whereTo)
        await flow.pick(ipoh)
        #expect(HomeSheet.mode(flow: flow) == .newTrip)
        // Close drops the flow: Home's own list, with its past routes, and the short detent it always had.
        #expect(HomeSheet.drawsPastRoutes(.list))
        #expect(!HomeSheet.drawsPastRoutes(.whereTo) && !HomeSheet.drawsPastRoutes(.newTrip))
        #expect(HomeSheet.height(.list, compact: 300) == 300)
        #expect(HomeSheet.height(.whereTo, compact: 300) == 560)
        #expect(HomeSheet.height(.newTrip, compact: 300) == 420)
    }

    @Test func aRouteThatFailsStaysOnTheSearchWithTheMessage() async {
        let (flow, counter) = makeFlow(failing: true)
        await flow.pick(ipoh)
        #expect(flow.ready == nil)
        #expect(flow.search.errorMessage == "Maps took too long.")
        #expect(flow.search.results.count == 3)
        #expect(counter.created.isEmpty)
    }

    @Test func aTripThatCannotBeWrittenStaysOnNewTripToTryAgain() async {
        let (flow, _) = makeFlow()
        await flow.pick(ipoh)
        let none = await flow.create { _, _, _ in throw Boom() }
        #expect(none == nil)
        #expect(flow.ready != nil)
        #expect(flow.createError == "Maps took too long.")
        let id = await flow.create { _, _, _ in "trip-2" }
        #expect(id == "trip-2")
        #expect(flow.createError == nil)
    }

    @Test func theNameIsEmptyUntilTypedAndFallsBackToTripTo() async {
        let (flow, counter) = makeFlow()
        await flow.pick(ipoh)
        #expect(flow.name.isEmpty)
        #expect(flow.namePlaceholder == "Trip to Ipoh")
        for typed in ["", "   ", " \n "] {
            flow.name = typed
            _ = await flow.create { name, place, route in counter.created.append((name, place, route)); return "x" }
        }
        #expect(counter.created.map(\.0) == ["Trip to Ipoh", "Trip to Ipoh", "Trip to Ipoh"])
        #expect(NewTripFlow.tripName(typed: "  Balik kampung raya ", destination: "Ipoh") == "Balik kampung raya")
    }

    @Test func pickingAgainStartsWithAnEmptyName() async {
        let (flow, _) = makeFlow()
        await flow.pick(ipoh)
        flow.name = "Raya"
        flow.back()
        await flow.pick(parade)
        #expect(flow.name.isEmpty)
        #expect(flow.namePlaceholder == "Trip to Ipoh Parade")
    }

    @Test func everyResultIsAPinAndTheCameraFollowsTheTopOfTheList() {
        let (flow, _) = makeFlow()
        #expect(flow.pins == [ipoh, parade, station])
        #expect(flow.focusTarget == ipoh)
        flow.topResultID = parade.id
        #expect(flow.focusTarget == parade)
        flow.topResultID = "gone"
        #expect(flow.focusTarget == ipoh)
    }

    @Test func pinsAreCappedAndSuggestionsAreNotPins() {
        let many = (0..<30).map { DestinationResult(name: "P\($0)", subtitle: "", coordinate: .init(latitude: 4 + Double($0) / 100, longitude: 101)) }
        let search = CreateTripModel()
        search.showForDemo(query: "p", results: many, origin: kl, originName: "KL")
        #expect(NewTripFlow(search: search).pins.count == NewTripFlow.maxPins)
        let typing = CreateTripModel()
        typing.showSuggestionsForDemo(query: "ipo", suggestions: [SearchSuggestion(title: "Ipoh", subtitle: "Perak", highlights: [])],
                                      origin: kl, originName: "KL")
        let typingFlow = NewTripFlow(search: typing)
        #expect(typingFlow.pins.isEmpty && typingFlow.focusTarget == nil)
    }

    @Test func newTripDrawsOnlyTheDestinationAndFitsTheRoute() async {
        let (flow, _) = makeFlow()
        let searching = flow.region(bottomObscured: 0.2, topObscured: 0.1)
        #expect(searching != nil)
        await flow.pick(ipoh)
        #expect(flow.pins == [ipoh])
        #expect(flow.focusTarget == nil)
        let region = flow.region(bottomObscured: 0.2, topObscured: 0.1)
        // KL to Ipoh: the whole line is inside the view.
        #expect(region != nil)
        if let region {
            #expect(region.span.latitudeDelta > 1.4)
            #expect(abs(region.center.latitude - 3.87) < 0.5)
        }
        #expect(flow.cameraKey != "-|-")
    }

    @Test func theLineUnderTheNameReadsAreaDistanceAndTime() {
        let route = BuiltRoute(distance: 205_400, travelTime: 9_600, name: "E1", polyline: "")
        #expect(NewTripFlow.detailLine(place: ipoh, route: route) == "City in Perak · 205 km · about 2 h 40 min from you")
    }
}
