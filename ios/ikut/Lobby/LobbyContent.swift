import Foundation

/// What the lobby's sheet says (canvas B4 and B5, decision #374), pure so each line can be tested: the header's
/// second line, the cars and their lines, the words above Start trip, the stop rows, and which rows each person gets.
enum LobbyContent {
    // MARK: Header

    /// The sheet's title: the trip's name while gathering, then what `LobbyLogic.title` says once it has started or ended.
    static func headerTitle(tripName: String, started: Bool, ended: Bool) -> String {
        started || ended ? LobbyLogic.title(started: started, ended: ended) : tripName
    }

    /// "To Ipoh · meet 12:00 · code K7M 2QX" before the start (no "meet" without a timed meeting point); "Since 9:35 PM"
    /// once it has started (nil when the start time wasn't recorded); nothing after the end.
    static func subtitle(
        destination: String, meetAt: Date?, code: String, started: Bool, ended: Bool, startedAt: Date?,
        locale: Locale = .current, timeZone: TimeZone = .current
    ) -> String? {
        if ended { return nil }
        if started { return LobbyLogic.sinceLine(startedAt: startedAt, locale: locale, timeZone: timeZone) }
        var parts = ["To \(destination)"]
        if let meetAt { parts.append("meet \(StopFormat.clock(meetAt, timeZone: timeZone))") }
        parts.append("code \(LobbyLogic.displayCode(code))")
        return parts.joined(separator: " · ")
    }

    // MARK: Cars

    /// "Cars · 4 of 5 ready"; just "Cars" with none yet.
    static func carsHeader(_ cars: [LobbyCar]) -> String {
        cars.isEmpty ? "Cars" : "Cars · \(cars.filter(\.hasTracker).count) of \(cars.count) ready"
    }

    /// One car's row: its name (with "· You" on yours), the line under it and the word on the trailing side.
    struct CarText: Equatable {
        var name: String
        var line: String
        var ready: Bool
        var trailing: String { ready ? "Ready" : "Waiting" }
        var isMine: Bool
    }

    /// How a car meets the convoy, from what its own doc says (no position): no route of its own means it is on the
    /// main route, at its start or part-way along. Nil before the car's tracker has worked it out. The "never meets"
    /// case needs the route's geometry (the other `join`).
    static func join(of car: Car) -> OwnWayJoin? {
        if let route = car.route, !route.isEmpty { return .merges(offset: car.mergeOffset ?? 0) }
        guard let offset = car.mergeOffset else { return nil }
        return offset < OwnWayLogic.startsWithin ? .startsWithConvoy : .onRoute(offset: offset)
    }

    /// Like `join(of:)`, but with the main route's geometry it can also tell a car whose own route never meets it
    /// (`.meetsAtDestination`), and a route that joins at the meeting point. Falls back to `join(of:)` without a route.
    static func join(of car: Car, main: RouteLine?, hasMeetingPoint: Bool) -> OwnWayJoin? {
        if let main, !main.isEmpty, let found = OwnWayLogic.join(car: car, main: main, hasMeetingPoint: hasMeetingPoint) {
            return found.join
        }
        return join(of: car)
    }

    /// `viewerLeavesFromTheStart`: the viewer is on the main route's start (the organiser always is), so a car that
    /// starts there "Leaves with you". `joinPlace` is the town a car joins near, for the join towns (D50 piece 3);
    /// until it is given the line says "Joins the convoy". `join` is `join(of:main:hasMeetingPoint:)` when the route is
    /// known; `destination` names where a car that never meets the route does.
    static func carText(
        _ item: LobbyCar, mine: Bool, viewerLeavesFromTheStart: Bool, joinPlace: String? = nil,
        join known: OwnWayJoin? = nil, destination: String? = nil
    ) -> CarText {
        let name = mine ? "\(item.car.name) · You" : item.car.name
        guard item.hasTracker else { return CarText(name: name, line: "Not sharing location yet", ready: false, isMine: mine) }
        let line: String
        if mine {
            line = "Ready · leaves from your start"
        } else {
            switch known ?? join(of: item.car) {
            case .startsWithConvoy: line = viewerLeavesFromTheStart ? "Leaves with you" : "Leaves with the convoy"
            case .onRoute, .merges: line = joinPlace.map { "Joins near \($0)" } ?? "Joins the convoy"
            case .meetsAtDestination:
                let who = viewerLeavesFromTheStart ? "you" : "the convoy"
                line = destination.map { "Meets \(who) at \($0)" } ?? "Meets the convoy at the end"
            case nil: line = "Sharing location"
            }
        }
        return CarText(name: name, line: line, ready: true, isMine: mine)
    }

    // MARK: Above Start trip

    /// The cars whose phones aren't sharing yet.
    static func notSharing(_ cars: [LobbyCar]) -> [LobbyCar] { cars.filter { !$0.hasTracker } }

    /// "Waiting for Siti’s Bezza to share location. You can start anyway." (two or more: "Waiting for 2 cars ..."); nil when
    /// every car is sharing.
    static func waitingLine(_ cars: [LobbyCar]) -> String? {
        let waiting = notSharing(cars)
        switch waiting.count {
        case 0: return nil
        case 1: return "Waiting for \(waiting[0].car.name) to share location. You can start anyway."
        default: return "Waiting for \(waiting.count) cars to share location. You can start anyway."
        }
    }

    /// The title of what tapping Start trip asks first ("Siti’s Bezza isn’t sharing yet", then `startConfirmMessage`); nil
    /// when it needn't ask.
    static func startConfirm(_ cars: [LobbyCar]) -> String? {
        let waiting = notSharing(cars)
        switch waiting.count {
        case 0: return nil
        case 1: return "\(waiting[0].car.name) isn’t sharing yet"
        default: return "\(waiting.count) cars aren’t sharing yet"
        }
    }

    static let startConfirmMessage = "Start anyway?"

    // MARK: Stops

    /// A stop's row: its number as on the map's pin (nil for the meeting point, which has none), name and second line.
    struct StopText: Equatable, Identifiable {
        var id: String
        var number: Int?
        var name: String
        var detail: String
    }

    /// The meeting point reads "Meeting point · meet 12:00"; a stop "About 1 h 35 min in · stay 20 min" (the drive time
    /// to it, from how far along the route it is; "62 km in" when the route's time isn't known). Numbers count the
    /// non-meeting stops in list order, as `LobbyMapLogic.pins` does.
    static func stopTexts(
        _ stops: [StopDraft], routeLength: Double?, routeSeconds: Double?, timeZone: TimeZone = .current
    ) -> [StopText] {
        var number = 0
        return stops.map { stop in
            if stop.isMeeting {
                var detail = "Meeting point"
                if let meetAt = stop.meetAt { detail += " · meet \(StopFormat.clock(meetAt, timeZone: timeZone))" }
                return StopText(id: stop.id, number: nil, name: stop.name, detail: detail)
            }
            number += 1
            var parts: [String] = []
            if let offset = stop.routeOffset {
                if let routeLength, routeLength > 0, let routeSeconds, routeSeconds > 0 {
                    parts.append("About \(ConvoyFormat.duration(routeSeconds * min(1, offset / routeLength))) in")
                } else {
                    parts.append("\(StopFormat.along(meters: offset)) in")
                }
            }
            if let minutes = stop.minutes { parts.append("stay \(StopFormat.length(minutes: minutes))") }
            if parts.isEmpty { parts.append(StopFormat.kind(stop.kind)) }
            return StopText(id: stop.id, number: number, name: stop.name, detail: parts.joined(separator: " · "))
        }
    }

    /// "After about 1 h 30 min", under Suggest stops: where the first suggestion would fall (`SuggestAfter`).
    static func suggestCaption(routeSeconds: Double?) -> String? {
        routeSeconds.map { "After about \(ConvoyFormat.duration(SuggestAfter.defaultSeconds(routeSeconds: $0)))" }
    }

    // MARK: Who gets which rows

    struct Rows: Equatable {
        /// The Name row is a button (rename) and Destination opens Change destination.
        var canRename: Bool
        var canChangeDestination: Bool
        /// Add a stop, Suggest stops, reorder and swipe to remove.
        var canEditStops: Bool
        var canPause: Bool
        var canLeave: Bool
        var canEnd: Bool
        /// A participant has their own way in (D26) under the header.
        var ownWay: Bool
    }

    /// `trackingOrPaused`: this phone is broadcasting (or paused while it was).
    static func rows(isOrganizer: Bool, started: Bool, ended: Bool, isLiveMember: Bool, trackingOrPaused: Bool) -> Rows {
        let canEdit = isOrganizer && isLiveMember
        return Rows(
            canRename: canEdit,
            canChangeDestination: LobbyLogic.canChangeDestination(canEdit: canEdit),
            canEditStops: canEdit && !started,
            canPause: trackingOrPaused && isLiveMember,
            canLeave: LobbyLogic.canLeaveTrip(isOrganizer: isOrganizer, started: started, isLiveMember: isLiveMember),
            canEnd: isOrganizer && !ended,
            ownWay: !isOrganizer)
    }
}
