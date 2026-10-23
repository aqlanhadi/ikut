import Foundation

/// The heads-up for a car parked ahead on the route (D26): on that car's phones, "Aisha’s car is
/// 3.3 km behind you" about `leadTime` before the nearest moving car behind reaches it, timed from that
/// car's smoothed speed (`ConvoyEntry.movingSpeed`, not the floored one).
///
/// It fires only after this phone has seen that car more than `leadTime` away, so cars that start
/// together, or a relaunch with the convoy already close, stay quiet. Once per car per trip. Pure
/// apart from what it remembers, which lasts as long as the value (the map's model).
struct CatchUpHeadsUp: Sendable {
    static let leadTime: TimeInterval = 120

    /// What the pill and the spoken line are about.
    struct Due: Equatable, Sendable {
        /// The car coming up behind.
        var carId: String
        /// "Aisha’s car", or the car's own name when it isn't anyone's ("Red Myvi").
        var carPhrase: String
        /// Meters along the route from it to my car.
        var distance: Double
        /// Seconds until it reaches my car.
        var seconds: TimeInterval
    }

    /// Cars behind seen more than `leadTime` away, by "trip/myCar/theirs".
    private var seenFar: Set<String> = []
    /// "trip/myCar" once it has fired.
    private var fired: Set<String> = []

    init() {}

    /// The nearest moving fresh car behind `myCarId` with its distance and time, while my car is
    /// fresh, on the route, not arrived and slower than `Config.parkedSpeed`; nil otherwise.
    static func nearestBehind(
        _ snapshot: ConvoySnapshot, myCarId: String, config: ConvoyOrdering.Config = .default
    ) -> Due? {
        let convoy = snapshot.convoy
        guard let i = convoy.firstIndex(where: { $0.id == myCarId }) else { return nil }
        let me = convoy[i]
        guard !me.isStale, !me.isPaused, !me.hasArrived, me.isParked else { return nil }
        // Cars parked behind are with me, or stopped too; the one to time is the nearest still driving.
        guard let behind = convoy[(i + 1)...].first(where: {
            !$0.isStale && !$0.isPaused && $0.movingSpeed >= config.parkedSpeed
        }) else { return nil }
        let distance = max(0, me.convoyOffset - behind.convoyOffset)
        return Due(
            carId: behind.id, carPhrase: phrase(behind.car.name), distance: distance,
            seconds: distance / behind.movingSpeed)
    }

    /// The heads-up the first time it is due for my car on this trip, else nil.
    mutating func check(
        _ snapshot: ConvoySnapshot, tripId: String, myCarId: String, config: ConvoyOrdering.Config = .default
    ) -> Due? {
        let mine = "\(tripId)/\(myCarId)"
        guard !fired.contains(mine), let due = Self.nearestBehind(snapshot, myCarId: myCarId, config: config)
        else { return nil }
        let pair = "\(mine)/\(due.carId)"
        guard due.seconds <= Self.leadTime else {
            seenFar.insert(pair)
            return nil
        }
        guard seenFar.contains(pair) else { return nil }
        fired.insert(mine)
        return due
    }

    /// "Aisha’s car" for "Aisha’s X70"; a name that isn't anyone's stays as it is.
    static func phrase(_ carName: String) -> String {
        let short = MapMarkerBuilder.shortName(carName)
        return short == carName ? carName : "\(short)’s car"
    }
}
