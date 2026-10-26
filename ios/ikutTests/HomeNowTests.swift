import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

struct HomeNowTests {
    private let utc = TimeZone(identifier: "UTC")!

    private func at(_ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: hour, minute: minute))!
    }

    private func trip(startedAt: Date? = nil, status: TripStatus = .active) -> Trip {
        .fixture(name: "Trip", code: "ABC123", organizerId: "u1", status: status, startedAt: startedAt)
    }

    private func cars(sharing: Int, of total: Int) -> [Car] {
        (0..<total).map { i in
            Car(id: "c\(i)", name: "Car \(i)", color: "#FF0000", trackerUserId: i < sharing ? "u\(i)" : nil,
                isLead: i == 0, route: nil, mergeOffset: nil, state: .joining)
        }
    }

    private func stop(_ kind: PlannedStopKind, meetAt: Date? = nil, order: Int = 0, skipped: Bool? = nil) -> PlannedStop {
        PlannedStop(id: "s\(order)", name: "Stop", coordinate: GeoPoint(latitude: 3, longitude: 101), routeOffset: 0,
                    kind: kind, meetAt: meetAt, order: order, skipped: skipped)
    }

    private func status(_ trip: Trip?, _ cars: [Car] = [], _ stops: [PlannedStop] = []) -> String {
        HomeNow.status(trip: trip, cars: cars, stops: stops, timeZone: utc)
    }

    @Test func gatheringWithAMeetingPoint() {
        #expect(status(trip(), cars(sharing: 4, of: 5), [stop(.meet, meetAt: at(12, 0))])
                == "Gathering · 4 of 5 cars ready · meet 12:00")
    }

    @Test func gatheringWithoutAMeetingPoint() {
        #expect(status(trip(), cars(sharing: 4, of: 5)) == "Gathering · 4 of 5 cars ready")
        // A fuel stop first, or a skipped or untimed meeting point, adds no meet time.
        #expect(status(trip(), cars(sharing: 4, of: 5), [stop(.fuel)]) == "Gathering · 4 of 5 cars ready")
        #expect(status(trip(), cars(sharing: 4, of: 5), [stop(.meet, meetAt: at(12, 0), skipped: true)]) == "Gathering · 4 of 5 cars ready")
        #expect(status(trip(), cars(sharing: 4, of: 5), [stop(.meet)]) == "Gathering · 4 of 5 cars ready")
    }

    @Test func readyCountsCarsWithAPhoneSharing() {
        #expect(status(trip(), cars(sharing: 3, of: 3)) == "Gathering · 3 of 3 cars ready")
        #expect(status(trip(), cars(sharing: 2, of: 3)) == "Gathering · 2 of 3 cars ready")
        #expect(status(trip(), cars(sharing: 0, of: 3)) == "Gathering · 0 of 3 cars ready")
        #expect(status(trip(), []) == "Gathering")
    }

    @Test func startedSaysSinceWhen() {
        #expect(status(trip(startedAt: at(12, 5)), cars(sharing: 5, of: 5), [stop(.meet, meetAt: at(12, 0))])
                == "On the move · since 12:05")
    }

    @Test func aTripThatDidNotLoadSaysInProgress() {
        #expect(status(nil) == "In progress")
    }

    @Test func splitsNowFromPastKeepingOrder() {
        func entry(_ id: String, ended: Bool) -> PastTrips.Entry {
            PastTrips.Entry(id: id, name: id, destination: "D", endedAt: ended ? Date() : nil, seenAt: Date(), others: nil)
        }
        let list = [entry("a", ended: true), entry("b", ended: false), entry("c", ended: true), entry("d", ended: false)]
        let parts = HomeNow.split(list)
        #expect(parts.now.map(\.id) == ["b", "d"])
        #expect(parts.past.map(\.id) == ["a", "c"])
    }

    @Test func noRunningTripMeansNoNowSection() {
        let ended = PastTrips.Entry(id: "a", name: "a", destination: "D", endedAt: Date(), seenAt: Date(), others: nil)
        #expect(HomeNow.split([ended]).now.isEmpty)
        #expect(HomeNow.split([]).now.isEmpty)
    }
}
