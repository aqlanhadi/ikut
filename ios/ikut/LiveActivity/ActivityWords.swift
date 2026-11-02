import Foundation
import SwiftUI

/// The sentences and glyph of each Live Activity state, built here from the content state's raw values (design note 17),
/// following LiveActivity.dc.html word for word. Names, places and numbers are shown verbatim.
struct ActivityWords {
    typealias Kind = ConvoyActivityAttributes.Kind
    typealias State = ConvoyActivityAttributes.ContentState

    var symbol: String
    var tint: Color
    /// The glyph's own colour on its filled badge (black on the light colours).
    var onTint: Color
    var title: String
    var subtitle: String?
    var big: String?
    var caption: String?
    var bigTint: Color?
    /// The one line under the track on the Lock Screen: the gap line, a stop-card line, a count.
    var line: String?
    var lineIsWarning = false
    /// The next-stop slot line while a stop request is open: "Wyna's fuel stop" and its detail.
    var request: (text: String, detail: String, symbol: String)?
    /// Sharing paused: when it ends. The views count down to it themselves (the app sleeps while paused, so nothing
    /// would update the number).
    var pauseEnd: Date?
    /// Leaving at … · … by …, with the leaving time and arrival it was made from.
    var leave: (text: String, leaveAt: Date)?
    /// Hazard ahead and Stop request: the alert glyph alone in the compact island, no ikut mark.
    var isAlert = false
    var showsTrack = false
    var small: (title: String, line: String, big: String?)

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    init(_ s: State, display: ConvoyActivityPresentation.Display, now: Date) {
        let kind = display.kind
        let me = s.cars.first(where: \.isMine).flatMap { ActivityPalette.hex($0.color) } ?? ActivityPalette.accent
        symbol = Symbol.car
        tint = ActivityPalette.accent
        onTint = .white
        title = s.tripName
        small = (s.tripName, "", nil)
        switch kind {
        case .waiting:
            subtitle = String(localized: "To \(s.destination) · \(s.carCount ?? 0) cars")
            if s.isOrganizer {
                let ready = String(localized: "\(s.readyCount ?? 0) of \(s.carCount ?? 0) cars ready")
                line = ready
                caption = String(localized: "ready")
                small.line = ready
            } else {
                let who = s.organizerName ?? String(localized: "the organiser")
                line = String(localized: "Waiting for \(who) to start the trip")
                caption = String(localized: "waiting")
                small.line = String(localized: "Waiting for \(s.organizerName ?? who)")
            }
        case .joining:
            symbol = Symbol.merge
            if s.meetsAtDestination {
                title = String(localized: "Meets the convoy at \(s.destination)")
            } else if let place = s.place {
                title = String(localized: "Joining near \(place)")
            } else {
                title = String(localized: "Joining the convoy")
            }
            subtitle = String(localized: "\(s.tripName) · to \(s.destination)")
            big = s.joinMeters.map(ConvoyFormat.distance) ?? s.joinSeconds.map(ConvoyFormat.duration)
            caption = String(localized: "to the convoy")
            bigTint = ActivityPalette.accent
            small = (title, String(localized: "To \(s.destination)"), nil)
        case .parkedAhead:
            symbol = Symbol.cars
            tint = ActivityPalette.positive
            onTint = .black
            let name = s.otherName ?? ""
            let km = s.otherMeters.map(ConvoyFormat.distance) ?? ""
            subtitle = String(localized: "To \(s.destination)")
            big = km
            caption = String(localized: "\(name) behind you")
            line = String(localized: "\(name)’s car is \(km) behind you")
            showsTrack = true
            small = (String(localized: "\(name)’s car"), String(localized: "Behind you"), km)
        case .catchUp:
            symbol = Symbol.cars
            tint = ActivityPalette.positive
            onTint = .black
            let name = s.otherName ?? ""
            let km = s.otherMeters.map(ConvoyFormat.distance) ?? ""
            title = String(localized: "\(name)’s car is behind you")
            let about = s.otherSeconds.map { String(localized: "About \(ConvoyFormat.duration($0)) away") }
            subtitle = about
            big = km
            caption = String(localized: "behind you")
            bigTint = ActivityPalette.positive
            showsTrack = true
            small = (String(localized: "\(name)’s car"), about ?? "", nil)
        case .inConvoy:
            tint = me
            var parts: [String] = []
            if s.stopName != nil, let meters = s.destinationMeters { parts.append("\(s.destination) \(ConvoyFormat.distance(meters))") }
            if let spread = s.spreadMeters { parts.append(String(localized: "spread \(ConvoyFormat.distance(spread))")) }
            subtitle = parts.isEmpty ? nil : parts.joined(separator: " · ")
            if let name = s.stopName {
                big = s.stopSeconds.map(ConvoyFormat.duration) ?? s.stopMeters.map(ConvoyFormat.distance)
                caption = [name, s.stopSeconds != nil ? s.stopMeters.map(ConvoyFormat.distance) : nil].compactMap { $0 }.joined(separator: " · ")
                small = (String(localized: "To \(name)"), s.stopMeters.map(ConvoyFormat.distance) ?? "", big)
            } else {
                big = s.destinationSeconds.map(ConvoyFormat.duration) ?? s.destinationMeters.map(ConvoyFormat.distance)
                caption = [s.destination, s.destinationSeconds != nil ? s.destinationMeters.map(ConvoyFormat.distance) : nil]
                    .compactMap { $0 }.joined(separator: " · ")
                small = (String(localized: "To \(s.destination)"), s.destinationMeters.map(ConvoyFormat.distance) ?? "", big)
            }
            line = Self.gapLine(s)
            showsTrack = true
            if let name = s.requesterName, let reason = s.reason {
                let ok = s.okCount ?? 0, total = s.okTotal ?? 0
                if s.iAsked {
                    request = (Self.youAsked(reason), String(localized: "\(ok) of \(total) OK · waiting for \(max(0, total - ok))"), Self.symbol(for: reason))
                } else {
                    request = (Self.theirStop(name, reason), String(localized: "You said OK · \(ok) of \(total)"), Self.symbol(for: reason))
                }
            }
        case .atStop:
            symbol = Symbol.parking
            tint = ActivityPalette.positive
            onTint = .black
            let name = s.stopName ?? ""
            title = String(localized: "At \(name)")
            subtitle = s.tripName
            big = String(localized: "\(s.hereCount ?? 0) of \(s.hereTotal ?? 0)")
            caption = String(localized: "here")
            bigTint = ActivityPalette.positive
            showsTrack = true
            var leaveLine = ""
            if let leaveAt = s.leaveAt {
                // The arrival is the later of now and the leaving time, plus the time still to go from the stop.
                let arrive = s.toGoSeconds.map {
                    String(localized: "\(s.destination) by \(ConvoyFormat.clock(max(now, leaveAt).addingTimeInterval($0)))")
                }
                let when = leaveAt > now
                    ? String(localized: "Leaving at \(ConvoyFormat.clock(leaveAt))") : String(localized: "Leave now")
                leave = ([when, arrive].compactMap { $0 }.joined(separator: " · "), leaveAt)
                leaveLine = String(localized: "Leaving \(ConvoyFormat.clock(leaveAt))")
            }
            small = (name, leaveLine, big)
        case .hazardAhead:
            symbol = Symbol.warning
            tint = ActivityPalette.yellow
            onTint = .black
            isAlert = true
            title = Self.hazardTitle(s.hazardType)
            subtitle = s.reporterName.map { String(localized: "Reported by \($0)’s car") }
            big = s.hazardMeters.map(ConvoyFormat.distance)
            caption = big == nil ? nil : String(localized: "ahead")
            bigTint = ActivityPalette.yellow
            showsTrack = true
            small = (title, s.reporterName.map { String(localized: "\($0)’s car") } ?? "", big)
        case .stopRequest:
            symbol = Self.symbol(for: s.reason ?? .rest)
            tint = ActivityPalette.positive
            onTint = .black
            isAlert = true
            let name = s.requesterName ?? ""
            title = Self.needs(name, s.reason ?? .rest)
            subtitle = s.requesterMeters.map { m in
                m < 0 ? String(localized: "\(ConvoyFormat.distance(-m)) behind you") : String(localized: "\(ConvoyFormat.distance(m)) ahead of you")
            }
            line = String(localized: "\(s.okCount ?? 0) of \(s.okTotal ?? 0) OK")
            caption = String(localized: "said OK")
            small = (title, String(localized: "OK"), String(localized: "\(s.okCount ?? 0) of \(s.okTotal ?? 0)"))
        case .stopped:
            symbol = Symbol.parking
            title = String(localized: "Convoy stopped")
            subtitle = s.stopName.map { String(localized: "At \($0)") } ?? s.tripName
            let minutes = s.stoppedSince.map { ConvoyActivityPresentation.minutes(since: $0, now: now) } ?? 1
            big = String(localized: "\(minutes) min")
            caption = String(localized: "stopped")
            bigTint = ActivityPalette.accent
            line = s.mayEndStop
                ? String(localized: "Tap Continue in ikut when everyone’s ready")
                : String(localized: "The lead car taps Continue when everyone’s ready")
            small = (title, "", big)
        case .sharingPaused:
            symbol = Symbol.pause
            tint = ActivityPalette.orange
            onTint = .black
            let minutes = s.pausedUntil.map { ConvoyActivityPresentation.minutes(until: $0, now: now) } ?? 1
            title = String(localized: "Sharing paused")
            pauseEnd = s.pausedUntil
            caption = String(localized: "until back on")
            bigTint = ActivityPalette.orange
            small = (title, "", String(localized: "\(minutes) min"))
        case .arrived:
            symbol = Symbol.flag
            tint = ActivityPalette.positive
            onTint = .black
            title = String(localized: "Arrived in \(s.destination)")
            subtitle = s.tripName
            big = s.driveSeconds.map(ConvoyFormat.duration)
            caption = big == nil ? nil : String(localized: "drive time")
            bigTint = ActivityPalette.positive
            let n = s.arrivedCount ?? 0, total = s.arrivedTotal ?? 0
            line = n == total && total > 0 ? String(localized: "Everyone’s arrived") : String(localized: "\(n) of \(total) arrived")
            small = (title, line ?? "", s.driveSeconds.map(Self.hoursAndMinutes))
        case .tripEnded:
            symbol = Symbol.close
            tint = ActivityPalette.grey
            title = String(localized: "Trip ended")
            subtitle = s.tripName
            small = (title, s.tripName, nil)
        }
        if display.isNotUpdating {
            // Whatever it was, greyed, with this line; the island keeps its icon and value in grey (note 6).
            tint = ActivityPalette.grey
            onTint = ActivityPalette.grey
            bigTint = ActivityPalette.grey
            lineIsWarning = true
            let since = ConvoyFormat.clock(s.dataAt ?? now)
            line = String(localized: "Not updating since \(since)")
            request = nil
            small.line = String(localized: "Not updating")
        }
    }

    /// "Aisha 1.8 km ahead · Daniel 2.8 km behind": one form both ways; a half is left out when there is no such car.
    static func gapLine(_ s: State) -> String? {
        let ahead = s.aheadName.flatMap { name in s.aheadMeters.map { String(localized: "\(name) \(ConvoyFormat.distance($0)) ahead") } }
        let behind = s.behindName.flatMap { name in s.behindMeters.map { String(localized: "\(name) \(ConvoyFormat.distance($0)) behind") } }
        let parts = [ahead, behind].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Debris ahead": the word is built here from the event type the app sends (note 17).
    static func hazardTitle(_ type: String?) -> String {
        switch type {
        case "debris": String(localized: "Debris ahead")
        case "accident": String(localized: "Accident ahead")
        case "pothole": String(localized: "Pothole ahead")
        case "animal": String(localized: "Animal ahead")
        case "stoppedVehicle": String(localized: "Stopped vehicle ahead")
        case "roadworks": String(localized: "Roadworks ahead")
        default: String(localized: "Hazard ahead")
        }
    }

    /// The symbol of the reason, as `StopLogic.reasonSymbol` picks it.
    static func symbol(for reason: ConvoyActivityAttributes.Reason) -> String {
        switch reason {
        case .fuel: Symbol.fuel
        case .food: Symbol.food
        case .toilet: Symbol.toilet
        case .rest: Symbol.rest
        }
    }

    static func needs(_ name: String, _ reason: ConvoyActivityAttributes.Reason) -> String {
        switch reason {
        case .fuel: String(localized: "\(name) needs fuel")
        case .food: String(localized: "\(name) needs food")
        case .toilet: String(localized: "\(name) needs a toilet break")
        case .rest: String(localized: "\(name) needs a rest")
        }
    }

    static func theirStop(_ name: String, _ reason: ConvoyActivityAttributes.Reason) -> String {
        switch reason {
        case .fuel: String(localized: "\(name)’s fuel stop")
        case .food: String(localized: "\(name)’s food stop")
        case .toilet: String(localized: "\(name)’s toilet stop")
        case .rest: String(localized: "\(name)’s rest stop")
        }
    }

    static func youAsked(_ reason: ConvoyActivityAttributes.Reason) -> String {
        switch reason {
        case .fuel: String(localized: "You asked for fuel")
        case .food: String(localized: "You asked for food")
        case .toilet: String(localized: "You asked for a toilet break")
        case .rest: String(localized: "You asked for a rest")
        }
    }

    /// "2 h 41": the .small card's room is short, so "min" is dropped.
    static func hoursAndMinutes(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60)" : "\(minutes) min"
    }
}
