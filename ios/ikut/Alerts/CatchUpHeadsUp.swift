import Foundation

/// The heads-up for a car parked ahead on the route (D26): on that car's phones, "Aisha’s car is
/// 3.3 km behind you" about `leadTime` before the nearest moving car behind reaches it, timed from that
/// car's smoothed speed (`ConvoyEntry.movingSpeed`, not the floored one).
///
/// It fires only after this phone has seen that car more than `leadTime` away, so cars that start
/// together, or a relaunch with the convoy already close, stay quiet. Once per stop: after it fires,
/// it is quiet until my car has driven on more than `rearmDistance` along the route from where it
/// fired, then a later stop ahead of the convoy can fire it again. Pure apart from what it remembers,
/// which lasts as long as the value (the map's model).
struct CatchUpHeadsUp: Sendable {
    static let leadTime: TimeInterval = 120
    /// How far my car drives on from where it heard the heads-up before the next stop can fire it again:
    /// well past GPS wander in a car park, well short of the next R&R or toll.
    static let rearmDistance: Double = 1_000

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
        /// Which heads-up this is for my car on this trip (1 at the first stop), so each stop's alert
        /// is announced on its own.
        var stop = 1
    }

    /// Cars behind seen more than `leadTime` away, by "trip/myCar/theirs".
    private var seenFar: Set<String> = []
    /// My car's route offset when it fired, by "trip/myCar"; gone once it drives on.
    private var firedAt: [String: Double] = [:]
    /// How many times it has fired, by "trip/myCar".
    private var stops: [String: Int] = [:]

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

    /// The heads-up the first time it is due for my car at this stop, else nil.
    mutating func check(
        _ snapshot: ConvoySnapshot, tripId: String, myCarId: String, config: ConvoyOrdering.Config = .default
    ) -> Due? {
        let mine = "\(tripId)/\(myCarId)"
        if let at = firedAt[mine] {
            // Re-arm once my car has driven on; it then has to see a car far behind again.
            guard let me = snapshot.entry(myCarId),
                  me.convoyOffset - at > Self.rearmDistance else { return nil }
            firedAt[mine] = nil
            seenFar = seenFar.filter { !$0.hasPrefix("\(mine)/") }
        }
        guard var due = Self.nearestBehind(snapshot, myCarId: myCarId, config: config) else { return nil }
        let pair = "\(mine)/\(due.carId)"
        guard due.seconds <= Self.leadTime else {
            seenFar.insert(pair)
            return nil
        }
        guard seenFar.contains(pair),
              let me = snapshot.entry(myCarId) else { return nil }
        firedAt[mine] = me.convoyOffset
        due.stop = (stops[mine] ?? 0) + 1
        stops[mine] = due.stop
        return due
    }

    /// "Aisha’s car" for "Aisha’s X70"; a name that isn't anyone's stays as it is.
    static func phrase(_ carName: String) -> String {
        let short = StopLogic.ownerName(fromCarName: carName)
        return short == carName ? carName : "\(short)’s car"
    }
}
