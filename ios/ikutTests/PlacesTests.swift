import CoreLocation
import Foundation
import Testing
@testable import ikut

@Suite("Places file")
struct PlacesTests {
    static let file = try! PlacesLoader.bundled()

    @Test func bundledFileIsSmallAndCurrent() throws {
        let url = try #require(Bundle.main.url(forResource: "places", withExtension: "json"))
        let bytes = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(bytes < 300 * 1024)
        #expect(Self.file.version == PlacesFile.supportedVersion)
        #expect(Self.file.license.contains("ODbL"))
        // Malaysia has hundreds of services and rest areas and thousands of pumps; a file far below that is broken.
        #expect(Self.file.sites.count > 300)
        #expect(Self.file.fuel.count > 3_000)
        #expect(Self.file.sites.allSatisfy { $0.coordinate.latitude > -1 && $0.coordinate.latitude < 8 })
    }

    @Test func rrTapahIsThereOnBothCarriageways() {
        let tapah = Self.file.sites.filter { $0.name == "Tapah Rest Area" && $0.kind == .services }
        #expect(tapah.count == 2)
        // Each side is its own place with its own outline, slip roads, and fuel.
        #expect(Set(tapah.map(\.id)) == ["way/339101076", "way/339101077"])
        for place in tapah {
            #expect(place.facilities.isSuperset(of: [.fuel, .food, .toilets]))
            #expect((place.ring?.count ?? 0) >= 4)
            #expect(place.ring?.first?.latitude == place.ring?.last?.latitude)
            #expect(!place.entries.isEmpty && !place.exits.isEmpty)
        }
        // The two sides are on opposite carriageways: a slip road of one runs north-west (about 325 degrees), the
        // other's south-east (about 145).
        let bearings = tapah.flatMap { $0.entries.map(\.bearing) }
        #expect(bearings.contains { abs($0 - 325) < 20 } && bearings.contains { abs($0 - 145) < 20 })
    }

    @Test func sungaiBulohOverheadIsOneOutlineAcrossTheRoad() throws {
        let place = try #require(Self.file.sites.first { $0.id == "relation/11949586" })
        #expect(place.kind == .services)
        #expect(place.name?.contains("Overhead Bridge") == true)
        #expect(place.facilities.contains(.fuel))
        // The outline reaches over both carriageways of the E1 (about 100 m of longitude apart).
        let longitudes = try #require(place.ring).map(\.longitude)
        #expect((longitudes.max()! - longitudes.min()!) * 111_000 * cos(3.19 * .pi / 180) > 300)
    }

    @Test func lonePumpsCarryOnlyABrand() throws {
        let pump = try #require(Self.file.fuel.first { $0.name != nil })
        #expect(pump.id.hasPrefix("n") || pump.id.hasPrefix("w") || pump.id.hasPrefix("r"))
        #expect(pump.coordinate.latitude != 0)
    }

    @Test func decodesTheDocumentedShape() throws {
        let json = """
        {"version":1,"generatedAt":"2026-10-24T03:14:15.926Z","source":"Geofabrik","license":"ODbL",
         "sites":[{"id":"way/1","kind":"rest_area","name":null,"at":[3.5,101.5],"facilities":["toilets"]},
                  {"id":"way/2","kind":"services","name":"Test","at":[3.6,101.5],
                   "ring":[[3.6,101.5],[3.6,101.6],[3.7,101.6],[3.6,101.5]],"facilities":["fuel","ev"],"brands":["Shell"],
                   "entries":[[3.59,101.49,320,3.595,101.495,300]],"exits":[[3.61,101.49,321,3.605,101.495,250]]}],
         "fuel":[["n9",3.1,101.1,"Petronas"],["w10",3.2,101.2,null]]}
        """
        let file = try PlacesLoader.decode(Data(json.utf8))
        #expect(file.sites.count == 2 && file.fuel.count == 2)
        #expect(file.sites[0].kind == .restArea && file.sites[0].name == nil && file.sites[0].entries.isEmpty)
        #expect(file.sites[1].facilities == [.fuel, .ev] && file.sites[1].brands == ["Shell"])
        #expect(file.sites[1].entries[0].gate.latitude == 3.595 && file.sites[1].entries[0].meters == 300)
        #expect(file.sites[1].exits[0].bearing == 321)
        #expect(file.fuel[1].name == nil && file.fuel[0].coordinate.longitude == 101.1)
        #expect(file.generatedAt.timeIntervalSince1970 > 1_700_000_000)
    }

    @Test func aNewerFormatIsRefusedNotMisread() {
        let json = #"{"version":2,"generatedAt":"2026-10-24T03:14:15Z","source":"x","license":"x","sites":[],"fuel":[]}"#
        #expect(throws: PlacesLoader.LoadError.self) { try PlacesLoader.decode(Data(json.utf8)) }
    }

    @Test func aBrokenFileThrows() {
        #expect(throws: (any Error).self) { try PlacesLoader.decode(Data("not json".utf8)) }
    }
}
