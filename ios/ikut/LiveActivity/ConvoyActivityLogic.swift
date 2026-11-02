import Foundation

/// A snapshot of the convoy as plain values, taken by `ConvoyActivityInput.snapshot` from the models the map reads
/// (`ConvoyModel`, `NextStop`, `StopArrival`, `StopLeave`, `StopLogic`…), and `ConvoyActivityLogic.state` which turns it
/// into the one state the Live Activity shows (D3 piece 2a). Pure: no Firebase, no clock but `now`.
struct ConvoyActivityInput: Equatable {
    typealias Reason = ConvoyActivityAttributes.Reason

    /// A car in the convoy, front car first (`ConvoySnapshot.convoy`).
    struct Dot: Equatable {
        /// The owner's first name ("Aisha"), not the car's.
        var name: String
        var color: String
        /// Meters along the main route.
        var offset: Double
        /// Meters to the car ahead (`ConvoyEntry.gap`); nil for the front car.
        var gapAhead: Double?
        var isMine = false
    }

    /// The next planned stop ahead (`NextStop.Cell`) with its place on the route.
    struct Stop: Equatable {
        var name: String
        var offset: Double
        var meters: Double
        var seconds: Double?
        var isHere: Bool
    }

    struct StopHere: Equatable {
        var here: Int
        var total: Int
        /// `StopLeave.leavingAt`; nil when the stop has no planned stay.
        var leaveAt: Date?
        /// Seconds still to go from the stop to the destination (the panel's pace over the road left after the stop).
        var toGoSeconds: Double?
    }

    struct Hazard: Equatable {
        /// The event type as stored ("debris").
        var type: String
        var reporter: String?
        /// Meters to it along the route; nil without a fresh fix of my car (the state then says no metres).
        var meters: Double?
        var offset: Double?
    }

    struct Request: Equatable {
        var requesterName: String
        var reason: Reason
        /// Meters from my car to the asking car, positive when it is ahead.
        var meters: Double?
        var okCount: Int
        var total: Int
        var iSaidOK: Bool
        var iAsked: Bool
        /// Another car asked and my car has not said OK.
        var owesMyAnswer: Bool
        /// When it first needed my OK on this phone: the full state lasts `ConvoyActivityLogic.requestWindow` from here.
        var since: Date
    }

    struct Heads: Equatable {
        var name: String
        var meters: Double
        var seconds: Double?
    }

    struct Arrived: Equatable {
        var count: Int
        var total: Int
        var driveSeconds: Double?
    }

    struct Joining: Equatable {
        var place: String?
        var meetsAtDestination: Bool
        var amount: ConvoyFormat.JoinAmount?
    }

    var now: Date
    var tripName: String
    var destination: String
    var tripStarted = true
    var tripEnded = false
    var isOrganizer = false
    var organizerName: String?
    var carCount = 0
    var readyCars = 0
    /// Sharing paused: when the pause ends.
    var pausedUntil: Date?
    /// When the newest position of any other car arrived.
    var newestOtherData: Date?
    /// My car in the convoy, with the cars in order; nil while it is joining or before it has a place.
    var dots: [Dot] = []
    var myOffset: Double?
    var arrived: Arrived?
    var destinationMeters: Double?
    var destinationSeconds: Double?
    var spreadMeters: Double?
    var nextStop: Stop?
    var stopHere: StopHere?
    var joining: Joining?
    var hazard: Hazard?
    var request: Request?
    var headsUp: Heads?
    /// My car is parked ahead and the nearest car behind is far off.
    var parkedAhead: Heads?
    var convoyStopSince: Date?
    var mayEndConvoyStop = false
}

enum ConvoyActivityLogic {
    typealias State = ConvoyActivityAttributes.ContentState
    typealias Kind = ConvoyActivityAttributes.Kind

    /// The full Stop request state lasts this long from when it first needed my OK (note 12); then the activity goes
    /// back to In the convoy and says nothing of it.
    static let requestWindow: TimeInterval = 2 * 60
    /// The track is a window of 10 km each side of my car (1 km = 5% of the bar), 1 km on Hazard ahead (note 5).
    static let windowMeters: Double = 10_000
    static let hazardWindowMeters: Double = 1_000

    /// Which state shows, in the order of note 4. Arrived and Trip ended are the last update, so they end the
    /// activity whatever else was true (a paused or stopped car that has arrived has arrived). "Not updating" is not
    /// here: it is the system's stale flag (`ConvoyActivityPresentation.display`).
    static func kind(_ i: ConvoyActivityInput) -> Kind {
        if i.arrived != nil { return .arrived }
        if i.tripEnded { return .tripEnded }
        if i.pausedUntil != nil { return .sharingPaused }
        if i.hazard != nil { return .hazardAhead }
        if let r = i.request, r.owesMyAnswer, i.now.timeIntervalSince(r.since) < requestWindow { return .stopRequest }
        if i.headsUp != nil { return .catchUp }
        if i.convoyStopSince != nil { return .stopped }
        if i.nextStop?.isHere == true { return .atStop }
        if !i.tripStarted { return .waiting }
        if i.joining != nil, i.myOffset == nil { return .joining }
        if i.parkedAhead != nil { return .parkedAhead }
        return .inConvoy
    }

    /// The date after which the system calls the activity stale (note 6): the newest other-car data plus 2 minutes,
    /// not this phone's last send (offline, its own GPS would keep resetting it). With no other car's data yet (a car
    /// alone, the lobby before the others share) it is 2 minutes from this update, so it still goes grey when this
    /// phone stops updating. Sharing paused ends at the pause's end; Arrived and Trip ended have none.
    static func staleDate(_ i: ConvoyActivityInput, kind: Kind) -> Date? {
        switch kind {
        case .arrived, .tripEnded: return nil
        case .sharingPaused: return i.pausedUntil
        default: return (i.newestOtherData ?? i.now).addingTimeInterval(ConvoyActivityPresentation.staleAfter)
        }
    }

    static func state(_ i: ConvoyActivityInput) -> (state: State, staleDate: Date?) {
        let kind = kind(i)
        var s = State(kind: kind, tripName: i.tripName, destination: i.destination)
        s.dataAt = i.newestOtherData ?? i.now
        switch kind {
        case .sharingPaused:
            s.pausedUntil = i.pausedUntil
        case .arrived:
            s.driveSeconds = i.arrived?.driveSeconds
            s.arrivedCount = i.arrived?.count
            s.arrivedTotal = i.arrived?.total
            s.dataAt = nil
        case .tripEnded:
            s.dataAt = nil
        case .waiting:
            s.carCount = i.carCount
            s.readyCount = i.readyCars
            s.isOrganizer = i.isOrganizer
            s.organizerName = i.organizerName
        case .joining:
            s.place = i.joining?.place
            switch i.joining?.amount {
            case .distance(let meters): s.joinMeters = meters
            case .time(let seconds): s.joinSeconds = seconds
            case nil: break
            }
            s.meetsAtDestination = i.joining?.meetsAtDestination == true
            if s.meetsAtDestination { s.place = nil }
        case .hazardAhead:
            let h = i.hazard
            s.hazardType = h?.type
            s.reporterName = h?.reporter
            s.hazardMeters = h?.meters.map { ($0 / 50).rounded() * 50 }
            applyTrack(&s, i, window: hazardWindowMeters, ring: nil, hazard: h?.offset)
        case .stopRequest:
            applyRequest(&s, i.request)
        case .catchUp:
            s.otherName = i.headsUp?.name
            s.otherMeters = i.headsUp?.meters
            s.otherSeconds = i.headsUp?.seconds
            applyTrack(&s, i, window: windowMeters, ring: nil, hazard: nil)
        case .stopped:
            s.stoppedSince = i.convoyStopSince
            s.mayEndStop = i.mayEndConvoyStop
            if i.nextStop?.isHere == true { s.stopName = i.nextStop?.name }
        case .atStop:
            s.stopName = i.nextStop?.name
            s.hereCount = i.stopHere?.here
            s.hereTotal = i.stopHere?.total
            s.leaveAt = i.stopHere?.leaveAt
            s.toGoSeconds = i.stopHere?.toGoSeconds
            applyTrack(&s, i, window: windowMeters, ring: nil, hazard: nil)
        case .parkedAhead:
            s.otherName = i.parkedAhead?.name
            s.otherMeters = i.parkedAhead?.meters
            applyTrack(&s, i, window: windowMeters, ring: nil, hazard: nil)
        case .inConvoy:
            s.destinationMeters = i.destinationMeters
            s.spreadMeters = i.spreadMeters
            // The big value is the next planned stop's time when one is ahead, else the destination's (notes 11, 19):
            // stop lengths vary, so a time to the destination is never shown while a stop is ahead.
            if let stop = i.nextStop {
                s.stopName = stop.name
                s.stopMeters = stop.meters
                s.stopSeconds = stop.seconds
            } else {
                s.destinationSeconds = i.destinationSeconds
            }
            applyGaps(&s, i)
            // After my OK, or while my own request is open, one line takes the Next stop slot (note 12). A request still
            // waiting on my OK that nobody answered in its 2 minutes leaves nothing here: the app and the notification ask.
            if let r = i.request, !r.owesMyAnswer { applyRequest(&s, r) }
            applyTrack(&s, i, window: windowMeters, ring: i.nextStop?.offset, hazard: nil)
        }
        return (s, staleDate(i, kind: kind))
    }

    private static func applyRequest(_ s: inout State, _ r: ConvoyActivityInput.Request?) {
        guard let r else { return }
        s.requesterName = r.requesterName
        s.reason = r.reason
        s.requesterMeters = r.meters
        s.okCount = r.okCount
        s.okTotal = r.total
        s.iSaidOK = r.iSaidOK
        s.iAsked = r.iAsked
    }

    /// The cars next to mine, one form both ways: the first half is left out when I lead, the second when I am last.
    private static func applyGaps(_ s: inout State, _ i: ConvoyActivityInput) {
        guard let me = i.dots.firstIndex(where: \.isMine) else { return }
        if me > 0, let gap = i.dots[me].gapAhead {
            s.aheadName = i.dots[me - 1].name
            s.aheadMeters = gap
        }
        if me + 1 < i.dots.count, let gap = i.dots[me + 1].gapAhead {
            s.behindName = i.dots[me + 1].name
            s.behindMeters = gap
        }
    }

    /// My car at the middle, every other car inside the window, the stop's ring and the hazard; one outside the window
    /// is left off (the gap line and the subtitle carry it), except the hazard, which is the point of its state and
    /// stays at the edge.
    private static func applyTrack(_ s: inout State, _ i: ConvoyActivityInput, window: Double, ring: Double?, hazard: Double?) {
        guard let mine = i.myOffset else { return }
        func place(_ offset: Double) -> Double { 0.5 + (offset - mine) / (2 * window) }
        func round2(_ f: Double) -> Double { (f * 100).rounded() / 100 }
        for dot in i.dots {
            let f = dot.isMine ? 0.5 : place(dot.offset)
            guard (0...1).contains(f) else { continue }
            s.cars.append(.init(at: round2(f), color: dot.color, isMine: dot.isMine))
        }
        if !s.cars.contains(where: \.isMine) { s.cars.append(.init(at: 0.5, color: "", isMine: true)) }
        if let ring, (0...1).contains(place(ring)) { s.stopRing = round2(place(ring)) }
        if let hazard { s.hazardMark = round2(min(1, max(0, place(hazard)))) }
    }
}
