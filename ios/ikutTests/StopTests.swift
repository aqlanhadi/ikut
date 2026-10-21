import CoreLocation
import FirebaseAuth
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

// MARK: Pure logic

struct StopLogicTests {
    private let t0 = Fixtures.t0

    private func car(_ id: String, _ number: Int?, _ name: String, tracker: String? = nil, lead: Bool = false) -> Car {
        Car(
            id: id, name: name, color: "#2563EB", trackerUserId: tracker, isLead: lead, route: nil,
            mergeOffset: nil, state: .convoy, number: number)
    }

    private func stop(by carId: String = "c2", author: String = "u2", expires: Date? = nil, place: StopPlace? = nil) -> TripEvent {
        var e = TripEvent(
            type: .stopFuel, location: GeoPoint(latitude: 3, longitude: 101), heading: 0, routeOffset: 0,
            authorId: author, carId: carId, createdAt: t0)
        e.id = "stop1"
        e.expiresAt = expires
        e.place = place
        return e
    }

    private func vote(_ carId: String, agree: Bool, suggestion: StopPlace? = nil) -> StopVote {
        StopVote(id: carId, userId: "u-\(carId)", agree: agree, at: t0, suggestion: suggestion)
    }

    private func place(_ name: String = "R&R", offset: Double = 18_000, pinned: String? = nil) -> StopPlace {
        StopPlace(name: name, coordinate: GeoPoint(latitude: 3, longitude: 101), routeOffset: offset, pinnedBy: pinned)
    }

    private var cars: [Car] {
        [
            car("c4", 4, "Daniel’s City", tracker: "u4"),
            car("c1", 1, "Aqlan’s Myvi", tracker: "u1", lead: true),
            car("c3", 3, "Hafiz’s Hilux", tracker: "u3"),
            car("c2", 2, "Wyna’s X70", tracker: "u2"),
            car("c5", 5, "Untracked"),
        ]
    }

    private func tally(
        _ event: TripEvent, votes: [StopVote] = [], me: String = "c1", user: String = "u1",
        organizer: Bool = false, offset: Double? = 0, now: Date? = nil
    ) throws -> StopRequestState {
        try #require(StopLogic.tally(
            event: event, votes: votes, cars: cars, myUserId: user, myCarId: me, isOrganizer: organizer,
            viewerOffset: offset, now: now ?? t0.addingTimeInterval(60)))
    }

    @Test func rowsAreOrderedByNumberAndSkipUntrackedCars() throws {
        let state = try tally(stop())
        #expect(state.rows.map(\.carId) == ["c1", "c2", "c3", "c4"])
        #expect(state.rows.first { $0.isMine }?.name == "Aqlan’s Myvi (you)")
    }

    @Test func requesterCountsAsAgreedOthersWaiting() throws {
        let state = try tally(stop())
        #expect(state.rows.map(\.status) == [.waiting, .agreed, .waiting, .waiting])
        #expect(state.agreedCount == 1)
        #expect(state.viewerAgrees == false)
    }

    @Test func votesTally() throws {
        let state = try tally(stop(), votes: [vote("c1", agree: true), vote("c3", agree: true), vote("c4", agree: false)])
        #expect(state.rows.map(\.status) == [.agreed, .agreed, .agreed, .waiting])
        #expect(state.agreedCount == 3)
        #expect(state.viewerAgrees)
    }

    @Test func aNoVoteWithSuggestionShowsSuggested() throws {
        let alt = place("Other R&R", offset: 26_000)
        let state = try tally(stop(), votes: [vote("c3", agree: false, suggestion: alt)])
        #expect(state.rows.first { $0.carId == "c3" }?.status == .suggested)
        #expect(state.alternatives.map(\.carId) == ["c3"])
        #expect(state.alternatives.first?.suggestion == alt)
    }

    @Test func requesterProposalIsItsOwnSuggestion() throws {
        let proposal = place("Proposed")
        let state = try tally(stop(), votes: [vote("c2", agree: true, suggestion: proposal)])
        #expect(state.proposal == proposal)
        #expect(state.alternatives.isEmpty)
        #expect(state.shownPlace == proposal)
    }

    @Test func pinnedPlaceWinsOverProposal() throws {
        let pinned = place("Pinned", pinned: "u1")
        let state = try tally(stop(place: pinned), votes: [vote("c2", agree: true, suggestion: place("Proposed"))])
        #expect(state.shownPlace == pinned)
    }

    @Test func aVoterOnAnUntrackedCarGetsARow() throws {
        let state = try tally(stop(), votes: [vote("c5", agree: true)])
        #expect(state.rows.map(\.carId).contains("c5"))
    }

    @Test func titleAndSubtitle() throws {
        let state = try tally(stop())
        #expect(state.title == "Wyna needs fuel")
        #expect(state.subtitle(now: t0.addingTimeInterval(65)) == "Car 2 · asked 1 min ago")
        #expect(state.subtitle(now: t0.addingTimeInterval(5)) == "Car 2 · asked just now")
        #expect(StopLogic.ownerName(fromCarName: "Wyna's car") == "Wyna")
        #expect(StopLogic.ownerName(fromCarName: "Convoy") == "Convoy")
        #expect(StopRequestState.need(for: .stopFood) == "needs food")
        #expect(StopRequestState.need(for: .stopToilet) == "needs a toilet break")
        #expect(StopRequestState.need(for: .stopRest) == "needs a rest")
    }

    @Test func distanceAndEtaToPlace() throws {
        let state = try tally(stop(place: place(offset: 18_000, pinned: "u1")), offset: 0)
        #expect(state.distanceText == "18 km ahead")
        #expect(state.etaText == "About 12 min")
        let passed = try tally(stop(place: place(offset: 18_000, pinned: "u1")), offset: 20_000)
        #expect(passed.distanceText == "Passed")
        #expect(passed.etaText == nil)
        let unknown = try tally(stop(place: place(pinned: "u1")), offset: nil)
        #expect(unknown.distanceText == nil)
    }

    // The UI gating: who may pin and resolve.

    @Test func leadCarTrackerCanPinAndResolve() throws {
        let state = try tally(stop(), me: "c1", user: "u1")
        #expect(state.canPin)
        #expect(state.canResolve)
    }

    @Test func organizerCanPinAndResolve() throws {
        let state = try tally(stop(), me: "c3", user: "u3", organizer: true)
        #expect(state.canPin)
        #expect(state.canResolve)
    }

    @Test func requesterCanResolveButNotPin() throws {
        let state = try tally(stop(), me: "c2", user: "u2")
        #expect(state.canPin == false)
        #expect(state.canResolve)
    }

    @Test func otherMemberCanNeitherPinNorResolve() throws {
        let state = try tally(stop(), me: "c3", user: "u3")
        #expect(state.canPin == false)
        #expect(state.canResolve == false)
    }

    @Test func leadFlagOnSomeoneElsesCarGrantsNothing() throws {
        // u9 shares car c1's lead flag in the viewer's context but doesn't track it.
        let state = try tally(stop(), me: "c1", user: "u9")
        #expect(state.canPin == false)
    }

    @Test func permissionsTruthTable() {
        #expect(StopPermissions.canPin(isLeadTracker: false, isOrganizer: false) == false)
        #expect(StopPermissions.canPin(isLeadTracker: true, isOrganizer: false))
        #expect(StopPermissions.canPin(isLeadTracker: false, isOrganizer: true))
        #expect(StopPermissions.canResolve(isAuthor: false, isLeadTracker: false, isOrganizer: false) == false)
        #expect(StopPermissions.canResolve(isAuthor: true, isLeadTracker: false, isOrganizer: false))
    }

    @Test func resolvedWhenExpired() throws {
        let state = try tally(stop(expires: t0), now: t0.addingTimeInterval(1))
        #expect(state.isResolved)
        #expect(try tally(stop()).isResolved == false)
    }

    // MARK: Open requests (D20)

    private func request(
        _ id: String, by carId: String = "c2", author: String = "u2", at offset: TimeInterval = 0,
        place: StopPlace? = nil, status: StopStatus? = nil, closedReason: StopClosedReason? = nil,
        expires: Date? = nil, type: EventType = .stopFuel
    ) -> TripEvent {
        var e = stop(by: carId, author: author, expires: expires, place: place)
        e.id = id
        e.type = type
        e.createdAt = t0.addingTimeInterval(offset)
        e.status = status
        e.closedReason = closedReason
        return e
    }

    @Test func openStopsListsEveryOpenRequestOldestFirst() {
        let a = request("a", at: 10)
        let b = request("b", at: 0)
        let done = request("done", at: 20, expires: t0.addingTimeInterval(5))
        let closed = request("closed", at: 30, status: .closed, closedReason: .left)
        var hazard = request("h", at: 40); hazard.category = .hazard
        let now = t0.addingTimeInterval(60)
        #expect(StopLogic.openStops(in: [a, b, done, closed, hazard], now: now).map(\.id) == ["b", "a"])
        #expect(StopLogic.openStops(in: [done, closed, hazard], now: now).isEmpty)
    }

    @Test func aMissingStatusReadsAsOpenAndClosedNeverIs() {
        let old = request("old")
        #expect(old.status == nil)
        #expect(StopLogic.isOpen(old, now: t0.addingTimeInterval(1)))
        // Closing sets expiresAt too, so old builds see it as resolved; a status alone also closes it here.
        #expect(!StopLogic.isOpen(request("x", status: .closed), now: t0.addingTimeInterval(1)))
        #expect(StopLogic.isOpen(request("p", status: .pinned), now: t0.addingTimeInterval(1)))
    }

    @Test func statusAndClosingReasonsDecodeWithFallbacks() throws {
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ json: String, as: T.Type) throws -> T { try decoder.decode(T.self, from: Data(json.utf8)) }
        #expect(try decode("\"pinned\"", as: StopStatus.self) == .pinned)
        #expect(try decode("\"somethingNew\"", as: StopStatus.self) == .open)
        #expect(try decode("\"noAnswer\"", as: StopClosedReason.self) == .noAnswer)
        #expect(try decode("\"notNow\"", as: StopAnswer.self) == .notNow)
        #expect(StopAnswer.yes.agree)
        #expect(StopAnswer.notNow.agree == false)
    }

    @Test func noAnswerAfterTenMinutesWithoutAPin() {
        let asked = request("a")
        let nine = t0.addingTimeInterval(9 * 60 + 59)
        let ten = t0.addingTimeInterval(10 * 60)
        #expect(!StopLogic.isNoAnswer(asked, now: nine))
        #expect(StopLogic.openStops(in: [asked], now: nine).count == 1)
        #expect(StopLogic.isNoAnswer(asked, now: ten))
        #expect(StopLogic.openStops(in: [asked], now: ten).isEmpty)
        #expect(StopLogic.noAnswerToClose(in: [asked], now: ten).map(\.id) == ["a"])
        // A pinned request never counts as no answer, however old.
        let pinned = request("p", place: place(pinned: "u1"), status: .pinned)
        #expect(!StopLogic.isNoAnswer(pinned, now: ten.addingTimeInterval(3_600)))
        #expect(StopLogic.noAnswerToClose(in: [pinned], now: ten.addingTimeInterval(3_600)).isEmpty)
        // Old builds pinned with the place only.
        #expect(!StopLogic.isNoAnswer(request("q", place: place(pinned: "u1")), now: ten))
    }

    @Test func theAskerSeesNoAnswerAndCanAskAgain() {
        let asked = request("a", by: "c1", author: "u1")
        let ten = t0.addingTimeInterval(10 * 60)
        #expect(StopLogic.missedAsk(in: [asked], myCarId: "c1", now: ten)?.id == "a")
        // Someone else's request is not mine to ask again.
        #expect(StopLogic.missedAsk(in: [asked], myCarId: "c2", now: ten) == nil)
        // Closed as no answer by the lead's phone: still shown for a while.
        let closed = request("a", by: "c1", author: "u1", status: .closed, closedReason: .noAnswer, expires: ten)
        #expect(StopLogic.missedAsk(in: [closed], myCarId: "c1", now: ten.addingTimeInterval(60))?.id == "a")
        #expect(StopLogic.missedAsk(in: [closed], myCarId: "c1", now: t0.addingTimeInterval(21 * 60)) == nil)
        // Asked again: the newer request replaces it.
        let again = request("b", by: "c1", author: "u1", at: 11 * 60)
        #expect(StopLogic.missedAsk(in: [closed, again], myCarId: "c1", now: ten.addingTimeInterval(120)) == nil)
        // Cancelled on purpose is not "no answer".
        let cancelled = request("c", by: "c1", author: "u1", status: .closed, closedReason: .cancelled, expires: t0)
        #expect(StopLogic.missedAsk(in: [cancelled], myCarId: "c1", now: ten) == nil)
    }

    @Test func leadPhoneOnlyIsWhoClosesNoAnswer() {
        #expect(StopLogic.isLeadTracker(cars: cars, myCarId: "c1", myUserId: "u1"))
        #expect(!StopLogic.isLeadTracker(cars: cars, myCarId: "c2", myUserId: "u2"))
        #expect(!StopLogic.isLeadTracker(cars: cars, myCarId: "c1", myUserId: "u9"))
    }

    // MARK: Answers and rows

    @Test func answersCountAndOldVotesStillCount() throws {
        func answered(_ car: String, _ answer: StopAnswer?, agree: Bool) -> StopVote {
            StopVote(id: car, userId: "u-\(car)", agree: agree, answer: answer, at: t0, suggestion: nil)
        }
        let state = try tally(stop(), votes: [
            answered("c1", .yes, agree: true), answered("c3", .notNow, agree: false), answered("c4", nil, agree: true),
        ])
        #expect(state.rows.map(\.status) == [.agreed, .agreed, .notNow, .agreed])
        #expect(state.myAnswer == .yes)
        // An old build's "no" with no answer and no place still reads as waiting.
        let old = try tally(stop(), votes: [answered("c3", nil, agree: false)])
        #expect(old.rows.first { $0.carId == "c3" }?.status == .waiting)
        #expect(try tally(stop()).myAnswer == nil)
    }

    @Test func requesterCarCountsAsYes() throws {
        let state = try tally(stop(), me: "c2", user: "u2")
        #expect(state.agreedCount == 1)
        #expect(state.rows.first { $0.carId == "c2" }?.status == .agreed)
        #expect(StopLogic.viewerIsRequester(state))
        #expect(!StopLogic.needsAnswer(state))
    }

    @Test func aRequestNeedsMyAnswerUntilIAnswerOrItIsPinned() throws {
        let open = try tally(stop(), me: "c3", user: "u3")
        #expect(StopLogic.needsAnswer(open))
        let said = try tally(stop(), votes: [vote("c3", agree: true)], me: "c3", user: "u3")
        #expect(!StopLogic.needsAnswer(said))
        let pinned = try tally(stop(place: place(pinned: "u1")), me: "c3", user: "u3")
        #expect(!StopLogic.needsAnswer(pinned))
        // The lead answers by pinning, so a vote does not clear its question.
        let lead = try tally(stop(), votes: [vote("c1", agree: true)], me: "c1", user: "u1")
        #expect(StopLogic.needsAnswer(lead))
    }

    @Test func carsAreHereWithin150MetersOrMinutesAway() throws {
        let spot = place("R&R", offset: 18_000, pinned: "u1")
        func fix(meters: Double, offset: Double?) -> StopCarFix {
            // About 111,195 m per degree of latitude.
            StopCarFix(latitude: 3 + meters / 111_195, longitude: 101, offset: offset)
        }
        #expect(StopLogic.arrival(of: fix(meters: 120, offset: 17_900), to: spot) == .here)
        #expect(StopLogic.arrival(of: fix(meters: 200, offset: 17_800), to: spot) == .minutes(1))
        // 15 km along the route at 25 m/s is 10 minutes, ahead or behind.
        #expect(StopLogic.arrival(of: fix(meters: 15_000, offset: 3_000), to: spot) == .minutes(10))
        #expect(StopLogic.arrival(of: fix(meters: 15_000, offset: 33_000), to: spot) == .minutes(10))
        // No route offset: the straight line.
        #expect(StopLogic.arrival(of: fix(meters: 15_000, offset: nil), to: spot) == .minutes(10))
    }

    @Test func rowsCarryArrivalOncePinned() throws {
        let fixes: [String: StopCarFix] = [
            "c1": StopCarFix(latitude: 3 + 18_000 / 111_195.0, longitude: 101, offset: 17_950),
            "c3": StopCarFix(latitude: 3 + 3_000 / 111_195.0, longitude: 101, offset: 3_000),
        ]
        let place = StopPlace(
            name: "R&R", coordinate: GeoPoint(latitude: 3 + 18_000 / 111_195.0, longitude: 101), routeOffset: 18_000,
            pinnedBy: "u1")
        let pinned = try #require(StopLogic.tally(
            event: stop(place: place), votes: [], cars: cars, myUserId: "u1", myCarId: "c1", isOrganizer: false,
            viewerOffset: 17_950, now: t0.addingTimeInterval(60), fixes: fixes))
        #expect(pinned.rows.first { $0.carId == "c1" }?.arrival == .here)
        #expect(pinned.rows.first { $0.carId == "c3" }?.arrival == .minutes(10))
        #expect(pinned.rows.first { $0.carId == "c4" }?.arrival == nil)
        #expect(pinned.hereCount == 1)
        #expect(pinned.viewerIsHere)
        // Before a pin nobody is "here".
        let open = try tally(stop())
        #expect(open.rows.allSatisfy { $0.arrival == nil })
    }

    // MARK: Button, badge and pill text

    private func board(_ states: [StopRequestState], missed: StopRequestState? = nil) -> StopBoard {
        StopBoard(requests: states, missed: missed)
    }

    @Test func buttonSaysPitStopWithNoStop() {
        let content = StopLogic.buttonContent(for: .empty)
        #expect(content.label == "Pit stop")
        #expect(content.symbol == "mappin.and.ellipse")
        #expect(content.badge == 0)
    }

    @Test func buttonShowsTheOpenStopAndBadge() throws {
        let deciding = try tally(stop(), votes: [vote("c3", agree: true)], me: "c4", user: "u4")
        let content = StopLogic.buttonContent(for: board([deciding]))
        #expect(content.label == "Fuel · 2 of 4")
        #expect(content.symbol == "fuelpump.fill")
        #expect(content.badge == 1)
        #expect(content.accessibilityLabel == "Fuel stop, 2 of 4 cars agreed, you have not answered")
        // Answered: the badge clears.
        let answered = try tally(stop(), votes: [vote("c3", agree: true), vote("c4", agree: true)], me: "c4", user: "u4")
        let after = StopLogic.buttonContent(for: board([answered]))
        #expect(after.label == "Fuel · 3 of 4")
        #expect(after.badge == 0)
        #expect(after.accessibilityLabel == "Fuel stop, 3 of 4 cars agreed")
    }

    @Test func buttonShowsMinutesOncePinnedAndHereAtTheStop() throws {
        let spot = place("R&R", offset: 18_000, pinned: "u1")
        let heading = try tally(stop(place: spot), me: "c3", user: "u3", offset: 3_000)
        // 15 km to go at 25 m/s is 10 minutes.
        #expect(StopLogic.buttonContent(for: board([heading])).label == "Fuel · 10 min")
        #expect(StopLogic.buttonContent(for: board([heading])).badge == 0)
        var here = heading
        here.rows = here.rows.map { row in
            var r = row
            if row.carId == "c3" || row.carId == "c1" { r.arrival = .here } else { r.arrival = .minutes(3) }
            return r
        }
        let content = StopLogic.buttonContent(for: board([here]))
        #expect(content.label == "Fuel · 2 of 4 here")
        #expect(content.accessibilityLabel == "Fuel stop, 2 of 4 cars here")
    }

    @Test func twoOpenRequestsReadTwoStops() throws {
        var other = request("two", by: "c4", author: "u4", at: 5, type: .stopFood)
        other.id = "two"
        let a = try tally(request("one"), me: "c3", user: "u3")
        let b = try #require(StopLogic.tally(
            event: other, votes: [], cars: cars, myUserId: "u3", myCarId: "c3", isOrganizer: false, viewerOffset: 0,
            now: t0.addingTimeInterval(60)))
        let content = StopLogic.buttonContent(for: board([a, b]))
        #expect(content.label == "2 stops")
        #expect(content.badge == 2)
        #expect(content.accessibilityLabel == "2 stops open, you have 2 to answer")
    }

    @Test func buttonSaysNoAnswerForMyIgnoredRequest() throws {
        let missed = try tally(request("m", by: "c1", author: "u1"), me: "c1", user: "u1")
        let content = StopLogic.buttonContent(for: board([], missed: missed))
        #expect(content.label == "Fuel · No answer")
        #expect(content.badge == 0)
    }

    @Test func reasonLabelsAndTexts() throws {
        #expect(StopLogic.reasonLabel(.stopFood) == "Food")
        #expect(StopLogic.reasonLabel(.stopToilet) == "Toilet")
        #expect(StopLogic.reasonLabel(.stopRest) == "Rest")
        let state = try tally(stop(place: place("Petronas R&R Tapah", offset: 18_000, pinned: "u1")), offset: 0)
        #expect(StopLogic.placeLine(state) == "Petronas R&R Tapah · 18 km · 12 min")
        let asker = try tally(stop(), votes: [vote("c3", agree: true)], me: "c2", user: "u2")
        #expect(StopLogic.decidingText(asker) == "Hafiz agreed. Waiting for Aqlan’s Myvi and Daniel’s City")
        #expect(StopLogic.joined(["Ali", "Sara", "Daniel"]) == "Ali, Sara and Daniel")
    }

    @Test func theLeadsLineToTheAsker() throws {
        let state = try #require(StopLogic.tally(
            event: stop(), votes: [], cars: cars, myUserId: "u1", myCarId: "c1", isOrganizer: false, viewerOffset: 0,
            now: t0.addingTimeInterval(60), fixes: ["c2": StopCarFix(latitude: 3, longitude: 101, offset: 20_000)]))
        let back = StopLogic.chosenLine(leadName: "Aisha", place: place("Petronas Bidor", offset: 8_000), state: state)
        #expect(back == "Aisha chose Petronas Bidor. 8 min back.")
        let ahead = StopLogic.chosenLine(leadName: "Aisha", place: place("Shell Gopeng", offset: 26_000), state: state)
        #expect(ahead == "Aisha chose Shell Gopeng. 4 min ahead.")
        #expect(StopLogic.chosenLine(leadName: "Aisha", place: place("X"), state: try tally(stop())) == "Aisha chose X.")
    }

    @Test func voterLabelsAndTitles() throws {
        let state = try tally(stop(place: place("R&R Demo", pinned: "u1")), votes: [vote("c1", agree: true), vote("c3", agree: true)])
        #expect(state.rows.map(StopLogic.shortName) == ["Me", "Wyna", "Hafiz", "Daniel"])
        #expect(StopLogic.voterAccessibilityLabel(state.rows[2]) == "Hafiz’s Hilux, agreed")
        #expect(StopLogic.voterAccessibilityLabel(state.rows[3]) == "Daniel’s City, waiting")
        #expect(StopLogic.voterAccessibilityLabel(state.rows[0]) == "Aqlan’s Myvi, you, agreed")
    }

    // MARK: The pill

    @Test func pillOffersTheOldestUnansweredRequestFirst() throws {
        let first = try tally(request("one", at: 0), me: "c3", user: "u3")
        let second = try #require(StopLogic.tally(
            event: request("two", by: "c4", author: "u4", at: 5, type: .stopFood), votes: [], cars: cars, myUserId: "u3",
            myCarId: "c3", isOrganizer: false, viewerOffset: 0, now: t0.addingTimeInterval(60)))
        var memory = StopPillMemory()
        memory.observe([first, second], now: t0)
        guard case .question(let id, _, let title, _, let button, let isPin)? =
            StopPillPlanner.current(requests: [first, second], memory: memory, now: t0.addingTimeInterval(1)) else {
            Issue.record("expected a question"); return
        }
        #expect(id == "one")
        #expect(title == "Wyna needs fuel")
        #expect(button == "Yes")
        #expect(!isPin)
        // Once the first is answered the second is offered.
        let answered = try tally(request("one", at: 0), votes: [vote("c3", agree: true)], me: "c3", user: "u3")
        guard case .question(let next, _, _, _, _, _)? =
            StopPillPlanner.current(requests: [answered, second], memory: memory, now: t0.addingTimeInterval(2)) else {
            Issue.record("expected the second question"); return
        }
        #expect(next == "two")
    }

    @Test func pillGoesQuietAfterTwentySeconds() throws {
        let state = try tally(stop(), me: "c3", user: "u3")
        var memory = StopPillMemory()
        memory.observe([state], now: t0)
        #expect(StopPillPlanner.current(requests: [state], memory: memory, now: t0.addingTimeInterval(19)) != nil)
        #expect(StopPillPlanner.current(requests: [state], memory: memory, now: t0.addingTimeInterval(20)) == nil)
        #expect(StopPillPlanner.nextChange(requests: [state], memory: memory, now: t0.addingTimeInterval(1)) == t0.addingTimeInterval(20))
        // The badge stays: the request still needs this car's answer.
        #expect(StopLogic.buttonContent(for: board([state])).badge == 1)
    }

    @Test func pillForTheLeadHasPinThisStop() throws {
        let state = try tally(stop(), me: "c1", user: "u1")
        var memory = StopPillMemory()
        memory.observe([state], now: t0)
        guard case .question(_, _, _, _, let button, let isPin)? =
            StopPillPlanner.current(requests: [state], memory: memory, now: t0) else {
            Issue.record("expected a question"); return
        }
        #expect(button == "Pin this stop")
        #expect(isPin)
    }

    @Test func tapConfirmsForFiveSeconds() throws {
        let state = try tally(stop(), votes: [vote("c1", agree: true), vote("c3", agree: true)], me: "c3", user: "u3")
        var memory = StopPillMemory()
        let before = try tally(stop(), votes: [vote("c1", agree: true)], me: "c3", user: "u3")
        memory.observe([before], now: t0)
        memory.noteAnswered(before, answer: .yes, now: t0.addingTimeInterval(3))
        guard case .confirm(_, let title, let detail)? =
            StopPillPlanner.current(requests: [state], memory: memory, now: t0.addingTimeInterval(4)) else {
            Issue.record("expected a confirmation"); return
        }
        #expect(title == "You said yes")
        // Wyna's car, Aqlan's and mine: 3 of 4.
        #expect(detail == "3 of 4 agreed")
        #expect(StopPillPlanner.current(requests: [state], memory: memory, now: t0.addingTimeInterval(8)) == nil)
    }

    @Test func pinnedPillSaysWhereAndHowLong() throws {
        var memory = StopPillMemory()
        let before = try tally(stop(), me: "c3", user: "u3", offset: 3_000)
        memory.observe([before], now: t0)
        let spot = place("Petronas R&R Tapah", offset: 18_000, pinned: "u1")
        let pinned = try tally(stop(place: spot), me: "c3", user: "u3", offset: 3_000)
        memory.observe([pinned], now: t0.addingTimeInterval(30))
        guard case .pinned(_, let title, let detail)? =
            StopPillPlanner.current(requests: [pinned], memory: memory, now: t0.addingTimeInterval(31)) else {
            Issue.record("expected the pinned pill"); return
        }
        #expect(title == "Stop in 10 min")
        #expect(detail == "Petronas R&R Tapah · pinned by Aqlan")
        // It folds into the button's label after a few seconds.
        #expect(StopPillPlanner.current(requests: [pinned], memory: memory, now: t0.addingTimeInterval(40)) == nil)
    }

    @Test func theAskerGetsAConfirmationNeverAQuestion() throws {
        let mine = try tally(request("m", by: "c1", author: "u1", at: 0), me: "c1", user: "u1")
        var memory = StopPillMemory()
        memory.observe([mine], now: t0.addingTimeInterval(1))
        guard case .asked(let title, let detail)? =
            StopPillPlanner.current(requests: [mine], memory: memory, now: t0.addingTimeInterval(2)) else {
            Issue.record("expected the asked pill"); return
        }
        #expect(title == "Asked the convoy")
        #expect(detail == "Waiting for 3 cars")
        #expect(StopPillPlanner.current(requests: [mine], memory: memory, now: t0.addingTimeInterval(10)) == nil)
        // An old request of mine that was already open is not announced again.
        var late = StopPillMemory()
        late.observe([mine], now: t0.addingTimeInterval(120))
        #expect(StopPillPlanner.current(requests: [mine], memory: late, now: t0.addingTimeInterval(121)) == nil)
    }

    // MARK: Driving and the passenger answer

    @Test func drivingNeedsTenSecondsAbove15KmH() {
        var detector = DrivingDetector()
        let fast = 20 / 3.6
        detector.feed(speed: fast, at: t0)
        #expect(!detector.isDriving)
        detector.feed(speed: fast, at: t0.addingTimeInterval(9))
        #expect(!detector.isDriving)
        detector.feed(speed: fast, at: t0.addingTimeInterval(10))
        #expect(detector.isDriving)
        // A dip shorter than ten seconds does not unlock it.
        detector.feed(speed: 5 / 3.6, at: t0.addingTimeInterval(11))
        detector.feed(speed: fast, at: t0.addingTimeInterval(15))
        detector.feed(speed: 5 / 3.6, at: t0.addingTimeInterval(16))
        detector.feed(speed: 5 / 3.6, at: t0.addingTimeInterval(25))
        #expect(detector.isDriving)
        detector.feed(speed: 5 / 3.6, at: t0.addingTimeInterval(26))
        #expect(!detector.isDriving)
    }

    @Test func aShortBurstOrAnUnknownSpeedNeverCountsAsDriving() {
        var detector = DrivingDetector()
        detector.feed(speed: 30 / 3.6, at: t0)
        detector.feed(speed: 2, at: t0.addingTimeInterval(5))
        detector.feed(speed: 30 / 3.6, at: t0.addingTimeInterval(8))
        detector.feed(speed: nil, at: t0.addingTimeInterval(30))
        detector.feed(speed: -1, at: t0.addingTimeInterval(31))
        #expect(!detector.isDriving)
        #expect(abs(DrivingDetector.speed - 4.1667) < 0.001)
    }

    @Test func passengerAnswerLastsUntilTheCardCloses() {
        var session = StopCardSession()
        #expect(StopCardGate.mode(driving: true, session: session, hasOpenStop: true) == .readOnly)
        #expect(StopCardGate.mode(driving: true, session: session, hasOpenStop: false) == .driverAsk)
        #expect(StopCardGate.needsPassengerCheck(driving: true, session: session))
        session.confirmPassenger()
        #expect(StopCardGate.mode(driving: true, session: session, hasOpenStop: true) == .full)
        #expect(!StopCardGate.needsPassengerCheck(driving: true, session: session))
        session.close()
        #expect(StopCardGate.needsPassengerCheck(driving: true, session: session))
        // "I'm driving" keeps the default place and remembers nothing.
        session.confirmPassenger()
        session.confirmDriving()
        #expect(StopCardGate.mode(driving: true, session: session, hasOpenStop: false) == .driverAsk)
    }

    @Test func nothingIsLockedWhileParked() {
        let session = StopCardSession()
        #expect(StopCardGate.mode(driving: false, session: session, hasOpenStop: true) == .full)
        #expect(StopCardGate.mode(driving: false, session: session, hasOpenStop: false) == .full)
        #expect(!StopCardGate.needsPassengerCheck(driving: false, session: session))
    }
}

// MARK: The ask confirm map

struct StopMapFramingTests {
    private let route = RouteLine((0...60).map { CLLocationCoordinate2D(latitude: 3, longitude: 101 + Double($0) * 0.009) })

    @Test func regionFitsBothPointsWithRoomAround() {
        let a = CLLocationCoordinate2D(latitude: 3, longitude: 101)
        let b = CLLocationCoordinate2D(latitude: 3.02, longitude: 101.18)
        let region = StopMapFraming.region(a, b)
        #expect(abs(region.center.longitude - 101.09) < 1e-9)
        #expect(region.span.longitudeDelta >= 0.18 * 1.5 - 1e-9)
        #expect(region.span.latitudeDelta >= 0.008)
        // Two points on top of each other still get a street-level frame.
        #expect(StopMapFraming.region(a, a).span.latitudeDelta == 0.008)
    }

    @Test func routeBetweenIsSampledAndEndsAtThePlace() {
        let points = StopMapFraming.routeBetween(route, from: 1_000, to: 5_000)
        #expect(points.count == 9)
        #expect(StopMapFraming.routeBetween(route, from: 5_000, to: 1_000).isEmpty)
        #expect(StopMapFraming.routeBetween(nil, from: 0, to: 1_000).isEmpty)
    }
}

// MARK: Suggestions

struct StopSuggestionTests {
    /// A straight east-west route from (3, 101), about 111 m per 0.001 deg, 60 km long.
    private let route = RouteLine((0...60).map { CLLocationCoordinate2D(latitude: 3, longitude: 101 + Double($0) * 0.009) })

    private func at(km: Double, offRouteMeters: Double = 0) -> CLLocationCoordinate2D {
        route.coordinate(atOffset: km * 1000).map {
            CLLocationCoordinate2D(latitude: $0.latitude + offRouteMeters / 111_195, longitude: $0.longitude)
        }!
    }

    private func found(_ name: String, km: Double, off: Double = 0) -> FoundPlace {
        FoundPlace(name: name, coordinate: at(km: km, offRouteMeters: off))
    }

    @Test func rankSortsByDistanceAlongRoute() {
        let ranked = StopSuggestions.rank(
            [found("C", km: 24), found("A", km: 12), found("B", km: 18)], route: route, fromOffset: 0)
        #expect(ranked.map(\.name) == ["A", "B", "C"])
        #expect(abs(ranked[1].distanceAhead - 18_000) < 50)
        #expect(abs(ranked[1].routeOffset - 18_000) < 50)
    }

    @Test func rankMeasuresFromTheViewer() {
        let ranked = StopSuggestions.rank([found("A", km: 30)], route: route, fromOffset: 10_000)
        #expect(abs(ranked[0].distanceAhead - 20_000) < 50)
    }

    @Test func rankDropsPlacesBehindOrTooFarOffRoute() {
        let ranked = StopSuggestions.rank(
            [found("behind", km: 5), found("here", km: 10.2), found("far", km: 20, off: 5_000), found("ok", km: 20, off: 800)],
            route: route, fromOffset: 10_000)
        #expect(ranked.map(\.name) == ["ok"])
        #expect(abs(ranked[0].offRoute - 800) < 20)
    }

    @Test func rankCollapsesDuplicatesAndLimits() {
        let dupes = [found("Petronas", km: 15), found("Petronas", km: 15.05), found("Shell", km: 16)]
        #expect(StopSuggestions.rank(dupes, route: route, fromOffset: 0).map(\.name) == ["Petronas", "Shell"])
        let many = (1...9).map { found("P\($0)", km: Double($0) * 3) }
        #expect(StopSuggestions.rank(many, route: route, fromOffset: 0, limit: 3).count == 3)
    }

    @Test func rankOnEmptyRoute() {
        #expect(StopSuggestions.rank([found("A", km: 12)], route: RouteLine([]), fromOffset: 0).isEmpty)
    }

    @Test func candidateText() {
        let onRoute = StopSuggestions.rank([found("A", km: 18)], route: route, fromOffset: 0)[0]
        #expect(onRoute.costText == "On route")
        #expect(onRoute.whereText == "18 km ahead · about 12 min")
        let off = StopSuggestions.rank([found("B", km: 18, off: 1_500)], route: route, fromOffset: 0)[0]
        #expect(off.costText == "+4 min")
        #expect(off.whereText.hasSuffix("off route"))
    }

    @Test func queriesPerType() {
        #expect(StopSuggestions.queries(for: .stopFuel).contains("petrol station"))
        #expect(StopSuggestions.queries(for: .stopFood) == ["restaurant"])
        #expect(StopSuggestions.queries(for: .stopRest).contains("R&R"))
        #expect(StopSuggestions.queries(for: .stopToilet) == StopSuggestions.queries(for: .stopRest))
    }

    @Test func searchCenterIsTwentyKmAhead() throws {
        let center = try #require(StopSuggestions.searchCenter(on: route, from: 5_000))
        let expected = try #require(route.coordinate(atOffset: 25_000))
        #expect(RouteLine.haversine(center, expected) < 1)
        // Near the end it clamps to the route's end.
        let end = try #require(StopSuggestions.searchCenter(on: route, from: route.length - 1_000))
        #expect(RouteLine.haversine(end, route.coordinates.last!) < 1)
    }

    @Test func suggestSearchesEachQueryAndRanks() async throws {
        let searcher = FakeSearcher(results: [found("A", km: 14), found("B", km: 22)])
        let list = try await StopSuggestions.suggest(type: .stopRest, route: route, fromOffset: 0, searcher: searcher)
        #expect(list.map(\.name) == ["A", "B"])
        #expect(await searcher.queries == ["R&R", "rest area"])
        let center = try #require(await searcher.centers.first)
        #expect(RouteLine.haversine(center, try #require(route.coordinate(atOffset: 20_000))) < 1)
    }

    @Test func suggestToleratesOneFailingQueryButNotAll() async throws {
        let partial = FakeSearcher(results: [found("A", km: 14)], failOn: ["petrol station"])
        let list = try await StopSuggestions.suggest(type: .stopFuel, route: route, fromOffset: 0, searcher: partial)
        #expect(list.map(\.name) == ["A"])
        let broken = FakeSearcher(results: [], failOn: ["petrol station", "gas station"])
        await #expect(throws: (any Error).self) {
            try await StopSuggestions.suggest(type: .stopFuel, route: route, fromOffset: 0, searcher: broken)
        }
    }
}

private actor FakeSearcherState {
    var queries: [String] = []
    var centers: [CLLocationCoordinate2D] = []
    func record(_ q: String, _ c: CLLocationCoordinate2D) { queries.append(q); centers.append(c) }
}

private struct FakeSearcher: PlaceSearching {
    var results: [FoundPlace]
    var failOn: Set<String> = []
    private let state = FakeSearcherState()
    var queries: [String] { get async { await state.queries } }
    var centers: [CLLocationCoordinate2D] { get async { await state.centers } }

    init(results: [FoundPlace], failOn: Set<String> = []) {
        self.results = results
        self.failOn = failOn
    }

    func search(query: String, near center: CLLocationCoordinate2D, radius: CLLocationDistance) async throws -> [FoundPlace] {
        await state.record(query, center)
        if failOn.contains(query) { throw URLError(.notConnectedToInternet) }
        return results
    }
}

// MARK: Emulator

/// Runs against the local Auth, Functions and Firestore emulators. Start them first, then:
/// `TEST_RUNNER_IKUT_EMULATOR_TESTS=1 xcodebuild test ...`
@Suite(.emulator, .serialized)
@MainActor
struct StopEmulatorTests {
    init() throws {
        Backend.configure()
        try Auth.auth().signOut()
    }

    private let service = StopService()
    private let route = RouteLine((0...60).map { CLLocationCoordinate2D(latitude: 3, longitude: 101 + Double($0) * 0.009) })

    private func makeTrip() async throws -> (tripId: String, carId: String, uid: String, code: String) {
        let trip = try await EmulatorTrip.make(
            name: "Stops",
            destination: DestinationResult(name: "Ipoh", subtitle: "", coordinate: .init(latitude: 3, longitude: 101.5)))
        return (trip.tripId, trip.carId, trip.uid, try await trip.code())
    }

    private func context(_ tripId: String, uid: String, carId: String, organizer: Bool) -> StopContext {
        StopContext(
            tripId: tripId, userId: uid, carId: carId, isOrganizer: organizer,
            snapshot: {
                ReportSnapshot(
                    coordinate: .init(latitude: 3, longitude: 101.01), heading: 90, route: nil,
                    previousOffset: nil, capturedAt: Date())
            },
            mainRoute: route)
    }

    private func place(_ name: String, km: Double) -> StopPlace {
        let c = route.coordinate(atOffset: km * 1000)!
        return StopPlace(name: name, coordinate: GeoPoint(latitude: c.latitude, longitude: c.longitude), routeOffset: km * 1000, pinnedBy: nil)
    }

    /// First board from `stream` that satisfies `predicate`, or nil after `seconds`.
    private func next(
        _ stream: AsyncStream<StopBoard>, seconds: Double = 10, where predicate: @escaping @Sendable (StopBoard) -> Bool
    ) async -> StopBoard? {
        await withTaskGroup(of: StopBoard?.self) { group in
            group.addTask {
                for await board in stream where predicate(board) { return board }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The first open request from `stream` that satisfies `predicate`.
    private func state(
        _ stream: AsyncStream<StopBoard>, where predicate: @escaping @Sendable (StopRequestState) -> Bool
    ) async throws -> StopRequestState {
        let found = await next(stream) { $0.requests.contains(where: predicate) }
        return try #require(found?.requests.first(where: predicate), "no matching state arrived")
    }

    /// Organizer (lead car) asks, votes, pins a place, then closes; the listener sees each step.
    @Test func leadRequestsVotesPinsAndCloses() async throws {
        let trip = try await makeTrip()
        let ctx = context(trip.tripId, uid: trip.uid, carId: trip.carId, organizer: true)
        let stream = StopService.listen(context: ctx, refresh: .seconds(60))

        let eventId = try await service.request(
            type: .stopFuel, place: place("Petronas Tapah", km: 18), context: ctx, snapshot: try #require(ctx.snapshot()))
        let asked = try await state(stream) { $0.proposal != nil }
        #expect(asked.eventId == eventId)
        #expect(asked.proposal?.name == "Petronas Tapah")
        #expect(asked.place == nil)
        #expect(asked.canPin)
        #expect(asked.title == "Aqlan needs fuel")
        #expect(asked.myAnswer == .yes)

        try await service.vote(tripId: trip.tripId, eventId: eventId, carId: trip.carId, userId: trip.uid, answer: .yes)
        try await service.pin(tripId: trip.tripId, eventId: eventId, place: place("Petronas Tapah", km: 18), userId: trip.uid)
        let pinned = try await state(stream) { $0.place != nil }
        #expect(pinned.place?.name == "Petronas Tapah")
        #expect(pinned.place?.pinnedBy == trip.uid)
        #expect(pinned.distanceText != nil)
        let pinnedDoc = try await Firestore.firestore().document(FirestorePaths.event(tripId: trip.tripId, eventId: eventId))
            .getDocument(as: TripEvent.self)
        #expect(pinnedDoc.status == .pinned)

        try await service.close(tripId: trip.tripId, eventId: eventId, reason: .left, userId: trip.uid, now: Date().addingTimeInterval(-1))
        let closed = await next(stream) { $0.requests.isEmpty }
        #expect(closed != nil, "expected the listener to report no open stop")
        let closedDoc = try await Firestore.firestore().document(FirestorePaths.event(tripId: trip.tripId, eventId: eventId))
            .getDocument(as: TripEvent.self)
        #expect(closedDoc.status == .closed)
        #expect(closedDoc.closedReason == .left)
        #expect(closedDoc.closedBy == trip.uid)
        #expect(closedDoc.expiresAt != nil)
    }

    /// A joined car answers and is tallied; it cannot pin (rejected by the rules) or close someone
    /// else's request, and the pin is not applied.
    @Test func memberVotesButCannotPinOrClose() async throws {
        let trip = try await makeTrip()
        let orgContext = context(trip.tripId, uid: trip.uid, carId: trip.carId, organizer: true)
        let eventId = try await service.request(
            type: .stopFood, place: nil, context: orgContext, snapshot: try #require(orgContext.snapshot()))

        try Auth.auth().signOut()
        try await Auth.auth().signInAnonymously()
        let joiner = try #require(Auth.auth().currentUser?.uid)
        let joined = try await LiveJoinAPI().join(
            code: trip.code, displayName: "Wyna", car: .new(name: "Wyna's X70", color: TripService.palette[1]), tracker: true)
        let ctx = context(trip.tripId, uid: joiner, carId: joined.carId, organizer: false)
        let stream = StopService.listen(context: ctx, refresh: .seconds(60))

        let before = try await state(stream) { $0.rows.count == 2 }
        #expect(before.canPin == false)
        #expect(before.canResolve == false)
        #expect(before.viewerAgrees == false)

        try await service.vote(tripId: trip.tripId, eventId: eventId, carId: joined.carId, userId: joiner, answer: .yes)
        let voted = try await state(stream) { $0.viewerAgrees }
        #expect(voted.agreedCount == 2)

        try await service.vote(tripId: trip.tripId, eventId: eventId, carId: joined.carId, userId: joiner, answer: .notNow)
        let declined = try await state(stream) { $0.myAnswer == .notNow }
        #expect(declined.rows.first { $0.isMine }?.status == .notNow)

        try await service.suggest(place: place("Other R&R", km: 26), eventId: eventId, canPin: false, context: ctx)
        let suggested = try await state(stream) { $0.alternatives.count == 1 }
        #expect(suggested.rows.first { $0.isMine }?.status == .suggested)

        await #expect(throws: (any Error).self) {
            try await service.pin(tripId: trip.tripId, eventId: eventId, place: place("Hax", km: 5), userId: joiner)
        }
        await #expect(throws: (any Error).self) {
            try await service.close(tripId: trip.tripId, eventId: eventId, reason: .left, userId: joiner)
        }
        // Voting for the organizer's car is also rejected.
        await #expect(throws: (any Error).self) {
            try await service.vote(tripId: trip.tripId, eventId: eventId, carId: trip.carId, userId: joiner, answer: .yes)
        }
        let doc = try await Firestore.firestore().document(FirestorePaths.event(tripId: trip.tripId, eventId: eventId))
            .getDocument(as: TripEvent.self)
        #expect(doc.place == nil)
        #expect(doc.expiresAt == nil)
        #expect(doc.status == nil)
    }

    /// The asker cancels their own request; nobody else's.
    @Test func askerCancelsOwnRequest() async throws {
        let trip = try await makeTrip()
        let ctx = context(trip.tripId, uid: trip.uid, carId: trip.carId, organizer: false)
        let eventId = try await service.request(
            type: .stopToilet, place: nil, context: ctx, snapshot: try #require(ctx.snapshot()))
        try await service.close(tripId: trip.tripId, eventId: eventId, reason: .cancelled, userId: trip.uid)
        let doc = try await Firestore.firestore().document(FirestorePaths.event(tripId: trip.tripId, eventId: eventId))
            .getDocument(as: TripEvent.self)
        #expect(doc.status == .closed)
        #expect(doc.closedReason == .cancelled)
        #expect(doc.expiresAt != nil)
    }
}
