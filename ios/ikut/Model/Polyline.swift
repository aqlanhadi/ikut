import CoreLocation

/// Google encoded polyline algorithm (precision 5).
enum Polyline {
    private static let scale = 1e5

    static func encode(_ coordinates: [CLLocationCoordinate2D]) -> String {
        var result = ""
        var lastLat = 0
        var lastLng = 0
        for c in coordinates {
            let lat = Int((c.latitude * scale).rounded())
            let lng = Int((c.longitude * scale).rounded())
            append(lat - lastLat, to: &result)
            append(lng - lastLng, to: &result)
            lastLat = lat
            lastLng = lng
        }
        return result
    }

    /// Returns an empty array for malformed input rather than partial garbage.
    static func decode(_ string: String) -> [CLLocationCoordinate2D] {
        let bytes = Array(string.utf8)
        var index = 0
        var lat = 0
        var lng = 0
        var result: [CLLocationCoordinate2D] = []
        while index < bytes.count {
            guard let dLat = readValue(bytes, &index), let dLng = readValue(bytes, &index) else { return [] }
            lat += dLat
            lng += dLng
            result.append(CLLocationCoordinate2D(latitude: Double(lat) / scale, longitude: Double(lng) / scale))
        }
        return result
    }

    private static func append(_ value: Int, to result: inout String) {
        var v = value < 0 ? ~(value << 1) : value << 1
        while v >= 0x20 {
            result.unicodeScalars.append(Unicode.Scalar(UInt8((0x20 | (v & 0x1f)) + 63)))
            v >>= 5
        }
        result.unicodeScalars.append(Unicode.Scalar(UInt8(v + 63)))
    }

    private static func readValue(_ bytes: [UInt8], _ index: inout Int) -> Int? {
        var result = 0
        var shift = 0
        while index < bytes.count {
            let b = Int(bytes[index]) - 63
            index += 1
            guard b >= 0, shift < 60 else { return nil }
            result |= (b & 0x1f) << shift
            shift += 5
            if b < 0x20 { return result & 1 != 0 ? ~(result >> 1) : result >> 1 }
        }
        return nil
    }
}
