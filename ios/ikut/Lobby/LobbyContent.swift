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

    /// The phone shares its location before the start (#394): the subtitle leads with "Sharing" in green, where a
    /// floating capsule used to sit above the cars. Paused, the paused banner says so and the subtitle drops it.
    static func subtitleSharing(tracking: Bool, paused: Bool, started: Bool, ended: Bool) -> Bool {
        tracking && !paused && !started && !ended
    }

    /// The subtitle's words with "Sharing" in front when it shares ("Sharing · To Ipoh · code K7M 2QX"); the view
    /// draws the arrow before them and colours "Sharing".
    static func subtitleWords(_ subtitle: String?, sharing: Bool) -> String? {
        guard sharing else { return subtitle }
        return [sharingWord, subtitle].compactMap { $0 }.joined(separator: " · ")
    }

    static let sharingWord = "Sharing"

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
        let offset = OwnWayLogic.cleanOffset(car.mergeOffset)
        if let route = car.route, !route.isEmpty { return .merges(offset: offset ?? 0) }
        guard let offset else { return nil }
        return offset < OwnWayLogic.startsWithin ? .startsWithConvoy : .onRoute(offset: offset)
    }

    /// How a car meets the convoy, and whether its route goes to the trip's meeting point (so it "meets you" there).
    struct CarJoin: Equatable {
        var join: OwnWayJoin?
        var viaMeeting = false
        /// Cars driving to the meeting point read "Meets you at <it>" (nothing is looked up for them).
        var meetsAtMeeting: Bool {
            guard viaMeeting, case .merges(let offset)? = join else { return false }
            return offset < OwnWayLogic.startsWithin
        }
    }

    /// Like `join(of:)`, but with the main route's geometry it can also tell a car whose own route never meets it
    /// (`.meetsAtDestination`), and a route that joins at the meeting point. Falls back to `join(of:)` without a route.
    static func carJoin(of car: Car, main: RouteLine?, hasMeetingPoint: Bool) -> CarJoin {
        if let main, !main.isEmpty, let found = OwnWayLogic.join(car: car, main: main, hasMeetingPoint: hasMeetingPoint) {
            return CarJoin(join: found.join, viaMeeting: found.viaMeeting)
        }
        return CarJoin(join: join(of: car))
    }

    static func join(of car: Car, main: RouteLine?, hasMeetingPoint: Bool) -> OwnWayJoin? {
        carJoin(of: car, main: main, hasMeetingPoint: hasMeetingPoint).join
    }

    /// `viewerLeavesFromTheStart`: the viewer is on the main route's start (the organiser always is), so a car that
    /// starts there "Leaves with you". `joinPlace` is the town a car joins near, for the join towns (D50 piece 3);
    /// until it is given the line says "Joins the convoy". `join` is `join(of:main:hasMeetingPoint:)` when the route is
    /// known; `destination` names where a car that never meets the route does.
    static func carText(
        _ item: LobbyCar, mine: Bool, viewerLeavesFromTheStart: Bool, joinPlace: String? = nil,
        join known: OwnWayJoin? = nil, destination: String? = nil, meeting: String? = nil
    ) -> CarText {
        let name = mine ? "\(item.car.name) · You" : item.car.name
        guard item.hasTracker else { return CarText(name: name, line: "Not sharing location yet", ready: false, isMine: mine) }
        let line: String
        if mine {
            line = "Ready · leaves from your start"
        } else {
            let who = viewerLeavesFromTheStart ? "you" : "the convoy"
            switch known ?? join(of: item.car) {
            case .merges where meeting != nil: line = "Meets \(who) at \(meeting!)"
            case .startsWithConvoy: line = viewerLeavesFromTheStart ? "Leaves with you" : "Leaves with the convoy"
            case .onRoute: line = "Waiting on the route"
            case .merges: line = joinPlace.map { "Joins near \($0)" } ?? "Joins the convoy"
            case .meetsAtDestination:
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

    /// The journey while driving, below the convoy at tall (canvas row L): the stops still ahead, numbered as on the map, and the part
    /// already driven folded into one line, so the list starts with what is still ahead.
    struct Journey: Equatable {
        /// "Passed R&R Bidor · 8:31 PM" (the last stop left or driven past), "Left Petronas · 7:42 PM" (the meeting
        /// point), or "Left 7:42 PM" with none passed yet; nil when not even the start time is known.
        var behind: String?
        var ahead: [StopText]
    }

    /// Where my car is on the main route, and its pace there (`NextStop.pace`, seconds per meter), for the journey.
    struct JourneyHere: Equatable {
        var offset: Double
        var pace: Double?
    }

    /// `stops` in any order; numbers count every non-meeting stop in order, passed and skipped ones too, so a stop
    /// keeps its pin's number. A stop is ahead while it is open (not left, not skipped) and, with `here`, my car has
    /// not driven past it by more than `NextStop.hereRadius`; with `here` it reads the distance and time from my car,
    /// as Next stop does ("18 km · 12 min · stay 20 min", "Here"). The fold line names the last stop left or driven
    /// past, with the time of the Leave when someone tapped it.
    static func journey(
        _ stops: [PlannedStop], routeLength: Double?, routeSeconds: Double?, departedAt: Date?, here: JourneyHere? = nil,
        locale: Locale = .current, timeZone: TimeZone = .current
    ) -> Journey {
        let ordered = stops.sorted { $0.order < $1.order }
        let texts = stopTexts(ordered.map(StopDraft.init), routeLength: routeLength, routeSeconds: routeSeconds, timeZone: timeZone)
        func drivenPast(_ stop: PlannedStop) -> Bool {
            guard let here else { return false }
            return stop.routeOffset < here.offset - NextStop.hereRadius
        }
        let ahead = zip(ordered, texts).filter { $0.0.isOpen && !drivenPast($0.0) }.map { stop, text in
            guard let here else { return text }
            var text = text
            let cell = NextStop.cell(stops: [stop], offset: here.offset, pace: here.pace)
            if let cell, !stop.isMeeting {
                text.detail = [cell.detail, stop.minutes.map { "stay \(StopFormat.length(minutes: $0))" }]
                    .compactMap { $0 }.joined(separator: " · ")
            } else if let cell {
                text.detail = cell.detail
            }
            return text
        }
        let behind: String?
        if let last = ordered.last(where: { $0.isLeft || ($0.isActive && drivenPast($0)) }) {
            let words = "\(last.isMeeting ? "Left" : "Passed") \(last.name)"
            behind = last.leftAt.map { "\(words) · \(ConvoyFormat.clock($0, locale: locale, timeZone: timeZone))" } ?? words
        } else {
            behind = departedAt.map { "Left \(ConvoyFormat.clock($0, locale: locale, timeZone: timeZone))" }
        }
        return Journey(behind: behind, ahead: ahead)
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

    /// What continues below the convoy when the driving sheet is at tall, in this order.
    enum DrivingSection: Equatable { case journey, code, trip, options, exit }

    /// The driving sections for this person, from the lobby's own `rows` (which also decide the rows inside them):
    /// Keep screen on is everyone's, so the options are always there; Leave or End only when this person can.
    static func drivingSections(_ rows: Rows) -> [DrivingSection] {
        var sections: [DrivingSection] = [.journey, .code, .trip, .options]
        if rows.canEnd || rows.canLeave { sections.append(.exit) }
        return sections
    }

    /// The banner that ends the lobby's usefulness: the trip ended, or this person is no longer in it. Driving, only
    /// the second shows (the end opens the recap); it sits on top of the convoy sheet at every height, with Back to
    /// trips, since there is no other way Home mid-trip (#403).
    enum ExitBanner: Equatable { case ended, noLongerInTrip }

    static func exitBanner(ended: Bool, membershipLost: Bool, tripLoaded: Bool) -> ExitBanner? {
        if ended { return .ended }
        if membershipLost && tripLoaded { return .noLongerInTrip }
        return nil
    }

    static func drivingBanner(ended: Bool, membershipLost: Bool, tripLoaded: Bool) -> ExitBanner? {
        let banner = exitBanner(ended: ended, membershipLost: membershipLost, tripLoaded: tripLoaded)
        return banner == .noLongerInTrip ? banner : nil
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
