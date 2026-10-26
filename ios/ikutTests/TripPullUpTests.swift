import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

/// While driving, the convoy sheet pulled to its tallest continues with the lobby (D53 piece 3, canvas row L): the
/// journey still ahead with what was driven folded into one line, the code, the trip, the options and Leave or End.
struct TripPullUpTests {
    private let utc = TimeZone(identifier: "UTC")!
    private func at(_ hour: Int, _ minute: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(hour * 3600 + minute * 60)) }

    private func stop(
        _ id: String, _ kind: PlannedStopKind, offset: Double, order: Int, minutes: Int? = nil,
        leftAt: Date? = nil, leftBy: String? = nil, skipped: Bool? = nil
    ) -> PlannedStop {
        var s = PlannedStop(id: id, name: id, coordinate: GeoPoint(latitude: 4, longitude: 101), routeOffset: offset,
                            kind: kind, minutes: minutes, order: order)
        s.leftAt = leftAt
        s.leftBy = leftBy
        s.skipped = skipped
        return s
    }

    private let enUS = Locale(identifier: "en_US")
    /// The header's clock ("7:42 PM", with whatever space the formatter puts before PM).
    private func clock(_ date: Date) -> String { ConvoyFormat.clock(date, locale: enUS, timeZone: utc) }

    private func journey(
        _ stops: [PlannedStop], departedAt: Date? = nil, here: LobbyContent.JourneyHere? = nil
    ) -> LobbyContent.Journey {
        LobbyContent.journey(stops, routeLength: 200_000, routeSeconds: 9_000, departedAt: departedAt, here: here,
                             locale: enUS, timeZone: utc)
    }

    // MARK: The journey

    @Test func beforeAnyStopIsPassedTheFoldLineIsWhenTheConvoyLeft() {
        let j = journey([stop("R&R Tapah", .rest, offset: 100_000, order: 0, minutes: 20),
                         stop("R&R Gopeng", .food, offset: 150_000, order: 1)], departedAt: at(19, 42))
        // The header's clock ("Left 7:42 PM"), not the meeting time's.
        #expect(j.behind == "Left \(clock(at(19, 42)))")
        #expect(clock(at(19, 42)).hasSuffix("PM"))
        #expect(j.ahead.map(\.name) == ["R&R Tapah", "R&R Gopeng"])
        #expect(j.ahead.map(\.number) == [1, 2])
        // Without my car's place yet: how far into the trip, as in the lobby.
        #expect(j.ahead[0].detail == "About 1 h 15 min in · stay 20 min")
    }

    @Test func aPassedStopFoldsIntoOneLineAndTheRestKeepTheirMapNumbers() {
        let j = journey([stop("R&R Bidor", .rest, offset: 50_000, order: 0, leftAt: at(20, 31), leftBy: "u1"),
                         stop("R&R Tapah", .fuel, offset: 100_000, order: 1),
                         stop("R&R Gopeng", .food, offset: 150_000, order: 2)], departedAt: at(19, 42))
        #expect(j.behind == "Passed R&R Bidor · \(clock(at(20, 31)))")
        // The expanded sheet starts with what is still ahead, numbered as the pins are.
        #expect(j.ahead.map(\.name) == ["R&R Tapah", "R&R Gopeng"])
        #expect(j.ahead.map(\.number) == [2, 3])
    }

    @Test func theFoldLineNamesTheLastStopPassed() {
        let j = journey([stop("A", .rest, offset: 50_000, order: 0, leftAt: at(12, 31)),
                         stop("B", .fuel, offset: 100_000, order: 1, leftAt: at(13, 2)),
                         stop("C", .food, offset: 150_000, order: 2)])
        #expect(j.behind == "Passed B · \(clock(at(13, 2)))")
        #expect(j.ahead.map(\.name) == ["C"])
    }

    @Test func aLeaveNotYetOnTheServerIsPassedWithoutATime() {
        let j = journey([stop("A", .rest, offset: 50_000, order: 0, leftBy: "u1"), stop("B", .fuel, offset: 100_000, order: 1)])
        #expect(j.behind == "Passed A")
        #expect(j.ahead.map(\.name) == ["B"])
    }

    @Test func theMeetingPointLeftReadsLeftAndASkippedStopIsNotAhead() {
        let j = journey([stop("Petronas", .meet, offset: 0, order: 0, leftAt: at(12, 5)),
                         stop("A", .rest, offset: 50_000, order: 1, skipped: true),
                         stop("B", .fuel, offset: 100_000, order: 2)])
        #expect(j.behind == "Left Petronas · \(clock(at(12, 5)))")
        #expect(j.ahead.map(\.name) == ["B"])
        #expect(j.ahead.map(\.number) == [2])
    }

    @Test func noStopsAndNoStartTimeLeaveNoFoldLine() {
        let j = journey([])
        #expect(j.behind == nil)
        #expect(j.ahead.isEmpty)
    }

    // MARK: The journey from where my car is

    @Test func aStopMyCarDroveByWithoutALeaveFoldsAwayWithoutATime() {
        // My car is 2 km past R&R Tapah; nobody tapped Leave there.
        let here = LobbyContent.JourneyHere(offset: 102_000, pace: 0.04)
        let j = journey([stop("R&R Tapah", .rest, offset: 100_000, order: 0, minutes: 20),
                         stop("R&R Gopeng", .food, offset: 150_000, order: 1)], departedAt: at(12, 5), here: here)
        #expect(j.behind == "Passed R&R Tapah")
        #expect(j.ahead.map(\.name) == ["R&R Gopeng"])
        #expect(j.ahead.map(\.number) == [2])
    }

    @Test func aStopWithinTheHereRadiusIsStillAheadAndReadsHere() {
        let here = LobbyContent.JourneyHere(offset: 100_000 + NextStop.hereRadius - 10, pace: 0.04)
        let j = journey([stop("R&R Tapah", .rest, offset: 100_000, order: 0, minutes: 20)], departedAt: at(12, 5), here: here)
        #expect(j.ahead.map(\.name) == ["R&R Tapah"])
        #expect(j.ahead[0].detail == "Here · stay 20 min")
        #expect(j.behind?.hasPrefix("Left ") == true)
    }

    @Test func midTripAStopAheadReadsTheDistanceAndTimeFromMyCarAsNextStopDoes() {
        // 18 km ahead at 25 m/s: 12 min, as the panel's Next stop says it.
        let here = LobbyContent.JourneyHere(offset: 82_000, pace: 0.04)
        let tapah = stop("R&R Tapah", .rest, offset: 100_000, order: 0, minutes: 20)
        let j = journey([tapah, stop("R&R Gopeng", .food, offset: 150_000, order: 1)], here: here)
        let cell = NextStop.cell(stops: [tapah], offset: 82_000, pace: 0.04)
        #expect(cell?.detail == "18 km · 12 min")
        #expect(j.ahead[0].detail == "18 km · 12 min · stay 20 min")
        // No pace yet: just the distance.
        let still = journey([tapah], here: .init(offset: 82_000, pace: nil))
        #expect(still.ahead[0].detail == "18 km · stay 20 min")
    }

    // MARK: Who gets which sections

    private func rows(organizer: Bool, sharing: Bool = true, live: Bool = true) -> LobbyContent.Rows {
        LobbyContent.rows(isOrganizer: organizer, started: true, ended: false, isLiveMember: live, trackingOrPaused: sharing)
    }

    @Test func theOrganiserAndAParticipantPullUpTheSameSectionsTheirRowsDecideTheRest() {
        #expect(LobbyContent.pulledUp(rows(organizer: true)) == [.journey, .code, .trip, .options, .exit])
        #expect(LobbyContent.pulledUp(rows(organizer: false)) == [.journey, .code, .trip, .options, .exit])
        // Inside them the lobby's rows decide: the organiser ends and changes the destination, a participant leaves.
        let organiser = rows(organizer: true)
        #expect(organiser.canEnd && organiser.canLeave && organiser.canChangeDestination && organiser.canPause)
        let participant = rows(organizer: false, sharing: false)
        #expect(!participant.canEnd && participant.canLeave && !participant.canChangeDestination && !participant.canPause)
    }

    @Test func noLongerInTheTripLeavesNothingToLeave() {
        #expect(!LobbyContent.pulledUp(rows(organizer: false, live: false)).contains(.exit))
    }

    // MARK: What the convoy sheet steps aside for

    @Test func drivingTheSheetStaysUpForLeaveEndAndRenameAndStepsAsideForWhatTakesTheScreen() {
        func cover(_ change: (inout LobbySheet.Cover) -> Void) -> LobbySheet.Cover { var c = LobbySheet.Cover(); change(&c); return c }
        // Presented from inside the pulled-up sheet: it stays up, so Cancel leaves it pulled up.
        #expect(!LobbySheet.drivingCovered(cover { $0.confirmEnd = true }, lobbyOnScreen: true))
        #expect(!LobbySheet.drivingCovered(cover { $0.confirmLeave = true }, lobbyOnScreen: true))
        #expect(!LobbySheet.drivingCovered(cover { $0.renaming = true }, lobbyOnScreen: true))
        // Pushed or presented over the whole screen: it steps aside.
        #expect(LobbySheet.drivingCovered(cover { $0.changeDestination = true }, lobbyOnScreen: true))
        #expect(LobbySheet.drivingCovered(cover { $0.alwaysExplainer = true }, lobbyOnScreen: true))
        #expect(LobbySheet.drivingCovered(LobbySheet.Cover(), lobbyOnScreen: false))
        #expect(!LobbySheet.drivingCovered(LobbySheet.Cover(), lobbyOnScreen: true))
    }

    @Test func theAsksInsideThePulledUpSheetGoWithItAndNeverComeBackUntapped() {
        let up = LobbySheet.PulledUpAsks(confirmLeave: true, confirmEnd: true, renaming: true, showQR: true)
        // Still pulled up: kept.
        #expect(LobbySheet.pulledUpAsks(up, continuationShown: true) == up)
        // Folded by the grabber, the header, a stop request or a hazard: all cleared.
        #expect(LobbySheet.pulledUpAsks(up, continuationShown: false) == LobbySheet.PulledUpAsks())
    }

    // MARK: No longer in the trip, driving (#403)

    @Test func drivingTheNoLongerInTheTripBannerShowsAndTheEndOpensTheRecapInstead() {
        #expect(LobbyContent.drivingBanner(ended: false, membershipLost: true, tripLoaded: true) == .noLongerInTrip)
        #expect(LobbyContent.drivingBanner(ended: false, membershipLost: false, tripLoaded: true) == nil)
        #expect(LobbyContent.drivingBanner(ended: true, membershipLost: true, tripLoaded: true) == nil)
        #expect(LobbyContent.drivingBanner(ended: false, membershipLost: true, tripLoaded: false) == nil)
        // The lobby keeps both.
        #expect(LobbyContent.exitBanner(ended: true, membershipLost: false, tripLoaded: true) == .ended)
        #expect(LobbyContent.exitBanner(ended: false, membershipLost: true, tripLoaded: true) == .noLongerInTrip)
    }

    // MARK: The lobby's header while this phone shares (#394)

    @Test func theSubtitleSaysSharingOnlyBeforeTheStartWhileThisPhoneShares() {
        #expect(LobbyContent.subtitleSharing(tracking: true, paused: false, started: false, ended: false))
        // Paused: the paused banner says so; the subtitle drops Sharing.
        #expect(!LobbyContent.subtitleSharing(tracking: true, paused: true, started: false, ended: false))
        #expect(!LobbyContent.subtitleSharing(tracking: false, paused: false, started: false, ended: false))
        #expect(!LobbyContent.subtitleSharing(tracking: true, paused: false, started: true, ended: false))
        #expect(!LobbyContent.subtitleSharing(tracking: true, paused: false, started: false, ended: true))
    }

    @Test func theSharingSubtitleLeadsTheUsualLine() {
        let rest = LobbyContent.subtitle(destination: "Ipoh", meetAt: nil, code: "K7M2QX", started: false, ended: false,
                                         startedAt: nil, timeZone: utc)
        #expect(LobbyContent.subtitleWords(rest, sharing: true) == "Sharing · To Ipoh · code K7M 2QX")
        #expect(LobbyContent.subtitleWords(rest, sharing: false) == "To Ipoh · code K7M 2QX")
        #expect(LobbyContent.subtitleWords(nil, sharing: true) == "Sharing")
        #expect(LobbyContent.subtitleWords(nil, sharing: false) == nil)
    }

    // MARK: When the lobby listens

    @Test func theLobbyListensInItsOwnModeAndWhileDrivingOnlyWithTheSheetPulledUp() {
        #expect(TripScreenLogic.lobbyListens(onScreen: true, mode: .lobby, pulledUp: false))
        #expect(TripScreenLogic.lobbyListens(onScreen: true, mode: .lobby, pulledUp: true))
        // Driving with the convoy sheet short or tall: the convoy listens, the lobby rests.
        #expect(!TripScreenLogic.lobbyListens(onScreen: true, mode: .driving, pulledUp: false))
        #expect(TripScreenLogic.lobbyListens(onScreen: true, mode: .driving, pulledUp: true))
        // Another screen pushed over the trip, or the trip screen gone: nothing listens.
        #expect(!TripScreenLogic.lobbyListens(onScreen: false, mode: .lobby, pulledUp: false))
        #expect(!TripScreenLogic.lobbyListens(onScreen: false, mode: .driving, pulledUp: true))
    }
}
