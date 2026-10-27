import CoreLocation
import Foundation
import Testing
@testable import ikut

/// A past trip picked on Home's map: its sheet words, which route is drawn, where the camera goes, and
/// the timeline item that moves the map.
@MainActor
struct PickedTripTests {
    private func entry(_ id: String = "demo", ended: Date? = Date(timeIntervalSince1970: 1_774_900_000)) -> PastTrips.Entry {
        PastTrips.Entry(id: id, name: "Balik kampung raya", destination: "Ipoh", endedAt: ended, seenAt: Date(), others: nil)
    }

    private func pickedTrip(_ e: PastTrips.Entry? = nil) -> PickedTrip {
        let e = e ?? entry()
        return PickedTrip(entry: e, model: RecapModel(snapshot: .demo(), originName: "Tanjung Malim"))
    }

    // MARK: A trip left early (D54, #421)

    @Test func aTripLeftEarlyShowsItsRouteAndReadsNothing() {
        var left = entry()
        left.leftAt = Date(timeIntervalSince1970: 1_774_800_000)
        #expect(!PickedTripLogic.readsServer(left))
        #expect(PickedTripLogic.readsServer(entry()))

        let picked = PickedTrip(entry: left, model: RecapModel(tripId: left.id))
        #expect(picked.isLeft)
        #expect(!pickedTrip().isLeft)
        // Its name and the drawn (cached) route, no stats.
        #expect(picked.title == "Balik kampung raya")
        #expect(picked.statsLine == nil)
        let drawn = PastTripRoute(id: left.id, name: left.name, destinationName: "Ipoh", destinationLatitude: 4.6,
                                  destinationLongitude: 101.1, points: [[3.1, 101.6], [4.6, 101.1]])
        #expect(PickedTripLogic.route(for: left, snapshot: nil, drawn: [drawn], fetched: nil) == drawn)
        #expect(PickedTripLogic.leftTitle == "You left while the trip was in progress")
        #expect(PickedTripLogic.leftLine == "No recap for trips you leave early.")
    }

    @Test func leavingIsKeptWhenTheTripIsRecordedAgain() {
        var left = entry(ended: Date(timeIntervalSince1970: 5))
        left.leftAt = Date(timeIntervalSince1970: 5)
        let list = PastTrips.upsert([left], PastTrips.Entry(id: left.id, name: "Renamed", destination: "Ipoh", endedAt: nil,
                                                            seenAt: Date()))
        #expect(list.first?.leftAt == left.leftAt)
        #expect(list.first?.endedAt == left.endedAt)
    }

    // MARK: Words

    @Test func subtitleIsDestinationAndDay() {
        let en = Fixtures.gb
        #expect(PickedTripLogic.subtitle(entry(), locale: en) == "To Ipoh · 31 Mar 2026")
        #expect(PickedTripLogic.subtitle(entry(ended: nil), locale: en) == "To Ipoh")
    }

    @Test func statsLineHasDistanceTimeCarsAndStops() throws {
        let recap = RecapLogic.recap(.demo())
        let line = try #require(PickedTripLogic.statsLine(recap))
        // Demo: the KL to Ipoh route, 4 cars, 2 h 47.
        #expect(line.contains(" km"))
        #expect(line.contains("2 h 47 min"))
        #expect(line.contains("4 cars"))
        #expect(line.split(separator: "·").count >= 3)
    }

    @Test func statsLineLeavesOutWhatIsUnknown() {
        var recap = RecapLogic.recap(.demo())
        recap.routeDistance = nil
        recap.duration = nil
        recap.carCount = 1
        recap.stopCount = 0
        #expect(PickedTripLogic.statsLine(recap) == "1 car")
        recap.carCount = 0
        #expect(PickedTripLogic.statsLine(recap) == nil)
        recap.stopCount = 1
        recap.routeDistance = 204_600
        recap.duration = 2 * 3600 + 47 * 60
        recap.carCount = 4
        #expect(PickedTripLogic.statsLine(recap) == "205 km · 2 h 47 min · 4 cars · 1 stop")
        recap.stopCount = 2
        recap.duration = 5 * 60 + 20
        #expect(PickedTripLogic.statsLine(recap) == "205 km · 5 min · 4 cars · 2 stops")
    }

    @Test func theTripLineReadsADurationInTheOneFormat() {
        var recap = RecapLogic.recap(.demo())
        recap.carCount = 0
        recap.stopCount = 0
        recap.routeDistance = nil
        func line(_ seconds: Double) -> String? {
            recap.duration = seconds
            return PickedTripLogic.statsLine(recap)
        }
        #expect(line(2 * 3600 + 5 * 60) == "2 h 5 min")
        #expect(line(59 * 60) == "59 min")
        #expect(line(10) == nil)
        #expect(line(2 * 3600) == "2 h")
        #expect(line(3600) == "1 h")
    }

    // MARK: Which route

    private func thin(_ id: String) -> PastTripRoute {
        PastTripRoute(id: id, name: id, destinationName: "D", destinationLatitude: 4.6, destinationLongitude: 101.1,
                      points: [[3.1, 101.7], [4.6, 101.1]])
    }

    @Test func routeIsTheFullOneFromTheRecapOnceItIsHere() throws {
        let snap = RecapSnapshot.demo()
        let route = try #require(PickedTripLogic.route(for: entry(), snapshot: snap, drawn: [thin("demo")], fetched: nil))
        #expect(route.points.count == Polyline.decode(snap.route).count)
        #expect(route.points.count > 2)
    }

    @Test func routeIsTheDrawnOneBeforeTheRecapLoads() {
        let route = PickedTripLogic.route(for: entry("a"), snapshot: nil, drawn: [thin("b"), thin("a")], fetched: nil)
        #expect(route?.id == "a")
        #expect(route?.points.count == 2)
    }

    @Test func aTripOutsideTheTwelveDrawnUsesTheOneFetched() {
        let entries = (0..<14).map { entry("t\($0)") }
        let drawn = PastTripsMapLogic.tripsToDraw(entries)
        #expect(drawn.count == PastTripsMapLogic.maxTrips)
        let old = entries[13]
        #expect(!drawn.contains { $0.id == old.id })
        #expect(PickedTripLogic.route(for: old, snapshot: nil, drawn: drawn.map { thin($0.id) }, fetched: nil) == nil)
        #expect(PickedTripLogic.route(for: old, snapshot: nil, drawn: drawn.map { thin($0.id) }, fetched: thin("t13"))?.id == "t13")
        // A route fetched for another trip is never shown.
        #expect(PickedTripLogic.route(for: old, snapshot: nil, drawn: [], fetched: thin("t3")) == nil)
    }

    @Test func recapOfAnotherTripIsIgnored() {
        let snap = RecapSnapshot.demo()
        #expect(PickedTripLogic.route(for: entry("other"), snapshot: snap, drawn: [], fetched: nil) == nil)
    }

    // MARK: Camera

    @Test func fitFramesTheRouteAboveTheShortSheet() throws {
        let route = thin("a")
        let insets = TripsHomeView.obscured(mapHeight: 874, sheet: 172)
        let r = try #require(PickedTripLogic.fit(route, bottomObscured: insets.bottom, topObscured: insets.top))
        let mapTop = r.center.latitude + r.span.latitudeDelta / 2
        let mapBottom = r.center.latitude - r.span.latitudeDelta / 2
        let visibleBottom = mapBottom + r.span.latitudeDelta * insets.bottom
        // Both ends of the route sit between the sheet's top edge and the status bar.
        #expect(3.1 >= visibleBottom)
        #expect(4.6 <= mapTop - r.span.latitudeDelta * insets.top)
        // The map's own bottom padding covers a sheet no taller than it, so the camera keeps no extra room;
        // a taller one keeps only the part above the padding.
        let padding = HomeSheet.legalInset(compact: HomeSheet.compactHeight)
        #expect(insets.bottom == 0)
        let tall = TripsHomeView.obscured(mapHeight: 874, sheet: 500).bottom
        #expect(abs(tall - Double(500 - padding) / 874) < 1e-9)
        #expect(tall > insets.bottom)
    }

    @Test func focusCentresTheSpotAboveTheSheet() {
        let spot = CLLocationCoordinate2D(latitude: 3.9, longitude: 101.4)
        let insets = TripsHomeView.obscured(mapHeight: 874, sheet: 172)
        let r = PickedTripLogic.focus(on: spot, bottomObscured: insets.bottom, topObscured: insets.top)
        let visibleBottom = r.center.latitude - r.span.latitudeDelta / 2 + r.span.latitudeDelta * insets.bottom
        let visibleTop = r.center.latitude + r.span.latitudeDelta / 2 - r.span.latitudeDelta * insets.top
        #expect(abs((visibleBottom + visibleTop) / 2 - spot.latitude) < 1e-9)
        #expect(r.center.longitude == spot.longitude)
    }

    // MARK: Picking

    @Test func startsOnTheWholeTripWithNothingSelected() {
        let p = pickedTrip()
        #expect(p.selectedItem == nil)
        #expect(p.filter == .all)
        #expect(p.entry.id == "demo")
    }

    @Test func tappingATimelineItemSelectsItAndTheXClearsIt() throws {
        let p = pickedTrip()
        let recap = try #require(p.model.recap)
        let stop = try #require(recap.timeline.first { $0.kind == .stop })
        p.select(stop)
        #expect(p.selectedItem?.id == stop.id)
        #expect(p.selectedItem?.coordinate != nil)
        p.clearSelection()
        #expect(p.selectedItem == nil)
    }

    @Test func anItemWithoutAPlaceDoesNothing() throws {
        let p = pickedTrip()
        let recap = try #require(p.model.recap)
        let end = try #require(recap.timeline.first { $0.id == "end" })
        #expect(end.coordinate == nil)
        p.select(end)
        #expect(p.selectedItem == nil)
    }

    @Test func mapMarksStopsAndRoadReportsOnly() throws {
        let p = pickedTrip()
        let markers = PickedTripLogic.markers(p.model.recap)
        #expect(!markers.isEmpty)
        #expect(markers.allSatisfy { $0.kind == .stop || $0.kind == .hazard })
        #expect(PickedTripLogic.markers(nil).isEmpty)
    }

    @Test func whileLoadingTheNameAndDateComeFromTheEntry() {
        let p = PickedTrip(entry: entry("never-opened-on-this-phone"))
        #expect(p.model.recap == nil)
        #expect(p.model.isLoading)
        #expect(p.title == "Balik kampung raya")
        #expect(p.subtitle.hasPrefix("To Ipoh"))
        #expect(p.statsLine == nil)
    }

    @Test func couldntLoadSaysSoInPlainWords() {
        let p = PickedTrip(entry: entry(), model: RecapModel(failedTripId: "demo"))
        #expect(!p.model.isLoading)
        #expect(p.model.errorMessage == "Couldn’t load this recap. Check your signal and try again.")
        #expect(p.model.recap == nil)
    }

    // MARK: Pin and camera

    @Test func pinSaysWhatItIsAndWhen() throws {
        let p = pickedTrip()
        let recap = try #require(p.model.recap)
        let stop = try #require(recap.timeline.first { $0.kind == .stop })
        let report = try #require(recap.timeline.first { $0.kind == .hazard })
        #expect(PickedTripLogic.pinLabel(stop) == "Fuel stop · \(RecapLogic.clock(stop.time))")
        #expect(PickedTripLogic.pinLabel(report) == "Road report · \(RecapLogic.clock(report.time))")
        #expect(!PickedTripLogic.pinLabel(stop).contains("asked"))
    }

    @Test func cameraRefitsWhenTheRecapFirstArrivesAndIsStillOurs() {
        #expect(PickedTripLogic.shouldRefit(hadSnapshot: false, hasSnapshot: true, itemSelected: false, cameraMovedByUser: false))
        #expect(!PickedTripLogic.shouldRefit(hadSnapshot: true, hasSnapshot: true, itemSelected: false, cameraMovedByUser: false))
        #expect(!PickedTripLogic.shouldRefit(hadSnapshot: false, hasSnapshot: false, itemSelected: false, cameraMovedByUser: false))
        #expect(!PickedTripLogic.shouldRefit(hadSnapshot: false, hasSnapshot: true, itemSelected: true, cameraMovedByUser: false))
        #expect(!PickedTripLogic.shouldRefit(hadSnapshot: false, hasSnapshot: true, itemSelected: false, cameraMovedByUser: true))
    }

    // MARK: Try again

    private struct Offline: Error {}

    @Test func retryGoesFromLoadingToFailedToLoaded() async throws {
        var online = false
        var calls = 0
        let snap = RecapSnapshot.demo()
        let model = RecapModel(tripId: snap.tripId, originName: "Tanjung Malim", fetch: { _ in
            calls += 1
            if online { return snap }
            throw Offline()
        }, persist: false)
        #expect(model.isLoading)
        await model.load(myUserId: nil)
        #expect(!model.isLoading)
        #expect(model.errorMessage == RecapModel.couldntLoad)
        #expect(model.recap == nil)
        online = true
        await model.retry(myUserId: nil)
        #expect(model.errorMessage == nil)
        #expect(model.snapshot != nil)
        #expect(model.recap?.title == snap.name)
        #expect(calls == 2)
    }

    @Test func retryDoesNothingOnceTheRecapIsThere() async {
        var calls = 0
        let model = RecapModel(tripId: "x", originName: "Somewhere", fetch: { _ in calls += 1; return RecapSnapshot.demo() }, persist: false)
        await model.load(myUserId: nil)
        #expect(calls == 1)
        await model.retry(myUserId: nil)
        #expect(calls == 1)
    }

    @Test func aFailedTryAgainStaysFailed() async {
        let model = RecapModel(tripId: "x", originName: "Somewhere", fetch: { _ in throw Offline() }, persist: false)
        await model.load(myUserId: nil)
        await model.retry(myUserId: nil)
        #expect(model.errorMessage == RecapModel.couldntLoad)
        #expect(model.snapshot == nil)
    }

    // MARK: Shared content

    @Test func theSheetAndTheScreenShareOneRecapContent() throws {
        let recap = try #require(RecapModel(snapshot: .demo()).recap)
        let text = RecapContent.shareText(recap)
        #expect(text.hasPrefix("Balik kampung raya: trip complete"))
        #expect(text.contains("Distance: "))
    }

    @Test func filterKeepsEachKindOfItem() throws {
        let recap = try #require(RecapModel(snapshot: .demo()).recap)
        #expect(recap.timeline.filter(RecapFilter.all.matches).count == recap.timeline.count)
        #expect(recap.timeline.filter(RecapFilter.stops.matches).allSatisfy { $0.kind == .stop })
        #expect(recap.timeline.filter(RecapFilter.reports.matches).allSatisfy { $0.kind == .hazard })
        #expect(!recap.timeline.filter(RecapFilter.reports.matches).isEmpty)
    }
}
