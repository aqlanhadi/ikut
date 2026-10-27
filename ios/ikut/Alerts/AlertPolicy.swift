import Foundation

/// Decides which events from the stream are new enough and relevant enough to announce.
struct AlertPolicy {
    /// Backlog events (those present when the listener started) are announced only when high
    /// severity and younger than this.
    static let backlogWindow: TimeInterval = 2 * 60

    let myUserId: String
    /// This phone's car: a stop request from it is already known to everyone in it. Set when the member doc arrives,
    /// which can be after the map started listening (a driving map opened on the app's first frame).
    var myCarId: String?
    private(set) var seen: Set<String> = []
    private var primed = false

    init(myUserId: String, myCarId: String? = nil) {
        self.myUserId = myUserId
        self.myCarId = myCarId
    }

    /// Events to announce for this snapshot, most severe first (newest first within a severity).
    /// Marks every event in the snapshot as seen, announced or not.
    mutating func newEvents(from events: [TripEvent], now: Date) -> [TripEvent] {
        let isBacklog = !primed
        primed = true
        var fresh: [TripEvent] = []
        for event in events {
            guard let id = event.id, seen.insert(id).inserted else { continue }
            guard !isMine(event) else { continue }
            if isBacklog {
                let age = event.createdAt.map { now.timeIntervalSince($0) } ?? 0
                guard event.severity == .high, age < Self.backlogWindow else { continue }
            }
            fresh.append(event)
        }
        return Self.ranked(fresh)
    }

    /// Written by this user, or a stop request from this user's car (the car's other phone asks too).
    func isMine(_ event: TripEvent) -> Bool {
        if event.authorId == myUserId { return true }
        return event.category == .stopRequest && myCarId != nil && event.carId == myCarId
    }

    /// Most severe first, then newest first. Stable for equal keys.
    static func ranked(_ events: [TripEvent]) -> [TripEvent] {
        events.enumerated().sorted { a, b in
            if a.element.severity.rank != b.element.severity.rank {
                return a.element.severity.rank > b.element.severity.rank
            }
            let ta = a.element.createdAt ?? .distantFuture
            let tb = b.element.createdAt ?? .distantFuture
            if ta != tb { return ta > tb }
            return a.offset < b.offset
        }.map(\.element)
    }
}

extension Severity {
    var rank: Int {
        switch self {
        case .high: 2
        case .medium: 1
        case .low: 0
        }
    }
}
