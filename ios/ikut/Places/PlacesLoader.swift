import Foundation

/// Reads the places file: the bundled one, or any file in the same format (the hosted refresh, piece 8, passes
/// its downloaded copy to `load(from:)`).
enum PlacesLoader {
    enum LoadError: Error {
        /// The bundle has no `places.json`.
        case missing
        /// A file from a newer format than this build reads.
        case unsupportedVersion(Int)
    }

    private struct Versioned: Decodable { var version: Int }

    /// The file inside the app bundle: works with no signal.
    static func bundled(_ bundle: Bundle = .main) throws -> PlacesFile {
        guard let url = bundle.url(forResource: "places", withExtension: "json") else { throw LoadError.missing }
        return try load(from: url)
    }

    static func load(from url: URL) throws -> PlacesFile {
        try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> PlacesFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        // The version first: a newer file may have a different shape, and must be refused for that, not misread.
        let version = try decoder.decode(Versioned.self, from: data).version
        guard version <= PlacesFile.supportedVersion else { throw LoadError.unsupportedVersion(version) }
        return try decoder.decode(PlacesFile.self, from: data)
    }
}

private extension JSONDecoder.DateDecodingStrategy {
    /// `new Date().toISOString()`: `2026-10-24T03:14:15.926Z`.
    static var iso8601WithFractionalSeconds: Self {
        .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(text)"))
        }
    }
}
