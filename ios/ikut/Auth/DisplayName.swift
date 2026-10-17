import Foundation

/// Rules for the name other cars see in the convoy.
enum DisplayName {
    static let maxLength = 30

    enum ValidationError: Error, Equatable, LocalizedError {
        case empty
        case tooLong(max: Int)

        var errorDescription: String? {
            switch self {
            case .empty: "Enter a name so the convoy knows who you are."
            case .tooLong(let max): "Keep your name to \(max) characters or fewer."
            }
        }
    }

    /// Trims, collapses internal whitespace runs to one space, and checks length
    /// (counted in user-perceived characters, so an emoji is one).
    static func validate(_ raw: String) -> Result<String, ValidationError> {
        let cleaned = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if cleaned.isEmpty { return .failure(.empty) }
        if cleaned.count > maxLength { return .failure(.tooLong(max: maxLength)) }
        return .success(cleaned)
    }
}
