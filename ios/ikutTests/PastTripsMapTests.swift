import CoreLocation
import MapKit
import Foundation
import Testing
@testable import ikut

struct PastTripsMapTests {
    private func route(_ id: String, _ coords: [(Double, Double)], dest: (Double, Double)) -> PastTripRoute {
        PastTripRoute(id: id, name: id, destinationName: "D", destinationLatitude: dest.0, destinationLongitude: dest.1,
                      points: coords.map { [$0.0, $0.1] })
    }

    @Test func noRoutesHasNoRegion() {
        #expect(PastTripsMapLogic.region(fitting: []) == nil)
    }

    @Test func regionCoversEveryRouteAndDestination() throws {
        let a = route("a", [(3.1, 101.6), (3.5, 101.4)], dest: (4.6, 101.1))
        let b = route("b", [(2.9, 101.7)], dest: (1.5, 103.7))
        let r = try #require(PastTripsMapLogic.region(fitting: [a, b]))
        for c in a.coordinates + b.coordinates + [a.destination, b.destination] {
            #expect(abs(c.latitude - r.center.latitude) <= r.span.latitudeDelta / 2)
            #expect(abs(c.longitude - r.center.longitude) <= r.span.longitudeDelta / 2)
        }
        // Padded beyond the bare bounding box (1.5...4.6, 101.1...103.7).
        #expect(r.span.latitudeDelta > 3.1)
        #expect(r.span.longitudeDelta > 2.6)
    }

    @Test func singlePointGetsMinimumSpan() throws {
        let r = try #require(PastTripsMapLogic.region(fitting: [route("a", [], dest: (3, 101))], minSpan: 0.05))
        #expect(r.span.latitudeDelta == 0.05)
        #expect(r.span.longitudeDelta == 0.05)
        #expect(r.center.latitude == 3)
    }

    @Test func sheetPushesContentIntoVisibleTop() throws {
        let a = route("a", [(3, 101)], dest: (4, 102))
        let r = try #require(PastTripsMapLogic.region(fitting: [a], padding: 1, bottomObscured: 0.5))
        // Visible half is the top: it spans the 1° of content exactly.
        #expect(abs(r.span.latitudeDelta - 2) < 1e-9)
        let visibleBottom = r.center.latitude
        let top = r.center.latitude + r.span.latitudeDelta / 2
        #expect(abs(visibleBottom - 3) < 1e-9)
        #expect(abs(top - 4) < 1e-9)
    }

    /// Tapah → Ipoh, as on Home: the routes and flags must sit centred in the visible band between
    /// the status bar and the sheet, and the region must stay close to the routes' own size.
    @Test func fitKeepsRoutesInVisibleAreaAboveSheet() throws {
        let a = route("a", [(4.0, 101.0), (4.3, 101.1)], dest: (4.6, 101.2))
        let b = route("b", [(4.05, 101.05)], dest: (4.5, 101.15))
        let minLat = 4.0, maxLat = 4.6
        // Every height the map can report, including 0 before its first layout.
        for height: CGFloat in [0, 1, 300, 672, 778, 874] {
            let insets = TripsHomeView.obscured(mapHeight: height)
            #expect(insets.bottom == 0, "height \(height)")  // the compact sheet is the map's padding
            #expect(insets.top > 0 && insets.top < 0.2, "height \(height)")
            let r = try #require(PastTripsMapLogic.region(fitting: [a, b], bottomObscured: insets.bottom,
                                                          topObscured: insets.top))
            let mapTop = r.center.latitude + r.span.latitudeDelta / 2
            let visibleTop = mapTop - r.span.latitudeDelta * insets.top
            let visibleBottom = mapTop - r.span.latitudeDelta * (1 - insets.bottom)
            #expect(visibleBottom < minLat && visibleTop > maxLat, "height \(height)")
            // Centred in the visible band.
            #expect(abs((visibleBottom + visibleTop) / 2 - (minLat + maxLat) / 2) < 1e-9)
            // The centre moves south only by the sheet's share, never out of the routes' latitudes.
            #expect(r.center.latitude >= minLat && r.center.latitude <= maxLat, "height \(height)")
            // Modest margin: within 2.5x the routes' span (1.1 padding / ~50% visible band) once
            // settled; 672 is a brief first layout with a smaller band.
            let limit = height == 672 ? 3.0 : 2.5
            #expect(r.span.latitudeDelta <= limit * (maxLat - minLat), "height \(height)")
            #expect(r.span.longitudeDelta <= 2 * 0.2)
        }
    }

    @Test func obscuredIsClampedSoTheFitNeverBalloons() throws {
        let a = route("a", [(4.0, 101.0)], dest: (4.6, 101.2))
        let r = try #require(PastTripsMapLogic.region(fitting: [a], padding: 1, bottomObscured: 300, topObscured: 1))
        #expect(r.span.latitudeDelta <= 0.6 / 0.3 + 1e-9)
    }

    @Test func thinKeepsEndsAndCaps() {
        let coords = (0..<1000).map { CLLocationCoordinate2D(latitude: Double($0) / 1000, longitude: 101) }
        let thin = PastTripsMapLogic.thin(coords, maxPoints: 50)
        #expect(thin.count == 50)
        #expect(thin.first?.latitude == coords.first?.latitude)
        #expect(thin.last?.latitude == coords.last?.latitude)
        #expect(PastTripsMapLogic.thin(Array(coords.prefix(10)), maxPoints: 50).count == 10)
    }

    @Test func drawsOnlyEndedTripsNewestFirstCapped() {
        let now = Date()
        let entries = (0..<20).map {
            PastTrips.Entry(id: "t\($0)", name: "T", destination: "D", endedAt: $0 == 0 ? nil : now, seenAt: now)
        }
        let drawn = PastTripsMapLogic.tripsToDraw(entries, limit: 5)
        #expect(drawn.map(\.id) == ["t1", "t2", "t3", "t4", "t5"])
    }

    @Test func routeDecodesEncodedPolyline() {
        let line = [CLLocationCoordinate2D(latitude: 3.1, longitude: 101.6), .init(latitude: 4.6, longitude: 101.1)]
        let r = PastTripsMapLogic.route(id: "x", name: "N", destinationName: "Ipoh", destination: line[1],
                                        encodedRoute: Polyline.encode(line))
        #expect(r.coordinates.count == 2)
        #expect(abs(r.start!.latitude - 3.1) < 1e-5)
        #expect(r.destinationName == "Ipoh")
    }
}

struct HomeSheetTests {
    @Test func aTallerPickedSheetLeavesOnlyTheDifferenceToTheCamera() {
        let padding = HomeSheet.legalInset(compact: HomeSheet.compactHeight)
        let taller = TripsHomeView.obscured(mapHeight: 800, sheet: padding + 80)
        #expect(abs(taller.bottom - 80.0 / 800) < 1e-9)
        #expect(TripsHomeView.obscured(mapHeight: 800, sheet: HomeSheet.compactHeight).bottom == 0)
    }

    @Test func legalInsetReachesTheTopOfTheRealListSheet() {
        // Measured on an iPhone 17 (874 pt): the 300 pt detent is a sheet 320.7 pt tall, its top at 545.3.
        #expect(abs(HomeSheet.defaultReach - (874 - 545.3)) < 2)
        #expect(HomeSheet.legalInset(compact: HomeSheet.compactHeight) == HomeSheet.defaultReach)
        #expect(HomeSheet.legalInset(compact: 390) == 420)
        #expect(HomeSheet.legalInset(compact: -5) == HomeSheet.detentExtra)
        // The short list sheet never reaches above the map's safe area, so the camera keeps no room of its own.
        #expect(HomeSheet.compactHeight <= HomeSheet.defaultReach)
    }

    @Test func homeSheetIsCoveredByEachThingThatTakesTheScreen() {
        func covered(path: Int = 0, name: Bool = false, denied: Bool = false, after: Bool = false, opening: Bool = false) -> Bool {
            HomeSheet.isCovered(pathCount: path, showName: name, showDenied: denied, afterName: after, opening: opening)
        }
        #expect(!covered())
        #expect(covered(path: 1))
        #expect(covered(path: 2))
        #expect(covered(name: true))
        #expect(covered(denied: true))
        #expect(covered(after: true))
        #expect(covered(opening: true))
    }

    @Test func aRootSheetWaitsForHomeSheetToGo() {
        #expect(!BottomSheet.presents(wanted: true, sheetUp: true))
        #expect(BottomSheet.presents(wanted: true, sheetUp: false))
        #expect(!BottomSheet.presents(wanted: false, sheetUp: false))
    }

    @Test func listAndPickedTripShareOneShortHeight() {
        // The short height depends on the text size only: the same number whichever state shows, so a pick never
        // replaces the detent.
        let compact = HomeSheet.compact(scaled: HomeSheet.compactHeight)
        #expect(compact == HomeSheet.compactHeight)
        #expect(HomeSheet.detent(expanded: false, compact: compact) == .height(300))
        #expect(HomeSheet.detent(expanded: true, compact: compact) == .large)
        #expect(HomeSheet.detents(compact: compact) == [.height(300), .large])
    }

    @Test func theShortHeightGrowsWithTheTextSizeWithinALimit() {
        // Smaller text never goes below the design's height; the largest sizes stop at 1.5x so the tall detent stays tall.
        #expect(HomeSheet.compact(scaled: 250) == HomeSheet.compactHeight)
        #expect(HomeSheet.compact(scaled: 390) == 390)
        #expect(HomeSheet.compact(scaled: 900) == HomeSheet.compactHeight * 1.5)
    }

    @Test func aLateRefitOnlyMovesAPictureThatIsOff() {
        let target = MKCoordinateRegion(center: .init(latitude: 4.0, longitude: 101.0),
                                        span: .init(latitudeDelta: 1.0, longitudeDelta: 0.5))
        // Already there, or a hair off (the thinned route against the full one): no second flight.
        #expect(PickedTripLogic.nearlyShown(centerLatitude: 4.0, centerLongitude: 101.0, latitudeSpan: 1.0, target: target))
        #expect(PickedTripLogic.nearlyShown(centerLatitude: 4.03, centerLongitude: 101.02, latitudeSpan: 1.04, target: target))
        // Still showing the list's fit: the camera goes to the trip.
        #expect(!PickedTripLogic.nearlyShown(centerLatitude: 4.3, centerLongitude: 101.0, latitudeSpan: 1.0, target: target))
        #expect(!PickedTripLogic.nearlyShown(centerLatitude: 4.0, centerLongitude: 101.0, latitudeSpan: 3.0, target: target))
    }

    @Test func theSelectedDetentIsWhatTheSheetReportsBack() {
        // Dragged to the top: tall. Dragged down, or the picked trip's short height: not tall.
        #expect(HomeSheet.isExpanded(.large))
        #expect(!HomeSheet.isExpanded(.height(300)))
        #expect(!HomeSheet.isExpanded(.height(230)))
        // A new short height after the text size changes still reads as short.
        let before = HomeSheet.detent(expanded: false, compact: 300)
        let after = HomeSheet.detent(expanded: false, compact: 390)
        #expect(before != after)
        #expect(!HomeSheet.isExpanded(after))
    }
}

struct PastTripsCacheTests {
    private func entry(_ id: String) -> PastTrips.Entry {
        PastTrips.Entry(id: id, name: id, destination: "D", endedAt: Date(), seenAt: Date(), others: nil)
    }
    private func route(_ id: String) -> PastTripRoute {
        PastTripRoute(id: id, name: id, destinationName: "D", destinationLatitude: 4, destinationLongitude: 101, points: [])
    }

    @Test func loadingOneOlderTripLeavesTheCacheAlone() {
        let cache = ["a": route("a"), "b": route("b"), "old": route("old")]
        #expect(PastTripsMapService.routesToKeep([entry("old")], cache: cache, keeping: false) == nil)
    }

    @Test func loadingTheDrawnTripsKeepsOnlyWhatHomeStillLists() {
        let cache = ["a": route("a"), "b": route("b"), "gone": route("gone")]
        let kept = PastTripsMapService.routesToKeep([entry("a"), entry("b")], cache: cache, keeping: true)
        #expect(kept?.map(\.id) == ["a", "b"])
    }
}
