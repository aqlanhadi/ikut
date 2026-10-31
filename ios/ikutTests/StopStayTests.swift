import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

@Suite("Changing a stop's stay (D121)")
@MainActor
struct StopStayTests {
    let t0 = Fixtures.t0

    func stop(
        _ id: String = "s1", kind: PlannedStopKind = .fuel, minutes: Int? = 20, arrivedAt: Date? = nil,
        leftAt: Date? = nil, skipped: Bool = false
    ) -> PlannedStop {
        PlannedStop.fixture(
            id, offset: 20_000, coordinate: GeoPoint(latitude: 3, longitude: 101), kind: kind,
            minutes: kind == .meet ? nil : minutes, skipped: skipped ? true : nil, arrivedAt: arrivedAt,
            leftAt: leftAt, leftBy: leftAt == nil ? nil : "u1")
    }

    // MARK: Which lengths

    @Test func theUsualLengthsAreOffered() {
        #expect(StopStay.options(current: 20) == [10, 20, 30, 60])
        #expect(StopStay.options(current: nil) == [10, 20, 30, 60])
    }

    @Test func aLengthOutsideTheUsualOnesStaysOnTheListInOrder() {
        #expect(StopStay.options(current: 45) == [10, 20, 30, 45, 60])
        #expect(StopStay.options(current: 5) == [5, 10, 20, 30, 60])
        #expect(StopStay.options(current: 90) == [10, 20, 30, 60, 90])
    }

    @Test func onlyWholeMinutesFromOneTo720Count() {
        #expect(StopStay.isValid(1) && StopStay.isValid(720))
        #expect(!StopStay.isValid(0) && !StopStay.isValid(721) && !StopStay.isValid(-10))
    }

    // MARK: Who may

    @Test func onlyTheOrganizerOnAnOpenStopThatIsNotTheMeetingPoint() {
        #expect(StopStay.canEdit(stop(), isOrganizer: true))
        #expect(!StopStay.canEdit(stop(), isOrganizer: false))
        #expect(!StopStay.canEdit(stop(kind: .meet), isOrganizer: true))
        #expect(!StopStay.canEdit(stop(skipped: true), isOrganizer: true))
        #expect(!StopStay.canEdit(stop(leftAt: t0), isOrganizer: true))
        // A stop with no length yet can be given one.
        #expect(StopStay.canEdit(stop(minutes: nil), isOrganizer: true))
    }

    // MARK: What follows

    @Test func leavingAtMovesWithTheNewLength() {
        let s = stop(arrivedAt: t0)
        #expect(StopStay.leavingAt(s, minutes: 30) == t0.addingTimeInterval(30 * 60))
        #expect(StopStay.leavingAt(s, minutes: 10) == t0.addingTimeInterval(10 * 60))
        // The same stop, read after the write arrived.
        let after = StopStay.changed(s, to: 30)
        #expect(after?.minutes == 30)
        #expect(after.flatMap(StopLeave.leavingAt) == t0.addingTimeInterval(30 * 60))
        // No arrival yet: no time to show, whatever the length.
        #expect(StopStay.leavingAt(stop(arrivedAt: nil), minutes: 30) == nil)
    }

    @Test func theSameOrAnInvalidLengthChangesNothing() {
        #expect(StopStay.changed(stop(), to: 20) == nil)
        #expect(StopStay.changed(stop(), to: 0) == nil)
        #expect(StopStay.changed(stop(), to: 721) == nil)
    }

    // MARK: The lobby's list

    private func planner(_ stops: [PlannedStop]) -> StopPlanner {
        let planner = StopPlanner(delay: .zero, origin: { nil }, save: { _ in })
        planner.sync(trip: Trip.fixture(organizerId: "u"), stops: stops)
        return planner
    }

    @Test func theLobbyListShowsTheNewLengthAtOnce() {
        let planner = planner([stop("s1"), stop("s2", kind: .food, minutes: nil)])
        #expect(planner.setStay(id: "s1", minutes: 30))
        #expect(planner.setStay(id: "s2", minutes: 10))
        #expect(planner.items.map(\.minutes) == [30, 10])
    }

    @Test func theLobbyListRefusesTheMeetingPointAnUnknownStopAndAnInvalidLength() {
        let planner = planner([stop("m", kind: .meet), stop("s1")])
        #expect(!planner.setStay(id: "m", minutes: 30))
        #expect(!planner.setStay(id: "nope", minutes: 30))
        #expect(!planner.setStay(id: "s1", minutes: 0))
        #expect(planner.items.map(\.minutes) == [nil, 20])
    }

    @Test func theLobbyListLeavesAStopAloneWhileTheRouteIsBeingBuilt() {
        let planner = planner([stop("s1")])
        planner.add(StopDraft(name: "Bidor", coordinate: .init(latitude: 3, longitude: 101), kind: .food, minutes: 20))
        #expect(planner.status == .building)
        #expect(!planner.setStay(id: "s1", minutes: 30))
    }
}
