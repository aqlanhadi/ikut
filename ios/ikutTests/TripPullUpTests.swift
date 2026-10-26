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

    private func journey(_ stops: [PlannedStop], departedAt: Date? = nil) -> LobbyContent.Journey {
        LobbyContent.journey(stops, routeLength: 200_000, routeSeconds: 9_000, departedAt: departedAt, timeZone: utc)
    }

    // MARK: The journey

    @Test func beforeAnyStopIsPassedTheFoldLineIsWhenTheConvoyLeft() {
        let j = journey([stop("R&R Tapah", .rest, offset: 100_000, order: 0, minutes: 20),
                         stop("R&R Gopeng", .food, offset: 150_000, order: 1)], departedAt: at(12, 5))
        #expect(j.behind == "Left 12:05")
        #expect(j.ahead.map(\.name) == ["R&R Tapah", "R&R Gopeng"])
        #expect(j.ahead.map(\.number) == [1, 2])
        #expect(j.ahead[0].detail == "About 1 h 15 min in · stay 20 min")
    }

    @Test func aPassedStopFoldsIntoOneLineAndTheRestKeepTheirMapNumbers() {
        let j = journey([stop("R&R Bidor", .rest, offset: 50_000, order: 0, leftAt: at(12, 31), leftBy: "u1"),
                         stop("R&R Tapah", .fuel, offset: 100_000, order: 1),
                         stop("R&R Gopeng", .food, offset: 150_000, order: 2)], departedAt: at(12, 5))
        #expect(j.behind == "Passed R&R Bidor · 12:31")
        // The expanded sheet starts with what is still ahead, numbered as the pins are.
        #expect(j.ahead.map(\.name) == ["R&R Tapah", "R&R Gopeng"])
        #expect(j.ahead.map(\.number) == [2, 3])
    }

    @Test func theFoldLineNamesTheLastStopPassed() {
        let j = journey([stop("A", .rest, offset: 50_000, order: 0, leftAt: at(12, 31)),
                         stop("B", .fuel, offset: 100_000, order: 1, leftAt: at(13, 2)),
                         stop("C", .food, offset: 150_000, order: 2)])
        #expect(j.behind == "Passed B · 1:02")
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
        #expect(j.behind == "Left Petronas · 12:05")
        #expect(j.ahead.map(\.name) == ["B"])
        #expect(j.ahead.map(\.number) == [2])
    }

    @Test func noStopsAndNoStartTimeLeaveNoFoldLine() {
        let j = journey([])
        #expect(j.behind == nil)
        #expect(j.ahead.isEmpty)
    }

    // MARK: Who gets which rows

    private func rows(organizer: Bool, sharing: Bool = true, live: Bool = true) -> LobbyContent.Rows {
        LobbyContent.rows(isOrganizer: organizer, started: true, ended: false, isLiveMember: live, trackingOrPaused: sharing)
    }

    @Test func theOrganiserPullsUpTheJourneyCodeTripOptionsAndEndOrLeave() {
        let up = LobbyContent.pulledUp(rows(organizer: true))
        #expect(up.sections == [.journey, .code, .trip, .options, .exit])
        #expect(up.changeDestination)
        #expect(up.pause)
        #expect(up.end)
        #expect(up.leave)
    }

    @Test func aParticipantPullsUpTheSameButOnlyLeavesAndNeverChangesTheDestination() {
        let up = LobbyContent.pulledUp(rows(organizer: false))
        #expect(up.sections == [.journey, .code, .trip, .options, .exit])
        #expect(!up.changeDestination)
        #expect(!up.end)
        #expect(up.leave)
    }

    @Test func aPassengerWhosePhoneDoesNotShareHasNoPause() {
        let up = LobbyContent.pulledUp(rows(organizer: false, sharing: false))
        #expect(!up.pause)
        // Keep screen on is still there, so the options stay.
        #expect(up.sections.contains(.options))
    }

    @Test func noLongerInTheTripLeavesNothingToLeave() {
        let up = LobbyContent.pulledUp(rows(organizer: false, live: false))
        #expect(!up.sections.contains(.exit))
        #expect(!up.pause)
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
