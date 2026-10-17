import Foundation

/// Decides which events from the stream are new enough and relevant enough to announce.
struct AlertPolicy {
    /// Backlog events (those present when the listener started) are announced only when high
    /// severity and younger than this.
    static let backlogWindow: TimeInterval = 2 * 60

    let myUserId: String
    private(set) var seen: Set<String> = []
    private var primed = false
    private var pinnedSeen: Set<String> = []

    init(myUserId: String) {
        self.myUserId = myUserId
    }

    /// Events to announce for this snapshot, most severe first (newest first within a severity).
    /// Marks every event in the snapshot as seen, announced or not.
    mutating func newEvents(from events: [TripEvent], now: Date) -> [TripEvent] {
        let isBacklog = !primed
        primed = true
        var fresh: [TripEvent] = []
        for event in events {
            guard let id = event.id, seen.insert(id).inserted else { continue }
            guard event.authorId != myUserId else { continue }
            if isBacklog {
                let age = event.createdAt.map { now.timeIntervalSince($0) } ?? 0
                guard event.severity == .high, age < Self.backlogWindow else { continue }
            }
            fresh.append(event)
        }
        return Self.ranked(fresh)
    }

    /// Stop requests that have a pinned place, once each, for events other than the viewer's own.
    /// Call after `newEvents` with its result as `fresh`: a request announced in this same snapshot
    /// is not repeated, and the caller decides whether the request was announced at all.
    mutating func newlyPinned(from events: [TripEvent], excluding fresh: [TripEvent]) -> [TripEvent] {
        let freshIds = Set(fresh.compactMap(\.id))
        var out: [TripEvent] = []
        for event in events {
            guard event.category == .stopRequest, event.place != nil, let id = event.id,
                  pinnedSeen.insert(id).inserted, event.authorId != myUserId, !freshIds.contains(id)
            else { continue }
            out.append(event)
        }
        return out
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
