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

/// Reading a stop's answers. Pure; 5b wires it into the arrival count and Leave.
enum SkipAnswers {
    /// The car ids that said they are skipping this stop. Pass `among` (the cars still in the trip) to leave out
    /// answers from cars that are gone, or nil to take every answer as it is.
    static func skipping(_ answers: [StopAnswer], among carIds: Set<String>? = nil) -> Set<String> {
        Set(answers.compactMap { answer in
            guard answer.answer == .skip, let id = answer.id else { return nil }
            if let carIds, !carIds.contains(id) { return nil }
            return id
        })
    }

    /// Whether the car has said it is skipping.
    static func isSkipping(carId: String, in answers: [StopAnswer]) -> Bool {
        skipping(answers).contains(carId)
    }

    /// The viewer's car may say "we'll skip": it is not the lead car, the stop is not skipped for everyone, and
    /// the car is still more than the here-radius short of it (the rules check the same, from the car's last
    /// reported place). `carOffset` is its place on the main route, nil before it has merged.
    static func canSkip(stop: PlannedStop, isLeadCar: Bool, carOffset: Double?, tripStarted: Bool) -> Bool {
        guard tripStarted, !isLeadCar, stop.isActive else { return false }
        guard let carOffset else { return true }
        return carOffset < stop.routeOffset - NextStop.hereRadius
    }
}
