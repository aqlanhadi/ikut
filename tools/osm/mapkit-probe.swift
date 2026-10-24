// D4 spike: what MapKit's category search finds along a route, for the comparison with OSM and the PLUS list.
//
//   swift tools/osm/mapkit-probe.swift <route.json> <out.json> [spacing m] [radius m]
//
// Runs on the Mac (MapKit on macOS answers the same as on the phone). Circles of `radius` every `spacing` meters
// along the route, one MKLocalPointsOfInterestRequest each with a category filter, about one request a second
// (Apple throttles). The output is for the spike's comparison table only: Apple's terms do not allow keeping or
// shipping MapKit results, so it stays in the scratch folder and is never committed.

import Foundation
import MapKit

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: mapkit-probe.swift <route.json> <out.json> [spacing] [radius]"); exit(64) }
let spacing = args.count > 3 ? Double(args[3])! : 6_000
let radius = args.count > 4 ? Double(args[4])! : 4_000
/// Only these circles (a rerun of throttled ones), merged into an existing out file.
let only: Set<Int>? = args.count > 5 ? Set(args[5].split(separator: ",").compactMap { Int($0) }) : nil

struct Route: Decodable { var coordinates: [[Double]] }
let route = try JSONDecoder().decode(Route.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let points = route.coordinates.map { CLLocation(latitude: $0[1], longitude: $0[0]) }

// Centres every `spacing` meters along the line.
var centres: [CLLocationCoordinate2D] = [points[0].coordinate]
var carried = 0.0
for i in 1..<points.count {
    var a = points[i - 1]
    let b = points[i]
    var seg = a.distance(from: b)
    while carried + seg >= spacing {
        let t = (spacing - carried) / seg
        let c = CLLocationCoordinate2D(
            latitude: a.coordinate.latitude + t * (b.coordinate.latitude - a.coordinate.latitude),
            longitude: a.coordinate.longitude + t * (b.coordinate.longitude - a.coordinate.longitude))
        centres.append(c)
        a = CLLocation(latitude: c.latitude, longitude: c.longitude)
        seg = a.distance(from: b)
        carried = 0
    }
    carried += seg
}

var categories: [MKPointOfInterestCategory] = [.gasStation, .restroom, .restaurant, .evCharger, .parking, .cafe]
if #available(macOS 27.0, *) { categories += [.restArea, .picnicArea] }

struct FoundIn: Decodable { var name: String; var category: String; var latitude: Double; var longitude: Double; var circle: Int }
struct Found: Encodable { var name: String; var category: String; var latitude: Double; var longitude: Double; var circle: Int }
var found: [String: Found] = [:]
if only != nil, let old = try? Data(contentsOf: URL(fileURLWithPath: args[2])),
   let rows = try? JSONDecoder().decode([FoundIn].self, from: old) {
    for r in rows { found[String(format: "%@|%.5f,%.5f", r.name, r.latitude, r.longitude)] = Found(name: r.name, category: r.category, latitude: r.latitude, longitude: r.longitude, circle: r.circle) }
}
var failures = 0
for (i, c) in centres.enumerated() where only?.contains(i) ?? true {
    let request = MKLocalPointsOfInterestRequest(center: c, radius: radius)
    request.pointOfInterestFilter = MKPointOfInterestFilter(including: categories)
    do {
        let response = try await MKLocalSearch(request: request).start()
        for item in response.mapItems {
            let p = item.placemark.coordinate
            let key = String(format: "%@|%.5f,%.5f", item.name ?? "", p.latitude, p.longitude)
            found[key] = Found(
                name: item.name ?? "", category: item.pointOfInterestCategory?.rawValue ?? "",
                latitude: p.latitude, longitude: p.longitude, circle: i)
        }
    } catch {
        failures += 1
        FileHandle.standardError.write("circle \(i): \(error.localizedDescription)\n".data(using: .utf8)!)
    }
    try await Task.sleep(nanoseconds: (only == nil ? 1_300_000_000 : 4_000_000_000))
}
let out = Array(found.values).sorted { $0.circle < $1.circle }
try JSONEncoder().encode(out).write(to: URL(fileURLWithPath: args[2]))
print("\(centres.count) circles, \(out.count) places, \(failures) failed requests")
