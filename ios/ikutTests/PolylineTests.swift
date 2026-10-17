import CoreLocation
import Testing
@testable import ikut

struct PolylineTests {
    private let googleExample = [
        CLLocationCoordinate2D(latitude: 38.5, longitude: -120.2),
        CLLocationCoordinate2D(latitude: 40.7, longitude: -120.95),
        CLLocationCoordinate2D(latitude: 43.252, longitude: -126.453),
    ]
    private let googleString = "_p~iF~ps|U_ulLnnqC_mqNvxq`@"

    @Test func encodesGoogleExample() {
        #expect(Polyline.encode(googleExample) == googleString)
    }

    @Test func decodesGoogleExample() {
        let points = Polyline.decode(googleString)
        #expect(points.count == 3)
        for (a, b) in zip(points, googleExample) {
            #expect(abs(a.latitude - b.latitude) < 1e-5)
            #expect(abs(a.longitude - b.longitude) < 1e-5)
        }
    }

    @Test func roundTripsKualaLumpurToPenang() {
        let route = (0..<200).map {
            CLLocationCoordinate2D(latitude: 3.139 + Double($0) * 0.0123457, longitude: 101.687 - Double($0) * 0.0031415)
        }
        let decoded = Polyline.decode(Polyline.encode(route))
        #expect(decoded.count == route.count)
        for (a, b) in zip(decoded, route) {
            #expect(abs(a.latitude - b.latitude) < 1e-5)
            #expect(abs(a.longitude - b.longitude) < 1e-5)
        }
    }

    @Test func emptyAndMalformedInput() {
        #expect(Polyline.encode([]) == "")
        #expect(Polyline.decode("").isEmpty)
        #expect(Polyline.decode("_p~iF").isEmpty)
    }
}
