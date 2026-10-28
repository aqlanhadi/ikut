import CoreLocation
import Foundation

/// What `TripSession` needs from `TrackingService`; tests substitute a fake.
@MainActor
protocol TrackingControlling: AnyObject {
    var isTracking: Bool { get }
    func start(tripId: String, carId: String, mainRoute: RouteLine, carRoute: RouteLine?)
    /// Called with every fix that was published while tracking.
    var onFix: ((LocationFix) -> Void)? { get set }
    /// One fix without starting to track; nil if cancelled or unavailable.
    func firstFix() async -> LocationFix?
    /// Must stop location updates synchronously.
    func stop()
}

extension TrackingService: TrackingControlling {}

/// Defaults so simple conformers (previews, no-op fakes) need not implement the fix hooks.
extension TrackingControlling {
    var onFix: ((LocationFix) -> Void)? {
        get { nil }
        set {}
    }
    func firstFix() async -> LocationFix? { nil }
}

/// What `TripSession` needs from `CarRouteService`; tests substitute a fake.
@MainActor
protocol CarRouteControlling: AnyObject {
    var routeLine: RouteLine? { get }
    func ensureRoute(at location: CLLocationCoordinate2D) async throws -> CarRoutePlan
    func handle(fix: LocationFix) async -> CarRouteEvent
}

extension CarRouteService: CarRouteControlling {}

/// Writes (a date) or clears (nil) `pausedAt` on the car doc; tests substitute a fake.
typealias PauseWriter = @MainActor (_ carId: String, _ pausedAt: Date?) async throws -> Void

/// One write of Leave trip: give up sharing for the car, then delete this phone's member doc.
enum LeaveStep: Equatable {
    case releaseTracker(carId: String)
    case deleteMember
}

/// Does one Leave step against the server; tests substitute a fake.
typealias LeaveWriter = @MainActor (LeaveStep) async throws -> Void

/// Leave trip couldn't reach the server: the person stays in the trip and can try again.
struct LeaveFailed: LocalizedError, Equatable {
    var errorDescription: String? { "Couldn’t leave the trip. Check your signal and try again." }
}

extension TripSessionLogic {
    /// A Leave write the server refuses because this phone is no longer a member (or the doc is gone) means it has
    /// left: typically the delete went through but its reply was lost, and the resend was refused (D54 review).
    static func leaveCountsAsLeft(_ error: Error) -> Bool { HomeNow.isGone(error) }
}

/// Builds the car-route service for one tracking session from the trip and car docs.
/// `meetingPoint` is the trip's meeting point when it has one: cars still joining route to it.
typealias CarRouteFactory = @MainActor (
    _ tripId: String, _ carId: String, _ trip: Trip, _ car: Car, _ meetingPoint: CLLocationCoordinate2D?
) throws -> CarRouteControlling

/// What a screen reads from the session beyond the trip, its stops and this phone's own docs (`TripSession.read`).
enum TripRead: Hashable, Sendable { case cars, members }

/// The screens that read from the session: the lobby (its rows, also below the pulled-up convoy) and the convoy's map.
enum TripReader: Hashable, Sendable { case lobby, map }

enum TripSessionLogic {
    /// The listeners the session runs for what its readers read: the union, so two readers share one listener.
    static func reads(_ readers: [TripReader: Set<TripRead>]) -> Set<TripRead> {
        readers.values.reduce(into: Set<TripRead>()) { $0.formUnion($1) }
    }

    /// The trip has started and is still running (`startedAt` set, not ended): the one rule the lobby and the map read.
    static func isStarted(_ trip: Trip?) -> Bool {
        guard let trip, trip.status == .active else { return false }
        return trip.startedAt != nil
    }

    /// Only the car's tracker, while the trip is active and they are still a member, broadcasts.
    static func shouldTrack(
        userId: String, tripStatus: TripStatus?, isMember: Bool, trackerUserId: String?
    ) -> Bool {
        guard !userId.isEmpty, tripStatus == .active, isMember else { return false }
        return trackerUserId == userId
    }

    /// A pause lasts at most this long; after it, every client treats the car as sharing again and the
    /// tracker's own session resumes by itself. Covers a forgotten pause, a crash or a relaunch.
    static let pauseExpiry: TimeInterval = 30 * 60

    /// True while `pausedAt` is set, not in the future by more than a skew allowance, and younger than `pauseExpiry`.
    static func isPaused(pausedAt: Date?, now: Date) -> Bool {
        guard let pausedAt else { return false }
        return now.timeIntervalSince(pausedAt) < pauseExpiry
    }

    /// Whether other members should show this car as paused ("Paused" instead of "Last seen ...").
    static func isPaused(_ car: Car?, now: Date) -> Bool {
        isPaused(pausedAt: car?.pausedAt, now: now)
    }

    /// The explainer is shown at most once per session, and only when the permission logic asks for it.
    static func shouldPresentAlwaysExplainer(action: LocationAction, alreadyShown: Bool) -> Bool {
        action == .showAlwaysExplainer && !alreadyShown
    }

    /// The Always sheet wants the screen while wanted and no map ask is up, so the two never stack.
    static func explainerWants(wanted: Bool, askShowing: Bool) -> Bool { wanted && !askShowing }

    /// It comes up only once the map's convoy sheet has gone (the sheet steps aside for it first).
    static func explainerVisible(wanted: Bool, askShowing: Bool, mapSheetUp: Bool = false) -> Bool {
        BottomSheet.presents(wanted: explainerWants(wanted: wanted, askShowing: askShowing), sheetUp: mapSheetUp)
    }

    @MainActor static func makeCarRouteService(
        tripId: String, carId: String, trip: Trip, car: Car, meetingPoint: CLLocationCoordinate2D? = nil
    ) throws -> CarRouteControlling {
        try CarRouteService(
            tripId: tripId, carId: carId, mainRoute: trip.route,
            destination: CLLocationCoordinate2D(
                latitude: trip.destination.coordinate.latitude, longitude: trip.destination.coordinate.longitude),
            meetingPoint: meetingPoint, route: car.route, state: car.state)
    }

    /// The meeting point: the first stop when it is of kind `meet` and not skipped. Nil for a trip without one.
    static func meetingPoint(in stops: [PlannedStop]) -> CLLocationCoordinate2D? {
        guard let first = stops.min(by: { $0.order < $1.order }), first.kind == .meet, first.isActive else { return nil }
        return first.coordinate.coordinate
    }

    /// The meeting point a car's own route goes to (D25 4d-2). The same as `meetingPoint(in:)` until the lead car
    /// has tapped Leave at it, or this car has said it will meet the convoy along the way (`skippingAlong`): after
    /// either, the car's route goes to the destination and merges wherever its road meets the main route, as on a
    /// trip with no meeting point.
    static func joiningMeetingPoint(in stops: [PlannedStop], skippingAlong: Bool) -> CLLocationCoordinate2D? {
        guard !skippingAlong,
              let first = stops.min(by: { $0.order < $1.order }), first.kind == .meet, first.isOpen
        else { return nil }
        return meetingPoint(in: stops)
    }

    /// What a running tracking session was started with, for `sessionMeetingPoint`.
    struct RunningSession { var meetingPoint: CLLocationCoordinate2D? }

    /// A listener on the car's answer that ended in an error, and when.
    struct AnswerFailure: Equatable { var target: [String]; var at: Date }

    /// How long after an error the same answer listener waits before attaching again.
    static let answerRetryDelay: TimeInterval = 10

    /// Whether the listener on `target` may attach now: not within `answerRetryDelay` of its own last failure, so a
    /// lasting error (permission denied) does not loop attach, error, attach.
    static func mayAttachAnswer(target: [String], lastFailure: AnswerFailure?, now: Date) -> Bool {
        guard let lastFailure, lastFailure.target == target else { return true }
        return now.timeIntervalSince(lastFailure.at) >= answerRetryDelay
    }

    /// The meeting point that keys a tracking session. After the start, a car that is no longer joining keeps what
    /// its running session was started with (`running`, when that session is this car's on this route), so neither
    /// a Leave nor its own merge restarts it; with no running session it follows `joiningMeetingPoint`. A car still
    /// joining, or any car before the start, follows `joiningMeetingPoint`.
    static func sessionMeetingPoint(
        in stops: [PlannedStop], skippingAlong: Bool, carState: CarState, tripStarted: Bool,
        running: RunningSession? = nil
    ) -> CLLocationCoordinate2D? {
        if tripStarted, carState != .joining, let running { return running.meetingPoint }
        return joiningMeetingPoint(in: stops, skippingAlong: skippingAlong)
    }

    /// A session for a joining car is not keyed until this car's answer on the meeting point has been read once:
    /// after a relaunch the answer starts unknown, and a route started toward the meet could land after the right one.
    static func waitsForAnswer(stops: [PlannedStop], carState: CarState, tripStarted: Bool, answerRead: Bool) -> Bool {
        guard tripStarted, carState == .joining, !answerRead else { return false }
        return stops.min(by: { $0.order < $1.order })?.kind == .meet
    }

    /// What a tracking session starts from. While a trip with a meeting point has not started, the car doc's state and
    /// route can't be trusted: they may belong to an old route (the organizer's car says `convoy` from the day the trip
    /// was made), or be left from before a pause, a relaunch, or an add made while the phone had no fix. So every
    /// session starts from `joining` with no route, and the car works out afresh whether it is at the meeting point
    /// (then it comes out `convoy`) and where it has to go. Once the trip has started the doc is used as it is.
    static func carForNewSession(_ car: Car, hasMeetingPoint: Bool, tripStarted: Bool) -> Car {
        guard hasMeetingPoint, !tripStarted else { return car }
        var fresh = car
        fresh.state = .joining
        fresh.route = nil
        fresh.mergeOffset = nil
        return fresh
    }

    /// Flat lat/lon list used to compare routes (`RouteLine` is not Equatable); nil for no route.
    static func signature(of line: RouteLine?) -> [Double]? {
        guard let line else { return nil }
        return line.coordinates.flatMap { [$0.latitude, $0.longitude] }
    }

    /// Decodes a polyline into a route; nil for a missing or malformed string.
    static func routeLine(from polyline: String?) -> RouteLine? {
        guard let polyline, !polyline.isEmpty else { return nil }
        let coordinates = Polyline.decode(polyline)
        return coordinates.isEmpty ? nil : RouteLine(coordinates)
    }
}
