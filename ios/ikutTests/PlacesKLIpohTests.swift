import CoreLocation
import Foundation
import Testing
@testable import ikut

private final class FixtureToken {}

/// The bundled places file on real drives: KL (Jalan Kuching) to Ipoh and back, as two routes from OSRM
/// (`Fixtures/kl-ipoh-*.json`, simplified to 20 m). The south line is its own drive, not the north line reversed:
/// the carriageways differ.
@Suite("Places on KL to Ipoh")
struct PlacesKLIpohTests {
    struct Drive: Decodable { var seconds: Double; var coordinates: [[Double]] }

    static let file = try! PlacesLoader.bundled()

    static func drive(_ name: String) -> (line: RouteLine, seconds: Double) {
        let url = Bundle(for: FixtureToken.self).url(forResource: name, withExtension: "json")!
        let d = try! JSONDecoder().decode(Drive.self, from: Data(contentsOf: url))
        return (RouteLine(d.coordinates.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }), d.seconds)
    }

    static func along(_ line: RouteLine) -> [PlaceAlong] {
        PlaceSide.along(sites: file.sites, fuel: file.fuel, line: line)
    }

    static func suggest(_ name: String) -> (rows: [PlaceAlong], picks: [StopSuggestion]) {
        let (line, seconds) = drive(name)
        let rows = along(line)
        return (rows, SuggestStops.suggest(candidates: rows, routeLength: line.length, routeSeconds: seconds))
    }

    @Test func goingNorthSuggestsTapah() {
        let (rows, picks) = Self.suggest("kl-ipoh-north")
        #expect(picks.count == 1)
        #expect(picks.first?.place.name?.contains("Tapah") == true)
        #expect(picks.first?.place.ours == true)
        #expect(rows.contains { $0.ours })
    }

    @Test func goingSouthSuggestsUluBernam() {
        let (_, picks) = Self.suggest("kl-ipoh-south")
        #expect(picks.count == 1)
        #expect(picks.first?.place.name?.contains("Ulu Bernam") == true)
    }

    /// The plain OSRM routes do not pass under the Sungai Buloh bridge today (the north one keeps to the west edge,
    /// the south one leaves the highway 1.4 km before it, as the discovery page found), so the bridge is tested on
    /// the 4 km of a route that OSRM draws through it (`Fixtures/sungai-buloh-north.json`), driven both ways. The
    /// outline spans the road, so which carriageway the line follows does not matter to the answer.
    @Test func sungaiBulohOverheadIsOursBothWays() throws {
        let north = Self.drive("sungai-buloh-north").line
        let south = RouteLine(north.coordinates.reversed())
        for (name, line, heading) in [("north", north, 320.0), ("south", south, 140.0)] {
            let overall = PlaceSide.bearing(line.coordinates.first!, line.coordinates.last!)
            #expect(PlaceSide.angleBetween(overall, heading) < 30, "\(name)")
            let row = try #require(Self.along(line).first { $0.id == "relation/11949586" }, "\(name): not along the route")
            #expect(row.side == .both && row.ours, "\(name)")
        }
    }

    @Test func tapahIsOursOnlyOnTheSideOfTheDirection() throws {
        let north = Self.along(Self.drive("kl-ipoh-north").line).filter { $0.name == "Tapah Rest Area" && $0.kind == .services }
        let south = Self.along(Self.drive("kl-ipoh-south").line).filter { $0.name == "Tapah Rest Area" && $0.kind == .services }
        #expect(Set(north.filter(\.ours).map(\.id)).count == 1)
        #expect(Set(south.filter(\.ours).map(\.id)).count == 1)
        #expect(Set(north.filter(\.ours).map(\.id)) != Set(south.filter(\.ours).map(\.id)))
    }

    @Test func alongTimingOnTheWholeCountryFile() {
        let line = Self.drive("kl-ipoh-north").line
        let start = ContinuousClock.now
        let rows = Self.along(line)
        let took = ContinuousClock.now - start
        print("D4 along KL-Ipoh: \(rows.count) places in \(took)")
        #expect(took < .seconds(5))
    }
}
