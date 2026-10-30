import FirebaseFunctions
import Foundation
import Testing
@testable import ikut

/// D106: the organiser of a live trip hands it over (or ends it) instead of leaving.
struct HandOverTests {
    private func member(_ id: String, _ name: String, car: String = "c1") -> Member {
        Member(id: id, displayName: name, carId: car, role: .member)
    }
    private func car(_ id: String, _ name: String) -> Car {
        Car(id: id, name: name, color: "#000", trackerUserId: nil, isLead: false, route: nil, mergeOffset: nil, state: .convoy, number: 1)
    }
    private func rows(organizer: Bool, others: Int, started: Bool = false, ended: Bool = false) -> LobbyContent.Rows {
        LobbyContent.rows(
            isOrganizer: organizer, started: started, ended: ended, isLiveMember: !ended, trackingOrPaused: false, otherMembers: others)
    }

    // MARK: The exit rows

    @Test func theOrganiserWithOthersGetsHandOverAndEndButNotLeave() {
        for started in [false, true] {
            let r = rows(organizer: true, others: 2, started: started)
            #expect(r.canHandOver && r.canEnd && !r.canLeave)
        }
    }

    @Test func theOrganiserAloneCanOnlyEnd() {
        let r = rows(organizer: true, others: 0, started: true)
        #expect(!r.canHandOver && !r.canLeave && r.canEnd)
        #expect(LobbyContent.pulledUp(r).contains(.exit))
    }

    @Test func aMemberLeavesAsBeforeAndCannotHandOver() {
        let r = rows(organizer: false, others: 3)
        #expect(r.canLeave && !r.canHandOver && !r.canEnd)
    }

    @Test func anEndedTripOffersNeitherHandOverNorEnd() {
        let r = rows(organizer: true, others: 2, started: true, ended: true)
        #expect(!r.canHandOver && !r.canEnd && !r.canLeave)
    }

    @Test func theListHasEveryoneButTheOrganiserByNameWithTheirCar() {
        let people = LobbyLogic.handOverCandidates(
            members: [member("u1", "Aqlan"), member("u3", "wyna", car: "c2"), member("u2", "Faiz"), member("u4", "Ghost", car: "gone")],
            cars: [car("c1", "Aqlan’s Myvi"), car("c2", "Wyna’s X70")], me: "u1")
        #expect(people.map(\.name) == ["Faiz", "Ghost", "wyna"])
        #expect(people.map(\.carName) == ["Aqlan’s Myvi", nil, "Wyna’s X70"])
        #expect(!people.contains { $0.id == "u1" })
    }

    // MARK: The flow

    @Test func pickingThenAskingThenWorkingThenLandedExitsOnce() {
        var flow = ExitFlow()
        flow.startPicking()
        #expect(flow.picking && !flow.busy && flow.canGoBack)
        flow.choose(id: "u2", name: "Wyna")
        #expect(flow.asking == .handOver && flow.target == .init(id: "u2", name: "Wyna"))
        flow.confirm(.handOver)
        #expect(flow.working == .handOver && flow.progress == .handOver && flow.busy && !flow.canGoBack)
        let first = flow.land()
        let second = flow.land()
        #expect(first && !second && flow.progress == .handOver)
    }

    @Test func cancelInTheListGoesBackToTheRows() {
        var flow = ExitFlow()
        flow.startPicking()
        flow.stopPicking()
        #expect(flow.phase == .idle)
        // Nothing is chosen from outside the list, and there is no hand-over without someone chosen.
        flow.choose(id: "u2", name: "Wyna")
        flow.confirm(.handOver)
        flow.ask(.handOver)
        #expect(flow.phase == .idle)
    }

    @Test func cancellingTheAlertBacksOutAndTheDialogClosingAfterTheTapChangesNothing() {
        var flow = ExitFlow()
        flow.startPicking()
        flow.choose(id: "u2", name: "Wyna")
        flow.cancel(.handOver)
        #expect(flow.phase == .idle && !flow.busy)
        flow.startPicking()
        flow.choose(id: "u2", name: "Wyna")
        flow.confirm(.handOver)
        flow.cancel(.handOver)
        flow.confirm(.leave)
        #expect(flow.working == .handOver)
    }

    @Test func aHandOverThatFailsReturnsTheRowsWithTheWordsAndATryStartsClean() {
        var flow = ExitFlow()
        flow.startPicking()
        flow.choose(id: "u2", name: "Wyna")
        flow.confirm(.handOver)
        flow.fail("Can’t reach the server. Check your signal and try again.")
        #expect(flow.phase == .idle && flow.error != nil && flow.canGoBack)
        let late = flow.land()
        #expect(!late)
        flow.startPicking()
        flow.choose(id: "u3", name: "Faiz")
        flow.confirm(.handOver)
        #expect(flow.error == nil && flow.target?.id == "u3")
    }

    @MainActor @Test func theRunnerExitsOnlyWhileTheScreenIsLiveAndNotTwice() async {
        let live = ExitRunner()
        live.flow.startPicking()
        live.flow.choose(id: "u2", name: "Wyna")
        var exits = 0
        #expect(await live.run(.handOver, write: {}, exit: { exits += 1 }) == nil)
        #expect(exits == 1)
        #expect(await live.run(.handOver, write: {}, exit: { exits += 1 }) == nil && exits == 1)

        let gone = ExitRunner()
        gone.flow.startPicking()
        gone.flow.choose(id: "u2", name: "Wyna")
        gone.live = false
        _ = await gone.run(.handOver, write: {}, exit: { exits += 1 })
        #expect(exits == 1)
    }

    // MARK: The two writes

    private struct Down: Error {}

    @MainActor @Test func aHandOverThatDoesNotLandNeverLeaves() async {
        var left = 0
        await #expect(throws: Down.self) {
            try await TripService.handOverAndLeave(to: "Wyna", handOver: { throw Down() }, leave: { left += 1 })
        }
        #expect(left == 0)
    }

    @MainActor @Test func aLandedHandOverThenLeavesOnce() async throws {
        var steps: [String] = []
        try await TripService.handOverAndLeave(to: "Wyna", handOver: { steps.append("hand") }, leave: { steps.append("leave") })
        #expect(steps == ["hand", "leave"])
    }

    @MainActor @Test func aLandedHandOverWithTheLeaveFailingSaysSoAndKeepsThemInTheTrip() async {
        do {
            try await TripService.handOverAndLeave(to: "Wyna", handOver: {}, leave: { throw LeaveFailed() })
            Issue.record("should have thrown")
        } catch {
            #expect(error.localizedDescription == "Wyna is the organiser now, but you’re still in the trip. Check your signal, then tap Leave trip.")
        }
    }

    @Test func failuresUsePlainWords() {
        let m = { TripService.handOverFailureMessage(code: $0, retryAfterSeconds: $1) }
        #expect(m(.unavailable, nil) == "Can’t reach the server. Check your signal and try again.")
        #expect(m(.invalidArgument, nil) == "That person isn’t in the trip any more. Pick someone else.")
        #expect(m(.failedPrecondition, nil) == "This trip has ended, so it can’t be handed over.")
        #expect(m(.permissionDenied, nil) == "You’re not the organiser any more, so you can’t hand the trip over.")
        #expect(m(.resourceExhausted, 240) == "You’ve handed this trip over a lot lately. Try again in 4 minutes.")
        #expect(m(.resourceExhausted, nil) == "You’ve handed this trip over a lot lately. Try again in a little while.")
        #expect(m(.internal, nil) == "Couldn’t hand the trip over just now. Please try again.")
    }
}
