import ActivityKit
import Foundation

/// The Live Activity's data, shared by the app (which starts and updates it) and the `ikutWidgets` extension (which
/// draws it). No Firebase here: the extension has no access to it.
///
/// The content state carries raw values and a state enum, never sentences (design note 17): names, counts, metres,
/// seconds, dates and track marks. The extension builds the words from the String Catalog, so plurals, Malay and
/// "Aisha's" are right and the state stays far under ActivityKit's 4 KB (`ConvoyActivityLogicTests` encodes the
/// worst case). Nothing here is a coordinate, a car id or a user id: a Lock Screen is read by anyone (note 2).
struct ConvoyActivityAttributes: ActivityAttributes {
    /// One state at a time, most urgent first (note 4). "Not updating" is not here: the system flips `isStale` when
    /// the stale date passes, and `ConvoyActivityPresentation.display` turns that into the greyed state.
    enum Kind: String, Codable, Hashable, CaseIterable, Sendable {
        case sharingPaused, hazardAhead, stopRequest, catchUp, stopped, atStop
        case waiting, joining, parkedAhead, inConvoy
        case arrived, tripEnded
    }

    /// Why a car asked to stop (`StopLogic`), for "Wyna needs fuel" and "Wyna's fuel stop".
    enum Reason: String, Codable, Hashable, Sendable { case fuel, food, toilet, rest }

    /// One car on the track: its place as a fraction of the bar (0 to 1, my car at 0.5) and its colour.
    struct CarMark: Codable, Hashable, Sendable {
        var at: Double
        var color: String
        var isMine = false
    }

    struct ContentState: Codable, Hashable, Sendable {
        var kind: Kind
        var tripName: String
        var destination: String

        // Waiting: how many cars share their location, of how many; the organiser's phone shows the count, a
        // passenger's says who starts.
        var carCount: Int?
        var readyCount: Int?
        var isOrganizer = false
        var organizerName: String?

        // Joining: the place my car meets the convoy, and how far; seconds while it moves, metres while it is slow.
        var place: String?
        var meetsAtDestination = false
        var joinMeters: Double?
        var joinSeconds: Double?

        // In the convoy: the destination, the next planned stop ahead, the spread and the cars next to mine.
        var destinationMeters: Double?
        var destinationSeconds: Double?
        var stopName: String?
        var stopMeters: Double?
        var stopSeconds: Double?
        var spreadMeters: Double?
        var aheadName: String?
        var aheadMeters: Double?
        var behindName: String?
        var behindMeters: Double?

        // Parked ahead, and the heads-up when the car behind is about to arrive.
        var otherName: String?
        var otherMeters: Double?
        var otherSeconds: Double?

        // At a stop: how many are here, of how many, and the times.
        var hereCount: Int?
        var hereTotal: Int?
        var leaveAt: Date?
        var arriveAt: Date?

        // Hazard ahead: the label ("Debris"), who reported it, how far (nil: no fresh fix, no metres).
        var hazardLabel: String?
        var reporterName: String?
        var hazardMeters: Double?

        // Stop request: who, why, how far behind, OKs; also the one line under In the convoy while a request is open.
        var requesterName: String?
        var reason: Reason?
        var requesterMeters: Double?
        var okCount: Int?
        var okTotal: Int?
        var iSaidOK = false
        var iAsked = false

        // Stopped (counts up) and Sharing paused (counts down): the dates, so the phone counts between updates.
        var stoppedSince: Date?
        var mayEndStop = false
        var pausedUntil: Date?

        // Arrived: the drive time and how many cars are in.
        var driveSeconds: Double?
        var arrivedCount: Int?
        var arrivedTotal: Int?

        // The track: my car, the others inside the window, the next stop's ring, the hazard.
        var cars: [CarMark] = []
        var stopRing: Double?
        var hazardMark: Double?

        /// When the newest data from another car arrived: "Not updating since 14:09".
        var dataAt: Date?
    }

    var tripId: String
}
