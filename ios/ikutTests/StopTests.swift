import CoreLocation
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

// MARK: Pure logic

struct StopLogicTests {
    private let t0 = Fixtures.t0

    private func car(_ id: String, _ number: Int?, _ name: String, tracker: String? = nil, lead: Bool = false) -> Car {
        Car.fixture(id, name: name, number: number, lead: lead, tracker: tracker)
    }

    private func stop(
        by carId: String = "c2", author: String = "u2", expires: Date? = nil, message: String? = nil
    ) -> TripEvent {
        var e = TripEvent(
            type: .stopFuel, location: GeoPoint(latitude: 3, longitude: 101), heading: 0, routeOffset: 0,
            authorId: author, carId: carId, createdAt: t0, message: message)
        e.id = "stop1"
        if let expires { e.expiresAt = expires }
        return e
    }

    private func ok(_ carId: String) -> StopVote { StopVote(id: carId, userId: "u-\(carId)", at: t0) }

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
        _ event: TripEvent, votes: [StopVote] = [], me: String = "c1", user: String = "u1", organizer: Bool = false
    ) throws -> StopRequestState {
        try #require(StopLogic.tally(
            event: event, votes: votes, cars: cars, myUserId: user, myCarId: me, isOrganizer: organizer))
    }

    private func board(_ states: [StopRequestState]) -> StopBoard { StopBoard(requests: states) }

    // MARK: Rows and the count

    @Test func rowsAreOrderedByNumberAndSkipUntrackedCars() throws {
        let state = try tally(stop())
        #expect(state.rows.map(\.carId) == ["c1", "c2", "c3", "c4"])
        #expect(state.rows.first { $0.isMine }?.name == "Aqlan’s Myvi (you)")
    }

    @Test func theAskingCarCountsAsOKAndOthersWait() throws {
        let state = try tally(stop())
        #expect(state.rows.map(\.status) == [.waiting, .ok, .waiting, .waiting])
        #expect(state.okCount == 1)
        #expect(state.viewerCarIsOK == false)
    }

    @Test func eachCarsOKIsCountedOnce() throws {
        // Two phones in car 3 write the same document, so there is one vote and one OK for the car.
        let state = try tally(stop(), votes: [ok("c1"), ok("c3"), ok("c3")])
        #expect(state.rows.map(\.status) == [.ok, .ok, .ok, .waiting])
        #expect(state.okCount == 3)
        #expect(state.viewerCarIsOK)
    }

    @Test func aVoterOnAnUntrackedCarGetsARow() throws {
        let state = try tally(stop(), votes: [ok("c5")])
        #expect(state.rows.map(\.carId).contains("c5"))
    }

    // MARK: Words

    @Test func titleSubtitleAndPillLine() throws {
        let state = try tally(stop())
        #expect(state.title == "Wyna needs fuel")
        #expect(state.subtitle(now: t0.addingTimeInterval(65)) == "Car 2 · asked 1 min ago")
        #expect(state.subtitle(now: t0.addingTimeInterval(5)) == "Car 2 · asked just now")
        // Without a message the pill's line says who and when.
        #expect(state.pillDetail(now: t0.addingTimeInterval(5)) == "Car 2 · just now")
        #expect(state.pillDetail(now: t0.addingTimeInterval(125)) == "Car 2 · 2 min ago")
        #expect(StopLogic.ownerName(fromCarName: "Wyna's car") == "Wyna")
        #expect(StopLogic.ownerName(fromCarName: "Convoy") == "Convoy")
        #expect(StopRequestState.need(for: .stopFood) == "needs food")
        #expect(StopRequestState.need(for: .stopToilet) == "needs a toilet break")
        #expect(StopRequestState.need(for: .stopRest) == "needs a rest")
    }

    @Test func theMessageIsTrimmedCutToOneLineOnThePillAndKeptInFullOnTheState() throws {
        let long = "Low on fuel,\nnext R&R please"
        let state = try tally(stop(message: "  \(long)  "))
        #expect(state.message == long)
        #expect(state.pillDetail(now: t0) == "Low on fuel, next R&R please")
        #expect(try tally(stop(message: "   ")).message == nil)
        #expect(try tally(stop(message: nil)).message == nil)
    }

    @Test func aMessageIsAtMost280CharactersAndEmptyMeansNone() {
        #expect(StopLogic.cleanedMessage(nil) == nil)
        #expect(StopLogic.cleanedMessage("  \n ") == nil)
        #expect(StopLogic.cleanedMessage(" hi ") == "hi")
        #expect(StopLogic.cleanedMessage(String(repeating: "m", count: 400))?.count == 280)
    }

    @Test func reasonLabelsAndTexts() throws {
        #expect(StopLogic.reasonLabel(.stopFood) == "Food")
        #expect(StopLogic.reasonLabel(.stopToilet) == "Toilet")
        #expect(StopLogic.reasonLabel(.stopRest) == "Rest")
        let asker = try tally(stop(), votes: [ok("c3")], me: "c2", user: "u2")
        #expect(StopLogic.statusLine(asker) == "Fuel · 2 of 4 OK")
        #expect(StopLogic.waitingText(asker) == "Waiting for 2 cars")
        #expect(StopLogic.waitingText(try tally(stop(), votes: [ok("c1"), ok("c3"), ok("c4")])) == "Everyone said OK")
    }

    @Test func voterLabels() throws {
        let state = try tally(stop(), votes: [ok("c1"), ok("c3")])
        #expect(state.rows.map(StopLogic.shortName) == ["Me", "Wyna", "Hafiz", "Daniel"])
        #expect(StopLogic.voterAccessibilityLabel(state.rows[2]) == "Hafiz’s Hilux, OK")
        #expect(StopLogic.voterAccessibilityLabel(state.rows[3]) == "Daniel’s City, waiting")
        #expect(StopLogic.voterAccessibilityLabel(state.rows[0]) == "Aqlan’s Myvi, you, OK")
    }

    // MARK: Who may tap We've stopped and Cancel request

    @Test func leadCarTrackerCanMarkStopped() throws {
        let state = try tally(stop(), me: "c1", user: "u1")
        #expect(state.canMarkStopped)
        #expect(state.isAuthor == false)
    }

    @Test func organizerCanMarkStopped() throws {
        #expect(try tally(stop(), me: "c3", user: "u3", organizer: true).canMarkStopped)
    }

    @Test func askerCanMarkStoppedAndCancel() throws {
        let state = try tally(stop(), me: "c2", user: "u2")
        #expect(state.canMarkStopped)
        #expect(state.isAuthor)
    }

    @Test func otherMemberCanDoNeither() throws {
        let state = try tally(stop(), me: "c3", user: "u3")
        #expect(state.canMarkStopped == false)
        #expect(state.isAuthor == false)
    }

    @Test func leadFlagOnSomeoneElsesCarGrantsNothing() throws {
        // u9 shares car c1's lead flag in the viewer's context but doesn't track it.
        #expect(try tally(stop(), me: "c1", user: "u9").canMarkStopped == false)
    }

    @Test func permissionsTruthTable() {
        #expect(StopPermissions.canMarkStopped(isAuthor: false, isLeadTracker: false, isOrganizer: false) == false)
        #expect(StopPermissions.canMarkStopped(isAuthor: true, isLeadTracker: false, isOrganizer: false))
        #expect(StopPermissions.canMarkStopped(isAuthor: false, isLeadTracker: true, isOrganizer: false))
        #expect(StopPermissions.canMarkStopped(isAuthor: false, isLeadTracker: false, isOrganizer: true))
        #expect(StopPermissions.canCancel(isAuthor: true))
        #expect(StopPermissions.canCancel(isAuthor: false) == false)
    }

    // MARK: Open requests

    private func request(
        _ id: String, by carId: String = "c2", author: String = "u2", at offset: TimeInterval = 0,
        status: StopStatus? = nil, closedReason: StopClosedReason? = nil, expires: Date? = nil,
        type: EventType = .stopFuel
    ) -> TripEvent {
        var e = stop(by: carId, author: author)
        e.id = id
        e.type = type
        e.createdAt = t0.addingTimeInterval(offset)
        e.expiresAt = expires ?? e.createdAt?.addingTimeInterval(StopLogic.lifetime)
        e.status = status
        e.closedReason = closedReason
        return e
    }

    @Test func aRequestClosesItselfThirtyMinutesAfterItWasAsked() {
        let asked = request("a")
        // The event is written with expiresAt = createdAt + 30 minutes, with no one closing it.
        #expect(asked.expiresAt == t0.addingTimeInterval(30 * 60))
        #expect(StopLogic.isOpen(asked, now: t0.addingTimeInterval(30 * 60 - 1)))
        #expect(!StopLogic.isOpen(asked, now: t0.addingTimeInterval(30 * 60)))
        #expect(!StopLogic.isOpen(asked, now: t0.addingTimeInterval(45 * 60)))
        #expect(StopLogic.openStops(in: [asked], now: t0.addingTimeInterval(31 * 60)).isEmpty)
        // A request made later is still open when the first has closed.
        let later = request("b", at: 10 * 60)
        #expect(StopLogic.openStops(in: [asked, later], now: t0.addingTimeInterval(31 * 60)).map(\.id) == ["b"])
    }

    @Test func aNewStopRequestIsBuiltWithAThirtyMinuteExpiry() {
        let event = EventService.makeEvent(
            type: .stopFuel, authorId: "u2", carId: "c2", location: .init(latitude: 3, longitude: 101),
            heading: 0, routeOffset: 0, message: "Low on fuel", now: t0)
        #expect(event.expiresAt == t0.addingTimeInterval(StopLogic.lifetime))
        #expect(event.message == "Low on fuel")
    }

    @Test func openStopsListsEveryOpenRequestOldestFirst() {
        let a = request("a", at: 10)
        let b = request("b", at: 0)
        let done = request("done", at: 20, expires: t0.addingTimeInterval(5))
        let closed = request("closed", at: 30, status: .closed, closedReason: .stopped)
        var hazard = request("h", at: 40); hazard.category = .hazard
        let now = t0.addingTimeInterval(60)
        #expect(StopLogic.openStops(in: [a, b, done, closed, hazard], now: now).map(\.id) == ["b", "a"])
        #expect(StopLogic.openStops(in: [done, closed, hazard], now: now).isEmpty)
    }

    @Test func aMissingStatusReadsAsOpenAndClosedNeverIs() {
        var old = request("old")
        old.expiresAt = nil
        #expect(old.status == nil)
        #expect(StopLogic.isOpen(old, now: t0.addingTimeInterval(1)))
        #expect(!StopLogic.isOpen(request("x", status: .closed), now: t0.addingTimeInterval(1)))
    }

    @Test func aMissingExpiryFallsBackToThirtyMinutesAfterItWasAsked() {
        var old = request("old")
        old.expiresAt = nil
        #expect(StopLogic.isOpen(old, now: t0.addingTimeInterval(StopLogic.lifetime - 1)))
        #expect(!StopLogic.isOpen(old, now: t0.addingTimeInterval(StopLogic.lifetime + 1)))
        // Not yet stamped by the server: just asked.
        old.createdAt = nil
        #expect(StopLogic.isOpen(old, now: t0.addingTimeInterval(5 * 3600)))
    }

    @Test func anOldStopRequestWithAPlaceAndPinnedStatusDecodesAsOpenAndIgnoresThePlace() throws {
        let event = try firestoreDecode(TripEvent.self, from: [
            "type": "stopFuel", "category": "stopRequest", "severity": "medium",
            "location": GeoPoint(latitude: 3, longitude: 101), "heading": 0.0, "routeOffset": 0.0,
            "authorId": "u2", "carId": "c2", "createdAt": Timestamp(date: t0),
            "expiresAt": Timestamp(date: t0.addingTimeInterval(StopLogic.lifetime)),
            "status": "pinned",
            "place": ["name": "Petronas Tapah", "location": GeoPoint(latitude: 4, longitude: 101)],
        ])
        #expect(event.status == .open)
        #expect(StopLogic.isOpen(event, now: t0.addingTimeInterval(60)))
    }

    @Test func anOldVoteWithAnAnswerAndASuggestionDecodesAsAnOK() throws {
        let vote = try firestoreDecode(StopVote.self, from: [
            "userId": "u3", "agree": false, "answer": "no", "suggestion": "Shell Kuala Kangsar",
            "at": Timestamp(date: t0),
        ])
        #expect(vote.userId == "u3")
        #expect(vote.id == "doc")
        #expect(vote.at == t0)
    }

    @Test func statusAndClosingReasonsDecodeWithFallbacks() throws {
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ json: String, as: T.Type) throws -> T { try decoder.decode(T.self, from: Data(json.utf8)) }
        #expect(try decode("\"closed\"", as: StopStatus.self) == .closed)
        // An older build's pinned stop is still an open one.
        #expect(try decode("\"pinned\"", as: StopStatus.self) == .open)
        #expect(try decode("\"stopped\"", as: StopClosedReason.self) == .stopped)
        #expect(try decode("\"cancelled\"", as: StopClosedReason.self) == .cancelled)
        #expect(try decode("\"left\"", as: StopClosedReason.self) == .stopped)
        #expect(try decode("\"noAnswer\"", as: StopClosedReason.self) == .stopped)
    }

    // MARK: Who is asked

    @Test func theAskingCarIsNeverAsked() throws {
        let state = try tally(stop(), me: "c2", user: "u2")
        #expect(StopLogic.viewerIsRequester(state))
        #expect(!StopLogic.needsAnswer(state))
    }

    @Test func aCarIsAskedUntilItsOKIsIn() throws {
        let open = try tally(stop(), me: "c3", user: "u3")
        #expect(StopLogic.needsAnswer(open))
        let said = try tally(stop(), votes: [ok("c3")], me: "c3", user: "u3")
        #expect(!StopLogic.needsAnswer(said))
    }

    @Test func oneOKPerCarTheOtherPhoneInTheCarIsNotAsked() throws {
        // Phone A in car 3 taps OK; phone B in car 3 (another user) now sees its car as OK.
        let phoneB = try tally(stop(), votes: [ok("c3")], me: "c3", user: "u3-second-phone")
        #expect(phoneB.viewerCarIsOK)
        #expect(!StopLogic.needsAnswer(phoneB))
        #expect(StopLogic.buttonContent(for: board([phoneB])).badge == 0)
    }

    @Test func theLeadCarIsAskedLikeEveryoneElse() throws {
        let lead = try tally(stop(), me: "c1", user: "u1")
        #expect(StopLogic.needsAnswer(lead))
        let said = try tally(stop(), votes: [ok("c1")], me: "c1", user: "u1")
        #expect(!StopLogic.needsAnswer(said))
        // There is no pinning, so an OK clears the lead car's question too.
        #expect(said.canMarkStopped)
    }

    // MARK: The Pit stop button

    @Test func buttonSaysPitStopWithNoStop() {
        let content = StopLogic.buttonContent(for: .empty)
        #expect(content.label == "Pit stop")
        #expect(content.symbol == "mappin.and.ellipse")
        #expect(content.badge == 0)
    }

    @Test func buttonShowsTheOpenStopAndBadge() throws {
        let waiting = try tally(stop(), votes: [ok("c3")], me: "c4", user: "u4")
        let content = StopLogic.buttonContent(for: board([waiting]))
        #expect(content.label == "Fuel · 2 of 4 OK")
        #expect(content.symbol == "fuelpump.fill")
        #expect(content.badge == 1)
        #expect(content.accessibilityLabel == "Fuel stop, 2 of 4 cars said OK, you have not said OK")
        // Said OK: the badge clears and the count moves.
        let answered = try tally(stop(), votes: [ok("c3"), ok("c4")], me: "c4", user: "u4")
        let after = StopLogic.buttonContent(for: board([answered]))
        #expect(after.label == "Fuel · 3 of 4 OK")
        #expect(after.badge == 0)
        #expect(after.accessibilityLabel == "Fuel stop, 3 of 4 cars said OK")
    }

    @Test func theAskersButtonCountsItsOwnCarAsOK() throws {
        let mine = try tally(request("m", by: "c1", author: "u1"), me: "c1", user: "u1")
        let content = StopLogic.buttonContent(for: board([mine]))
        #expect(content.label == "Fuel · 1 of 4 OK")
        #expect(content.badge == 0)
    }

    @Test func twoOpenRequestsReadTwoStops() throws {
        let other = request("two", by: "c4", author: "u4", at: 5, type: .stopFood)
        let a = try tally(request("one"), me: "c3", user: "u3")
        let b = try #require(StopLogic.tally(
            event: other, votes: [], cars: cars, myUserId: "u3", myCarId: "c3", isOrganizer: false))
        let content = StopLogic.buttonContent(for: board([a, b]))
        #expect(content.label == "2 stops")
        #expect(content.badge == 2)
        #expect(content.accessibilityLabel == "2 stops open, you have 2 to say OK to")
    }

    // MARK: The pill

    /// D26: a request from a car more than 2 km from mine says how far, along the route.
    @Test func pillSaysHowFarAFarRequestIs() throws {
        let first = try tally(request("one", at: 0), me: "c3", user: "u3")
        var memory = StopPillMemory()
        memory.observe([first], now: t0)
        func title(_ meters: Double?) -> String? {
            guard case .question(_, _, let title, _)? = StopPillPlanner.current(
                requests: [first], memory: memory, now: t0.addingTimeInterval(1), distance: { _ in meters }) else { return nil }
            return title
        }
        #expect(title(-40_000) == "Wyna needs fuel · 40 km behind")
        #expect(title(12_000) == "Wyna needs fuel · 12 km ahead")
        #expect(title(-1_500) == "Wyna needs fuel")
        #expect(title(2_000) == "Wyna needs fuel")
        #expect(title(nil) == "Wyna needs fuel")
        // Every car is counted once, however far: "N of M OK" (D24).
        #expect(Set(first.rows.map(\.carId)).count == first.rows.count)
        #expect(first.rows.count == 4)          // the four tracked cars
    }

    @Test func pillOffersTheOldestUnansweredRequestFirst() throws {
        let first = try tally(request("one", at: 0), me: "c3", user: "u3")
        let second = try #require(StopLogic.tally(
            event: request("two", by: "c4", author: "u4", at: 5, type: .stopFood), votes: [], cars: cars, myUserId: "u3",
            myCarId: "c3", isOrganizer: false))
        var memory = StopPillMemory()
        memory.observe([first, second], now: t0)
        guard case .question(let id, _, let title, _)? =
            StopPillPlanner.current(requests: [first, second], memory: memory, now: t0.addingTimeInterval(1)) else {
            Issue.record("expected a question"); return
        }
        #expect(id == "one")
        #expect(title == "Wyna needs fuel")
        // Once the first is answered the second is offered.
        let answered = try tally(request("one", at: 0), votes: [ok("c3")], me: "c3", user: "u3")
        guard case .question(let next, _, _, _)? =
            StopPillPlanner.current(requests: [answered, second], memory: memory, now: t0.addingTimeInterval(2)) else {
            Issue.record("expected the second question"); return
        }
        #expect(next == "two")
    }

    @Test func pillShowsTheMessageOnOneLineOrWhoAndWhen() throws {
        var withNote = stop(message: "Low on fuel, next R&R please")
        withNote.id = "one"
        let note = try tally(withNote, me: "c3", user: "u3")
        let plain = try tally(request("two"), me: "c3", user: "u3")
        var memory = StopPillMemory()
        memory.observe([note, plain], now: t0)
        guard case .question(_, let symbol, _, let detail)? =
            StopPillPlanner.current(requests: [note], memory: memory, now: t0.addingTimeInterval(1)) else {
            Issue.record("expected a question"); return
        }
        #expect(symbol == "fuelpump.fill")
        #expect(detail == "Low on fuel, next R&R please")
        guard case .question(_, _, _, let quiet)? =
            StopPillPlanner.current(requests: [plain], memory: memory, now: t0.addingTimeInterval(1)) else {
            Issue.record("expected a question"); return
        }
        #expect(quiet == "Car 2 · just now")
    }

    @Test func pillGoesQuietAfterTwentySeconds() throws {
        let state = try tally(stop(), me: "c3", user: "u3")
        var memory = StopPillMemory()
        memory.observe([state], now: t0)
        #expect(StopPillPlanner.current(requests: [state], memory: memory, now: t0.addingTimeInterval(19)) != nil)
        #expect(StopPillPlanner.current(requests: [state], memory: memory, now: t0.addingTimeInterval(20)) == nil)
        #expect(StopPillPlanner.nextChange(requests: [state], memory: memory, now: t0.addingTimeInterval(1)) == t0.addingTimeInterval(20))
        // The badge stays: the request still needs this car's OK.
        #expect(StopLogic.buttonContent(for: board([state])).badge == 1)
    }

    @Test func theLeadGetsTheSameOKPillAsEveryoneElse() throws {
        let state = try tally(stop(), me: "c1", user: "u1")
        var memory = StopPillMemory()
        memory.observe([state], now: t0)
        guard case .question(let id, _, let title, _)? = StopPillPlanner.current(requests: [state], memory: memory, now: t0) else {
            Issue.record("expected a question"); return
        }
        #expect(id == "stop1")
        #expect(title == "Wyna needs fuel")
    }

    @Test func tapConfirmsForFiveSeconds() throws {
        let state = try tally(stop(), votes: [ok("c1"), ok("c3")], me: "c3", user: "u3")
        var memory = StopPillMemory()
        let before = try tally(stop(), votes: [ok("c1")], me: "c3", user: "u3")
        memory.observe([before], now: t0)
        memory.noteOK(before, now: t0.addingTimeInterval(3))
        guard case .confirm(_, let title, let detail)? =
            StopPillPlanner.current(requests: [state], memory: memory, now: t0.addingTimeInterval(4)) else {
            Issue.record("expected a confirmation"); return
        }
        #expect(title == "You said OK")
        // Wyna's car, Aqlan's and mine: 3 of 4.
        #expect(detail == "3 of 4 OK")
        #expect(StopPillPlanner.current(requests: [state], memory: memory, now: t0.addingTimeInterval(8)) == nil)
    }

    @Test func aSecondTapDoesNotCountTheCarTwice() throws {
        let already = try tally(stop(), votes: [ok("c1"), ok("c3")], me: "c3", user: "u3")
        var memory = StopPillMemory()
        memory.noteOK(already, now: t0)
        #expect(memory.confirmation?.detail == "3 of 4 OK")
    }

    @Test func theAskerGetsAConfirmationNeverAQuestion() throws {
        let mine = try tally(request("m", by: "c1", author: "u1", at: 0), me: "c1", user: "u1")
        var memory = StopPillMemory()
        memory.observe([mine], now: t0.addingTimeInterval(1))
        guard case .asked(let title, let detail)? =
            StopPillPlanner.current(requests: [mine], memory: memory, now: t0.addingTimeInterval(2)) else {
            Issue.record("expected the asked pill"); return
        }
        #expect(title == "Informed the convoy")
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
        #expect(StopCardGate.needsPassengerCheck(driving: true, session: session))
        session.confirmPassenger()
        #expect(!StopCardGate.needsPassengerCheck(driving: true, session: session))
        session.close()
        #expect(StopCardGate.needsPassengerCheck(driving: true, session: session))
        // "I'm driving" sends without a message and remembers nothing.
        session.confirmPassenger()
        session.confirmDriving()
        #expect(StopCardGate.needsPassengerCheck(driving: true, session: session))
    }

    @Test func nothingAsksWhileParked() {
        let session = StopCardSession()
        #expect(!StopCardGate.needsPassengerCheck(driving: false, session: session))
    }
}

// MARK: The card's ask steps

/// Records what the card would send.
private final class FakeStopService: StopServing, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [(type: EventType, message: String?)] = []
    var failing = false
    var requests: [(type: EventType, message: String?)] { lock.withLock { sent } }

    func request(type: EventType, message: String?, context: StopContext, snapshot: ReportSnapshot) async throws -> String {
        if failing { throw URLError(.notConnectedToInternet) }
        lock.withLock { sent.append((type, message)) }
        return "new"
    }
}

@MainActor
struct StopAskTests {
    private func context(withFix: Bool = true) -> StopContext {
        StopContext(
            tripId: "t", userId: "u1", carId: "c1", isOrganizer: false,
            snapshot: {
                withFix
                    ? ReportSnapshot(
                        coordinate: .init(latitude: 3, longitude: 101), heading: 0, route: nil, previousOffset: nil,
                        capturedAt: Date())
                    : nil
            },
            mainRoute: nil)
    }

    @Test func sendingNeedsAReasonAndSendsItWithoutAMessageByDefault() async {
        let service = FakeStopService()
        let ask = RequestStopModel(context: context(), service: service)
        #expect(!ask.canSend)
        #expect(await ask.send() == false)
        ask.choose(StopReason.all[0])
        #expect(ask.canSend)
        #expect(await ask.send())
        #expect(service.requests.count == 1)
        #expect(service.requests[0].type == .stopFuel)
        #expect(service.requests[0].message == nil)
    }

    @Test func aTypedMessageIsSentTrimmedAndAtMost280Characters() async {
        let service = FakeStopService()
        let ask = RequestStopModel(context: context(), service: service)
        ask.choose(StopReason.all[2])
        ask.message = "  Low on fuel, next R&R please  "
        #expect(await ask.send())
        #expect(service.requests[0].type == .stopFood)
        #expect(service.requests[0].message == "Low on fuel, next R&R please")
        ask.message = String(repeating: "m", count: 500)
        #expect(ask.message.count == 280)
    }

    @Test func goingBackToTheTilesDropsTheMessage() {
        let ask = RequestStopModel(context: context(), service: FakeStopService())
        ask.choose(StopReason.all[0])
        ask.message = "hello"
        ask.clearReason()
        #expect(ask.reason == nil)
        #expect(ask.message.isEmpty)
    }

    @Test func aFailedSendSaysSoInPlainWords() async {
        let service = FakeStopService()
        service.failing = true
        let ask = RequestStopModel(context: context(), service: service)
        ask.choose(StopReason.all[0])
        #expect(await ask.send() == false)
        #expect(ask.sending == .failed("Could not reach the convoy. Try again in a moment."))
        let noFix = RequestStopModel(context: context(withFix: false), service: FakeStopService())
        noFix.choose(StopReason.all[0])
        #expect(await noFix.send() == false)
        #expect(noFix.sending == .failed("Waiting for your location. Try again in a moment."))
    }

    @Test func onlyTheMessageIsBehindThePassengerCheck() {
        // On a moving phone Add a message asks first; nothing else on the card does (its buttons are
        // plain actions, see StopCard), and a passenger's answer lasts until the card closes.
        var session = StopCardSession()
        #expect(StopCardGate.needsPassengerCheck(driving: true, session: session))
        session.confirmPassenger()
        #expect(!StopCardGate.needsPassengerCheck(driving: true, session: session))
        #expect(!StopCardGate.needsPassengerCheck(driving: false, session: StopCardSession()))
    }

    @Test func sendingGoesThroughTheServiceWithTheReasonOnTheCard() async {
        // The ask works with no passenger check at all: reason, then Inform the convoy.
        let service = FakeStopService()
        let model = StopCardModel(context: context(), service: service)
        #expect(model.screen == .home)
        model.ask.choose(StopReason.all[3])
        #expect(await model.ask.send())
        #expect(service.requests.map(\.type) == [.stopRest])
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

    private static let ipoh = DestinationResult(name: "Ipoh", subtitle: "", coordinate: .init(latitude: 3, longitude: 101.5))

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

    private func eventDoc(_ tripId: String, _ eventId: String) async throws -> TripEvent {
        try await Firestore.firestore().document(FirestorePaths.event(tripId: tripId, eventId: eventId))
            .getDocument(as: TripEvent.self)
    }

    /// The first open request from `stream` that satisfies `predicate`.
    private func state(
        _ stream: AsyncStream<StopBoard>, where predicate: @escaping @Sendable (StopRequestState) -> Bool
    ) async throws -> StopRequestState {
        let found = await firstValue(of: stream) { $0.requests.contains(where: predicate) }
        return try #require(found?.requests.first(where: predicate), "no matching state arrived")
    }

    /// Organizer (lead car) asks with a message, the request is written with a 30 minute expiry, then
    /// the organizer says We've stopped; the listener sees each step.
    @Test func leadAsksWithAMessageAndMarksItStopped() async throws {
        let trip = try await EmulatorTrip.make(name: "Stops", destination: Self.ipoh)
        let ctx = context(trip.tripId, uid: trip.uid, carId: trip.carId, organizer: true)
        let stream = StopService.listen(context: ctx, refresh: .seconds(60))

        let eventId = try await service.request(
            type: .stopFuel, message: "Low on fuel, next R&R please", context: ctx, snapshot: try #require(ctx.snapshot()))
        let asked = try await state(stream) { $0.message != nil }
        #expect(asked.eventId == eventId)
        #expect(asked.message == "Low on fuel, next R&R please")
        #expect(asked.canMarkStopped)
        #expect(asked.isAuthor)
        #expect(asked.title == "Aqlan needs fuel")
        #expect(asked.okCount == 1)
        let written = try await eventDoc(trip.tripId, eventId)
        let createdAt = try #require(written.createdAt)
        #expect(written.expiresAt == createdAt.addingTimeInterval(30 * 60))

        try await service.close(tripId: trip.tripId, eventId: eventId, reason: .stopped, userId: trip.uid, now: Date().addingTimeInterval(-1))
        let closed = await firstValue(of: stream) { $0.requests.isEmpty }
        #expect(closed != nil, "expected the listener to report no open stop")
        let closedDoc = try await eventDoc(trip.tripId, eventId)
        #expect(closedDoc.status == .closed)
        #expect(closedDoc.closedReason == .stopped)
        #expect(closedDoc.closedBy == trip.uid)
        #expect(closedDoc.expiresAt != nil)
    }

    /// A joined car says OK and is tallied; it cannot close someone else's request, nor say OK for
    /// another car, and a stop with no message has none.
    @Test func memberSaysOKButCannotCloseOrVoteForAnotherCar() async throws {
        let trip = try await EmulatorTrip.make(name: "Stops", destination: Self.ipoh)
        let orgContext = context(trip.tripId, uid: trip.uid, carId: trip.carId, organizer: true)
        let eventId = try await service.request(
            type: .stopFood, message: nil, context: orgContext, snapshot: try #require(orgContext.snapshot()))

        let (joiner, joinedCar) = try await EmulatorTrip.joinAsGuest(
            code: try await trip.code(), name: "Wyna", carName: "Wyna's X70", tracker: true)
        let ctx = context(trip.tripId, uid: joiner, carId: joinedCar, organizer: false)
        let stream = StopService.listen(context: ctx, refresh: .seconds(60))

        let before = try await state(stream) { $0.rows.count == 2 }
        #expect(before.canMarkStopped == false)
        #expect(before.isAuthor == false)
        #expect(before.viewerCarIsOK == false)
        #expect(before.message == nil)

        try await service.ok(tripId: trip.tripId, eventId: eventId, carId: joinedCar, userId: joiner)
        let said = try await state(stream) { $0.viewerCarIsOK }
        #expect(said.okCount == 2)
        // A second phone in the car writes the same document: still one OK for the car.
        try await service.ok(tripId: trip.tripId, eventId: eventId, carId: joinedCar, userId: joiner)

        await #expect(throws: (any Error).self) {
            try await service.close(tripId: trip.tripId, eventId: eventId, reason: .stopped, userId: joiner)
        }
        await #expect(throws: (any Error).self) {
            try await service.close(tripId: trip.tripId, eventId: eventId, reason: .cancelled, userId: joiner)
        }
        // An OK for the organizer's car is also rejected.
        await #expect(throws: (any Error).self) {
            try await service.ok(tripId: trip.tripId, eventId: eventId, carId: trip.carId, userId: joiner)
        }
        let doc = try await eventDoc(trip.tripId, eventId)
        #expect(doc.status == nil)
        #expect(doc.closedReason == nil)
    }

    /// The asker cancels their own request.
    @Test func askerCancelsOwnRequest() async throws {
        let trip = try await EmulatorTrip.make(name: "Stops", destination: Self.ipoh)
        let ctx = context(trip.tripId, uid: trip.uid, carId: trip.carId, organizer: false)
        let eventId = try await service.request(
            type: .stopToilet, message: nil, context: ctx, snapshot: try #require(ctx.snapshot()))
        try await service.close(tripId: trip.tripId, eventId: eventId, reason: .cancelled, userId: trip.uid)
        let doc = try await eventDoc(trip.tripId, eventId)
        #expect(doc.status == .closed)
        #expect(doc.closedReason == .cancelled)
        #expect(doc.expiresAt != nil)
    }
}
