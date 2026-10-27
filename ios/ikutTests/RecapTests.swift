import CoreLocation
import Foundation
import Testing
@testable import ikut

struct RecapLogicTests {
    @Test func stepsWithAPlaceFlyAndOnesWithoutJump() {
        // Near or far, a step with a place flies (CameraPace paces it); D57 replaced the jump past 3 screen widths.
        let a = CLLocationCoordinate2D(latitude: 3.0, longitude: 101.0)
        #expect(RecapLogic.stepMove(from: a, to: .init(latitude: 3.2, longitude: 101.2)) == .fly)
        #expect(RecapLogic.stepMove(from: a, to: .init(latitude: 5.0, longitude: 101.0)) == .fly)
        #expect(RecapLogic.stepMove(from: nil, to: a) == .jump)
        #expect(RecapLogic.stepMove(from: a, to: nil) == .jump)
    }

    private let t0 = Fixtures.t0
    private let dest = CLLocationCoordinate2D(latitude: 4.6, longitude: 101.09)

    private func snapshot(positions: [RecapPosition] = [], events: [RecapEvent] = [], ended: Double? = 10_000) -> RecapSnapshot {
        let route = Polyline.encode([.init(latitude: 3.68, longitude: 101.52), dest])
        return RecapSnapshot(
            tripId: "t1", name: "Balik", destinationName: "Ipoh",
            destinationLatitude: dest.latitude, destinationLongitude: dest.longitude, route: route,
            createdAt: t0, endedAt: ended.map { t0.addingTimeInterval($0) },
            cars: [
                RecapCar(id: "c1", name: "Myvi", color: "#2563EB", number: 1, isLead: true),
                RecapCar(id: "c2", name: "Axia", color: "#D9480F", number: 2, isLead: false),
            ],
            memberNames: ["u1": "Aqlan", "u2": "Wyna", "u3": "Faiz"], memberCars: ["u1": "c1", "u2": "c2", "u3": "c1"],
            positions: positions, events: events)
    }

    private func pos(_ car: String, near: Bool, offset: Double?, at minutes: Double) -> RecapPosition {
        RecapPosition(carId: car, latitude: near ? dest.latitude + 0.001 : 4.0, longitude: dest.longitude,
                      convoyOffset: offset, updatedAt: t0.addingTimeInterval(minutes * 60))
    }

    private func event(_ id: String, _ type: EventType, car: String, user: String, at minutes: Double, expires: Double? = nil, message: String? = nil) -> RecapEvent {
        RecapEvent(id: id, type: type.rawValue, carId: car, authorId: user, latitude: 4, longitude: 101,
                   createdAt: t0.addingTimeInterval(minutes * 60), expiresAt: expires.map { t0.addingTimeInterval($0 * 60) },
                   message: message)
    }

    @Test func durationNeedsBothEnds() {
        #expect(RecapLogic.duration(start: t0, end: t0.addingTimeInterval(600)) == 600)
        #expect(RecapLogic.duration(start: t0, end: nil) == nil)
        #expect(RecapLogic.duration(start: t0, end: t0.addingTimeInterval(-1)) == nil)
    }

    @Test func arrivalsAreCarsNearDestinationEarliestFirst() {
        let a = RecapLogic.arrivals(
            positions: [pos("c1", near: true, offset: nil, at: 170), pos("c2", near: true, offset: nil, at: 160), pos("c3", near: false, offset: nil, at: 150)],
            destination: dest)
        #expect(a.map(\.carId) == ["c2", "c1"])
    }

    @Test func spreadNeedsTwoMergedCars() {
        #expect(RecapLogic.finalSpread(positions: [pos("c1", near: false, offset: 5_000, at: 1)]) == nil)
        #expect(RecapLogic.finalSpread(positions: [pos("c1", near: false, offset: 5_000, at: 1), pos("c2", near: false, offset: 1_500, at: 1), pos("c3", near: false, offset: nil, at: 1)]) == 3_500)
    }

    @Test func countsStopsAndRoadReports() {
        let r = RecapLogic.recap(snapshot(events: [
            event("h1", .debris, car: "c1", user: "u1", at: 10),
            event("h2", .heavyRain, car: "c2", user: "u2", at: 20),
            event("m1", .message, car: "c2", user: "u2", at: 25),
            event("s1", .stopFuel, car: "c2", user: "u2", at: 30, expires: 50),
        ]))
        #expect(r.roadReportCount == 2)
        #expect(r.stopCount == 1)
        #expect(r.carCount == 2)
        #expect(r.peopleCount == 3)
        #expect(r.duration == 10_000)
    }

    @Test func timelineIsChronologicalAndListsEachStopOnce() {
        let r = RecapLogic.recap(snapshot(
            positions: [pos("c1", near: true, offset: 100, at: 150)],
            events: [event("s1", .stopFuel, car: "c2", user: "u2", at: 30, expires: 60), event("h1", .debris, car: "c1", user: "u1", at: 10)]))
        // No "stopped at" row: a stop is the reason, who asked and when, nothing about a place.
        #expect(r.timeline.map(\.id) == ["start", "h1", "s1", "arrived", "end"])
        #expect(r.timeline.first { $0.id == "s1" }?.title == "Wyna asked for a fuel stop")
        #expect(r.timeline.allSatisfy { $0.time >= t0 })
    }

    @Test func aStopShowsItsMessageWhenThereWasOne() {
        let r = RecapLogic.recap(snapshot(events: [
            event("s1", .stopFuel, car: "c2", user: "u2", at: 30, message: "Low on fuel, next R&R please"),
            event("s2", .stopRest, car: "c1", user: "u1", at: 40),
        ]))
        let withNote = r.timeline.first { $0.id == "s1" }
        #expect(withNote?.detail.hasSuffix("Low on fuel, next R&R please") == true)
        let without = r.timeline.first { $0.id == "s2" }
        #expect(without?.detail.contains("R&R") == false)
        #expect(r.timeline.contains { $0.id == "s1-done" } == false)
    }

    @Test func awardsFromWhatHappened() {
        let r = RecapLogic.recap(snapshot(
            positions: [pos("c1", near: true, offset: 9_000, at: 150), pos("c2", near: false, offset: 4_000, at: 151)],
            events: [
                event("h1", .debris, car: "c2", user: "u2", at: 10), event("h2", .pothole, car: "c2", user: "u2", at: 12),
                event("h3", .animal, car: "c1", user: "u1", at: 14), event("s1", .stopFood, car: "c1", user: "u1", at: 30),
            ]))
        let byKind = Dictionary(uniqueKeysWithValues: r.awards.map { ($0.kind, $0.carId) })
        #expect(byKind[.lead] == "c1")
        #expect(byKind[.firstIn] == "c1")
        #expect(byKind[.reporter] == "c2")
        #expect(byKind[.stopCaller] == "c1")
        #expect(byKind[.sweeper] == "c2")
    }

    @Test func awardTiesGoToTheCarWhoseFirstEventCameFirst() {
        let r = RecapLogic.recap(snapshot(
            positions: [pos("c1", near: true, offset: 9_000, at: 150), pos("c2", near: false, offset: 4_000, at: 151)],
            events: [
                event("h1", .debris, car: "c2", user: "u2", at: 10), event("h2", .pothole, car: "c1", user: "u1", at: 12),
                event("s1", .stopFood, car: "c1", user: "u1", at: 20), event("s2", .stopFuel, car: "c2", user: "u2", at: 25),
            ]))
        let byKind = Dictionary(uniqueKeysWithValues: r.awards.map { ($0.kind, $0.carId) })
        #expect(byKind[.reporter] == "c2")
        #expect(byKind[.stopCaller] == "c1")
    }

    @Test func degradesWithoutPositionsOrEvents() {
        let r = RecapLogic.recap(snapshot(), now: t0.addingTimeInterval(10_000 + 8 * 24 * 3600))
        #expect(r.arrivals.isEmpty)
        #expect(r.finalSpread == nil)
        #expect(r.timeline.map(\.id) == ["start", "end"])
        #expect(r.notes.contains { $0.contains("7 days") })
        #expect(r.stats.count == 4)
        #expect(r.stats[2].label == "Stops")
        #expect(r.awards.map(\.kind) == [.lead])
    }

    @Test func notEndedHasNoDuration() {
        let r = RecapLogic.recap(snapshot(ended: nil))
        #expect(r.duration == nil)
        #expect(r.stats[1].value == "–")
    }

    @Test func mergeKeepsCachedEventsPurgedOnServer() {
        let cached = snapshot(positions: [pos("c2", near: true, offset: nil, at: 100)], events: [event("h1", .debris, car: "c1", user: "u1", at: 10)])
        let fresh = snapshot(positions: [pos("c1", near: true, offset: nil, at: 120)], events: [event("s1", .stopFuel, car: "c2", user: "u2", at: 30)])
        let merged = RecapLogic.merge(cached: cached, fresh: fresh)
        #expect(merged.events.map(\.id) == ["h1", "s1"])
        #expect(Set(merged.positions.map(\.carId)) == ["c1", "c2"])
        var other = cached
        other.tripId = "t2"
        #expect(RecapLogic.merge(cached: other, fresh: fresh) == fresh)
    }

    @Test func snapshotRoundTripsThroughJSON() throws {
        let s = snapshot(positions: [pos("c1", near: true, offset: 1, at: 1)], events: [event("h1", .debris, car: "c1", user: "u1", at: 10)])
        let back = try JSONDecoder().decode(RecapSnapshot.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    @Test func pastTripsUpsertKeepsEndedAndOrder() {
        let a = PastTrips.Entry(id: "a", name: "A", destination: "X", endedAt: t0, seenAt: t0)
        let b = PastTrips.Entry(id: "b", name: "B", destination: "Y", endedAt: nil, seenAt: t0)
        var list = PastTrips.upsert([], a)
        list = PastTrips.upsert(list, b)
        list = PastTrips.upsert(list, .init(id: "a", name: "A2", destination: "X", endedAt: nil, seenAt: t0))
        #expect(list.map(\.id) == ["a", "b"])
        #expect(list[0].endedAt == t0)
        #expect(list[0].name == "A2")
    }

    @Test func withPhraseNamesWhoYouWentWith() {
        #expect(PastTrips.withPhrase(nil) == nil)
        #expect(PastTrips.withPhrase([]) == nil)
        #expect(PastTrips.withPhrase(["Ali"]) == "With Ali")
        #expect(PastTrips.withPhrase(["sara", "Ali"]) == "With Ali and sara")
        #expect(PastTrips.withPhrase(["Wyna", "ali", "Sara"]) == "With ali and 2 others")
        #expect(PastTrips.withPhrase(["E", "D", "C", "B", "A"]) == "With A and 4 others")
    }

    @Test func othersExcludesMeAndIsNilWhenUnknown() {
        let names = ["me": "Aqlan", "u2": "Wyna", "u3": "Ali"]
        #expect(PastTrips.others(from: names, excluding: "me") == ["Ali", "Wyna"])
        #expect(PastTrips.others(from: ["me": "Aqlan"], excluding: "me") == [])
        #expect(PastTrips.others(from: names, excluding: nil) == ["Ali", "Aqlan", "Wyna"])
    }

    @Test func pastTripsUpsertKeepsPreviousOthersWhenNil() {
        let a = PastTrips.Entry(id: "a", name: "A", destination: "X", endedAt: t0, seenAt: t0, others: ["Ali"])
        var list = PastTrips.upsert([], a)
        list = PastTrips.upsert(list, .init(id: "a", name: "A", destination: "X", endedAt: nil, seenAt: t0, others: nil))
        #expect(list[0].others == ["Ali"])
        list = PastTrips.upsert(list, .init(id: "a", name: "A", destination: "X", endedAt: nil, seenAt: t0, others: ["Sara"]))
        #expect(list[0].others == ["Sara"])
    }

    @Test func pastTripEntryDecodesOldJSONWithoutOthers() throws {
        let json = #"[{"id":"a","name":"A","destination":"X","seenAt":0}]"#
        let list = try JSONDecoder().decode([PastTrips.Entry].self, from: Data(json.utf8))
        #expect(list[0].others == nil)
    }

    @Test func theOnTheRoadTileReadsAsOneDurationWithNoUnit() {
        let r = RecapLogic.recap(snapshot(), now: t0.addingTimeInterval(10_000 + 8 * 24 * 3600))
        #expect(r.stats[1].label == "On the road")
        #expect(r.stats[1].value == "2 h 47 min")
        #expect(r.stats[1].unit == "")
    }
}
