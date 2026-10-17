import Foundation

/// Links the app understands: `ikut://join/CODE`, `ikut://join?code=CODE` and the
/// future universal-link form `https://<host>/join/CODE`.
enum DeepLink: Equatable {
    case join(code: String)

    static let scheme = "ikut"

    static func parse(_ url: URL) -> DeepLink? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case Self.scheme:
            guard url.host(percentEncoded: false)?.lowercased() == "join" else { return nil }
            let segments = pathSegments(url)
            if segments.count == 1 { return code(segments[0]).map(DeepLink.join) }
            guard segments.isEmpty,
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  let raw = items.first(where: { $0.name == "code" })?.value
            else { return nil }
            return code(raw).map(DeepLink.join)
        case "https":
            guard url.host(percentEncoded: false)?.isEmpty == false else { return nil }
            let segments = pathSegments(url)
            guard segments.count == 2, segments[0].lowercased() == "join" else { return nil }
            return code(segments[1]).map(DeepLink.join)
        default:
            return nil
        }
    }

    /// Code from scanned QR text: any link `parse` accepts, or a bare code.
    static func joinCode(fromScanned text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil, trimmed.contains("://") {
            if case .join(let code)? = parse(url) { return code }
            return nil
        }
        return code(trimmed)
    }

    private static func pathSegments(_ url: URL) -> [String] {
        url.path(percentEncoded: false).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Strips spaces and dashes, then requires exactly a full code in the code alphabet.
    private static func code(_ raw: String) -> String? {
        let stripped = raw.filter { !$0.isWhitespace && $0 != "-" }
        let normalized = JoinService.normalizeCode(stripped)
        guard JoinService.isCompleteCode(normalized), normalized == stripped.uppercased() else { return nil }
        return normalized
    }
}
