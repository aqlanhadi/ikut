#if DEBUG
import Foundation

/// The sample convoy behind every Debug-only look at the Live Activity: the `IKUT_SCREEN=live-activity-<state>` launch
/// states (`LiveActivityDemo`) and the Xcode previews of the widget views (`ikutWidgets/ActivityPreviews.swift`). Both
/// targets compile this one file, so a preview and the real activity are made by the same `ConvoyActivityLogic.state`
/// from the same inputs and cannot drift. Debug builds only; a Release build leaves it out.
enum LiveActivitySamples {
    static let names = [
        "waiting", "waiting-organiser", "joining", "joining-destination", "parked-ahead", "heads-up", "in-convoy",
        "last-leg", "at-stop", "hazard", "hazard-no-distance", "stop-request", "after-ok", "my-request", "stopped",
        "stopped-lead", "paused", "not-updating", "arrived", "ended",
    ]

    /// The state `ConvoyActivityLogic.state` makes for a sample, and the stale date when the sample is a stale one.
    static func state(_ name: String) -> (state: ConvoyActivityAttributes.ContentState, staleDate: Date?) {
        let (input, staleOffset) = Self.input(name)
        let (state, stale) = ConvoyActivityLogic.state(input)
        return (state, staleOffset.map { input.now.addingTimeInterval($0) } ?? stale)
    }

    /// The sample: Aqlan in car 2 between Aisha (lead, car 1) and Daniel (car 3), Wyna last; R&R Tapah ahead, Ipoh 63 km.
    /// The second value is a stale date relative to now, for the one state that is made by the date passing.
    static func input(_ name: String) -> (ConvoyActivityInput, TimeInterval?) {
        let now = Date()
        var i = ConvoyActivityInput(now: now, tripName: "Balik kampung raya", destination: "Ipoh")
        i.carCount = 4
        i.readyCars = 3
        i.organizerName = "Aisha"
        i.myOffset = 50_000
        i.dots = [
            .init(name: "Aisha", color: "#D9480F", offset: 51_800, gapAhead: nil),
            .init(name: "Aqlan", color: "#2563EB", offset: 50_000, gapAhead: 1_800, isMine: true),
            .init(name: "Daniel", color: "#7C3AED", offset: 47_200, gapAhead: 2_800),
            .init(name: "Wyna", color: "#0D9488", offset: 44_000, gapAhead: 3_200),
        ]
        i.destinationMeters = 63_000
        i.destinationSeconds = 41 * 60
        i.spreadMeters = 6_800
        i.newestOtherData = now.addingTimeInterval(-5)
        i.nextStop = .init(name: "R&R Tapah", offset: 59_000, meters: 18_000, seconds: 12 * 60, isHere: false)
        let request = ConvoyActivityInput.Request(
            requesterName: "Wyna", reason: .fuel, meters: -5_000, okCount: 2, total: 4, iSaidOK: false, iAsked: false,
            owesMyAnswer: true, since: now)
        switch name {
        case "waiting", "waiting-organiser":
            i.tripStarted = false
            i.isOrganizer = name == "waiting-organiser"
            i.dots = []
            i.myOffset = nil
            i.nextStop = nil
        case "joining", "joining-destination":
            i.dots = []
            i.myOffset = nil
            i.nextStop = nil
            i.joining = .init(place: name == "joining" ? "Rawang" : nil, meetsAtDestination: name != "joining", amount: .distance(name == "joining" ? 14_000 : 160_000))
        case "parked-ahead":
            i.dots = [.init(name: "Aqlan", color: "#2563EB", offset: 50_000, gapAhead: nil, isMine: true),
                      .init(name: "Aisha", color: "#D9480F", offset: 26_000, gapAhead: 24_000)]
            i.parkedAhead = .init(name: "Aisha", meters: 24_000, seconds: nil)
            i.nextStop = nil
        case "heads-up":
            i.dots = [.init(name: "Aqlan", color: "#2563EB", offset: 50_000, gapAhead: nil, isMine: true),
                      .init(name: "Aisha", color: "#D9480F", offset: 46_700, gapAhead: 3_300),
                      .init(name: "Daniel", color: "#7C3AED", offset: 44_600, gapAhead: 2_100),
                      .init(name: "Wyna", color: "#0D9488", offset: 41_000, gapAhead: 3_600)]
            i.headsUp = .init(name: "Aisha", meters: 3_300, seconds: 120)
        case "in-convoy": break
        case "last-leg": i.nextStop = nil
        case "at-stop":
            i.nextStop = .init(name: "R&R Tapah", offset: 50_050, meters: 0, seconds: nil, isHere: true)
            let leave = now.addingTimeInterval(12 * 60)
            i.stopHere = .init(here: 3, total: 4, leaveAt: leave, toGoSeconds: 29 * 60)
        case "hazard", "hazard-no-distance":
            i.hazard = .init(type: "debris", reporter: "Wyna", meters: name == "hazard" ? 350 : nil, offset: 50_350)
        case "stop-request": i.request = request
        case "after-ok":
            i.request = .init(requesterName: "Wyna", reason: .fuel, meters: -5_000, okCount: 3, total: 4, iSaidOK: true, iAsked: false, owesMyAnswer: false, since: now)
        case "my-request":
            i.request = .init(requesterName: "Aqlan", reason: .fuel, meters: nil, okCount: 3, total: 4, iSaidOK: false, iAsked: true, owesMyAnswer: false, since: now)
        case "stopped", "stopped-lead":
            i.convoyStopSince = now.addingTimeInterval(-12 * 60)
            i.mayEndConvoyStop = name == "stopped-lead"
        case "paused": i.pausedUntil = now.addingTimeInterval(23 * 60)
        case "not-updating":
            i.newestOtherData = now.addingTimeInterval(-5 * 60)
            return (i, -180)
        case "arrived": i.arrived = .init(count: 3, total: 4, driveSeconds: 2 * 3600 + 41 * 60)
        case "ended": i.tripEnded = true
        default: break
        }
        return (i, nil)
    }
}
#endif
