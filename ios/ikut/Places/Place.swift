import CoreLocation
import Foundation

/// The places file the app bundles (`Resources/places.json`, built from OpenStreetMap by `tools/osm/extract.mjs`,
/// ODbL: see `README-places.md`): every services area, rest area and fuel station in Malaysia with what each has.
/// What the file holds is exactly what the side-of-road, overhead-bridge, R&R-or-lay-by, Suggest-stops and
/// stop-request logic reads (`tools/osm/places.mjs` is the tested reference of it).
struct PlacesFile: Decodable, Sendable {
    var version: Int
    var generatedAt: Date
    var source: String
    var license: String
    /// Services areas and rest areas, by latitude.
    var sites: [PlaceSite]
    /// Fuel stations that are not part of a services area (a town pump, or one mapped on its own), by latitude.
    var fuel: [FuelStation]

    private enum CodingKeys: String, CodingKey { case version, generatedAt, source, license, sites, fuel }

    /// A hosted file may be newer than the app in what it lists (a new kind of place, a new facility), never in its
    /// shape (that is a `version` bump). A site of a kind this build does not know is skipped, as is an unknown
    /// facility on a site, instead of the whole file being refused.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        source = try c.decode(String.self, forKey: .source)
        license = try c.decode(String.self, forKey: .license)
        sites = try c.decode([MaybeSite].self, forKey: .sites).compactMap(\.site)
        fuel = try c.decode([FuelStation].self, forKey: .fuel)
    }

    /// The newest file format this build reads. A hosted file with a higher `version` is ignored.
    static let supportedVersion = 1
}

enum PlaceSiteKind: String, Decodable, Sendable {
    /// `highway=services`: fuel, food, toilets and parking by the OSM wiki's definition.
    case services
    /// `highway=rest_area`: parking and maybe toilets, no fuel.
    case restArea = "rest_area"
}

/// One entry of `sites`: nil for a kind this build does not know.
private struct MaybeSite: Decodable {
    var site: PlaceSite?
    init(from decoder: any Decoder) throws {
        do { site = try PlaceSite(from: decoder) } catch is PlaceSite.UnknownKind { site = nil }
    }
}

enum PlaceFacility: String, Decodable, Sendable {
    case fuel, food, toilets, ev
}

/// A services area or rest area.
struct PlaceSite: Decodable, Sendable, Identifiable {
    /// The OpenStreetMap element, e.g. `way/339101076`.
    var id: String
    var kind: PlaceSiteKind
    var name: String?
    /// Where the place is (the middle of its outline).
    var coordinate: CLLocationCoordinate2D
    /// The outline (closed: the last point is the first), when it is mapped as an area. The side test and the
    /// overhead-bridge check read it.
    var ring: [CLLocationCoordinate2D]?
    var facilities: Set<PlaceFacility>
    var brands: [String]
    /// Where traffic turns off the motorway toward the place, and where it rejoins.
    var entries: [PlaceSlipRoad]
    var exits: [PlaceSlipRoad]

    struct UnknownKind: Error {}

    private enum CodingKeys: String, CodingKey { case id, kind, name, at, ring, facilities, brands, entries, exits }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        guard let kind = PlaceSiteKind(rawValue: try c.decode(String.self, forKey: .kind)) else { throw UnknownKind() }
        self.kind = kind
        name = try c.decodeIfPresent(String.self, forKey: .name)
        coordinate = try c.decode(CoordinatePair.self, forKey: .at).coordinate
        ring = try c.decodeIfPresent([CoordinatePair].self, forKey: .ring)?.map(\.coordinate)
        facilities = Set(try c.decode([String].self, forKey: .facilities).compactMap(PlaceFacility.init(rawValue:)))
        brands = try c.decodeIfPresent([String].self, forKey: .brands) ?? []
        entries = try c.decodeIfPresent([PlaceSlipRoad].self, forKey: .entries) ?? []
        exits = try c.decodeIfPresent([PlaceSlipRoad].self, forKey: .exits) ?? []
    }

    init(id: String, kind: PlaceSiteKind, name: String?, coordinate: CLLocationCoordinate2D,
         ring: [CLLocationCoordinate2D]? = nil, facilities: Set<PlaceFacility>, brands: [String] = [],
         entries: [PlaceSlipRoad] = [], exits: [PlaceSlipRoad] = []) {
        self.id = id; self.kind = kind; self.name = name; self.coordinate = coordinate; self.ring = ring
        self.facilities = facilities; self.brands = brands; self.entries = entries; self.exits = exits
    }
}

/// One slip road between the motorway and a place: `[junctionLat, junctionLon, bearing, gateLat, gateLon, meters]`
/// in the file.
struct PlaceSlipRoad: Decodable, Sendable {
    /// The motorway point where the slip road meets the carriageway.
    var junction: CLLocationCoordinate2D
    /// The carriageway's bearing there, degrees clockwise from north: it says which way that carriageway runs.
    var bearing: Double
    /// Where the slip road reaches the place: the point to route to.
    var gate: CLLocationCoordinate2D
    /// Road meters between the gate and the junction.
    var meters: Double

    init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let junctionLatitude = try c.decode(Double.self), junctionLongitude = try c.decode(Double.self)
        bearing = try c.decode(Double.self)
        let gateLatitude = try c.decode(Double.self), gateLongitude = try c.decode(Double.self)
        meters = try c.decode(Double.self)
        junction = CLLocationCoordinate2D(latitude: junctionLatitude, longitude: junctionLongitude)
        gate = CLLocationCoordinate2D(latitude: gateLatitude, longitude: gateLongitude)
    }

    init(junction: CLLocationCoordinate2D, bearing: Double, gate: CLLocationCoordinate2D, meters: Double) {
        self.junction = junction; self.bearing = bearing; self.gate = gate; self.meters = meters
    }
}

/// A fuel station on its own: `[id, lat, lon, name]` in the file. It has fuel and nothing else; `name` is its brand.
struct FuelStation: Decodable, Sendable, Identifiable {
    var id: String
    var coordinate: CLLocationCoordinate2D
    var name: String?

    init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        id = try c.decode(String.self)
        let latitude = try c.decode(Double.self), longitude = try c.decode(Double.self)
        coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        name = try c.decodeIfPresent(String.self)
    }

    init(id: String, coordinate: CLLocationCoordinate2D, name: String?) {
        self.id = id; self.coordinate = coordinate; self.name = name
    }
}

/// `[latitude, longitude]` in the file.
private struct CoordinatePair: Decodable {
    var coordinate: CLLocationCoordinate2D
    init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let latitude = try c.decode(Double.self), longitude = try c.decode(Double.self)
        coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
