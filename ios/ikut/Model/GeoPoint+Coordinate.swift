import CoreLocation
import FirebaseFirestore

extension GeoPoint {
    /// The same place as a MapKit/CoreLocation coordinate.
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
