import FirebaseFirestore

enum MemberRole: String, Codable, Sendable, Equatable {
    case organizer
    case member
}

/// `trips/{tripId}/members/{userId}`.
struct Member: Codable, Sendable, Equatable, Identifiable {
    @DocumentID var id: String?
    var displayName: String
    var carId: String
    var role: MemberRole
    var pushToken: String?
}
