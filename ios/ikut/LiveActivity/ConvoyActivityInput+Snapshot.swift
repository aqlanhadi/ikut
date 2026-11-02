import Foundation

extension ConvoyActivityInput {
    /// The convoy as the map reads it, taken from the open trip's session and map model. Nothing is recomputed here:
    /// the next stop is `NextStop.cell`, the count at a stop `StopArrival.tally`, the leaving time `StopLeave`, the
    /// gaps and spread `ConvoyOrdering`'s, the stop request `StopRequestState`. Nil until the trip has loaded.
    /// `joinPlace` is the town my car meets the convoy at (the panel's header says the same).
    @MainActor
    static func snapshot(
        session: TripSession, map: TripMapModel, joinPlace: String?, now: Date = Date()
    ) -> ConvoyActivityInput? {
        guard let trip = session.trip else { return nil }
        let convoy = map.convoy
        var i = ConvoyActivityInput(now: now, tripName: trip.name, destination: ConvoyFormat.placeShortName(trip.destination.name))
        i.tripStarted = TripSessionLogic.isStarted(trip)
        i.tripEnded = session.isEnded
        i.isOrganizer = session.isOrganizer
        i.organizerName = LobbyLogic.organizerName(trip: trip, members: session.members)
        i.carCount = session.cars.count
        i.readyCars = session.cars.filter { $0.trackerUserId != nil }.count
        i.pausedUntil = session.pausedUntil
        i.convoyStopSince = session.convoyStop?.since
        i.mayEndConvoyStop = session.mayEndConvoyStop

        let me = convoy.myEntry
        let myId = convoy.myCarId
        let convoyData = convoy.convoy.filter { $0.id != myId }.compactMap(\.position.updatedAt)
        let joiningData = convoy.joining.filter { $0.id != myId }.compactMap { $0.position?.updatedAt }
        i.newestOtherData = (convoyData + joiningData).max()
        i.dots = convoy.convoy.map {
            Dot(name: StopLeave.ownerWord($0.car), color: $0.car.color, offset: $0.convoyOffset,
                gapAhead: $0.gap?.distance, isMine: $0.id == myId)
        }
        i.myOffset = me?.convoyOffset
        i.spreadMeters = convoy.convoy.count > 1 ? convoy.snapshot.spread : nil

        let length = map.mainRoute?.length
        if let me {
            i.destinationMeters = length.map { max(0, $0 - me.convoyOffset) }
            i.destinationSeconds = convoy.driveArrival(forCar: me.id).map { max(0, $0.timeIntervalSince(now)) }
            if me.hasArrived {
                i.arrived = Arrived(
                    count: convoy.convoy.filter(\.hasArrived).count, total: convoy.convoy.count + convoy.joining.count,
                    driveSeconds: map.departedAt.map { now.timeIntervalSince($0) })
            }
        } else if let mine = convoy.myJoining {
            let meets = map.mainRoute.flatMap { OwnWayLogic.join(car: map.myCar, main: $0)?.join } == .meetsAtDestination
            i.joining = Joining(place: joinPlace, meetsAtDestination: meets, amount: convoy.joinAmount(mine))
        }

        stopFields(&i, map: map, now: now)
        hazardFields(&i, map: map, now: now)
        requestFields(&i, map: map, now: now)
        otherCarFields(&i, map: map, now: now)
        return i
    }

    @MainActor
    private static func stopFields(_ i: inout ConvoyActivityInput, map: TripMapModel, now: Date) {
        let convoy = map.convoy
        let cell: NextStop.Cell?
        let pace: Double?
        if let me = convoy.myEntry {
            pace = map.stopPace()
            cell = NextStop.cell(stops: map.stops, offset: me.convoyOffset, pace: pace, now: now)
        } else if let mine = convoy.myJoining {
            pace = map.joiningStopPace()
            cell = NextStop.joiningCell(
                stops: map.stops, distance: mine.distanceToMerge, seconds: mine.timeToMerge,
                mergeOffset: mine.car.mergeOffset, pace: pace, skipsMeet: map.skipsMeetingPoint)
        } else {
            return
        }
        guard let cell, let stop = map.stops.first(where: { $0.id == cell.stopId }) else { return }
        i.nextStop = Stop(name: stop.name, offset: stop.routeOffset, meters: cell.distance, seconds: cell.seconds, isHere: cell.isHere)
        guard cell.isHere, let target = StopArrival.target(stopId: stop.id ?? "", in: map.stops) else { return }
        let tally = StopArrival.tally(
            target: target, convoy: convoy.convoy, joining: convoy.joining, pace: pace, now: now, cars: map.cars)
        let leaveAt = StopLeave.leavingAt(stop)
        var arriveAt: Date?
        if let leaveAt, let pace, let length = map.mainRoute?.length {
            arriveAt = leaveAt.addingTimeInterval(pace * max(0, length - stop.routeOffset))
        }
        i.stopHere = StopHere(here: tally.here, total: tally.total, leaveAt: leaveAt, arriveAt: arriveAt)
    }

    @MainActor
    private static func hazardFields(_ i: inout ConvoyActivityInput, map: TripMapModel, now: Date) {
        guard let id = map.activityFeed.hazardEventId, let marker = map.hazards.markers.first(where: { $0.id == id }) else { return }
        // No metres without a fresh fix of my car (note 5): `myOffsetNow` carries a fix forward only while it is fresh.
        let fresh = map.convoy.myEntry?.position.updatedAt.map { now.timeIntervalSince($0) <= 10 } ?? false
        i.hazard = Hazard(
            label: marker.label, reporter: map.hazardReporter(eventId: id),
            meters: fresh ? map.approachDistance(eventId: id, now: now) : nil, offset: marker.mainOffset)
    }

    /// The oldest open request: the one the pill would ask about, or the one my car answered or asked.
    @MainActor
    private static func requestFields(_ i: inout ConvoyActivityInput, map: TripMapModel, now: Date) {
        guard let r = map.activityFeed.requests.first else { return }
        let reason: Reason
        switch r.type {
        case .stopFuel: reason = .fuel
        case .stopFood: reason = .food
        case .stopToilet: reason = .toilet
        default: reason = .rest
        }
        let owes = StopLogic.needsAnswer(r)
        i.request = Request(
            requesterName: r.requesterName, reason: reason, meters: map.convoy.distance(fromMyCarTo: r.requesterCarId),
            okCount: r.okCount, total: r.rows.count, iSaidOK: r.viewerCarIsOK && !StopLogic.viewerIsRequester(r),
            iAsked: StopLogic.viewerIsRequester(r), owesMyAnswer: owes, since: map.activityFeed.questionSeen[r.eventId] ?? now)
    }

    /// The heads-up from the car coming up behind, and my car parked far ahead of the nearest car behind.
    @MainActor
    private static func otherCarFields(_ i: inout ConvoyActivityInput, map: TripMapModel, now: Date) {
        let convoy = map.convoy
        if let alert = map.catchUp, let meters = map.catchUpDistance(alert, now: now),
           let car = convoy.convoy.first(where: { $0.id == alert.eventId }) {
            i.headsUp = Heads(name: StopLeave.ownerWord(car.car), meters: meters, seconds: map.catchUpSeconds(alert, distance: meters))
        }
        guard let me = convoy.myEntry, me.isParked, let index = convoy.convoy.firstIndex(where: { $0.id == me.id }),
              index == 0, convoy.convoy.count > 1,
              let behind = convoy.distance(fromMyCarTo: convoy.convoy[1].id), -behind > ConvoyOrdering.Config.default.groupRadius
        else { return }
        i.parkedAhead = Heads(name: StopLeave.ownerWord(convoy.convoy[1].car), meters: -behind, seconds: nil)
    }
}
