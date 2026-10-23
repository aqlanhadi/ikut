import FirebaseFirestore

/// What a car said about a stop. D25 5a writes `skip` ("we'll skip this stop"); D4 adds `carryOn` for a chosen
/// stop, in the same document.
enum StopAnswerKind: String, Codable, Sendable, Equatable {
    case skip
}

/// `trips/{tripId}/stops/{stopId}/answers/{carId}`: a car's answer about one stop. One per car: the document id
/// is the car id, so a second phone in the car writes the same document. Undo deletes it.
struct StopAnswer: Codable, Sendable, Equatable, Identifiable {
    /// The car id.
    @DocumentID var id: String?
    var answer: StopAnswerKind
    /// Who tapped it for the car.
    var userId: String
    @ServerTimestamp var at: Date?
}
