import CoreLocation
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

/// D25 piece 3a: "R&R Tapah in 2 km. Take the exit." once per planned stop, per phone.
@MainActor
struct StopApproachTests {
    private func stop(_ id: String, at offset: Double, kind: PlannedStopKind = .fuel, minutes: Int? = 20,
                      name: String = "R&R Tapah", skipped: Bool? = nil, order: Int = 1) -> PlannedStop {
        // Set the id after init: passing a non-nil @DocumentID to the initializer logs a Firestore warning.
        var stop = PlannedStop(
            id: nil, name: name, coordinate: GeoPoint(latitude: 4, longitude: 101), routeOffset: offset,
            kind: kind, minutes: minutes, order: order, skipped: skipped)
        stop.id = id
        return stop
    }

    @Test func firesOnceAtAboutTwoKilometresForAStopAhead() {
        var watch = StopApproach()
        let stops = [stop("s1", at: 50_000)]
        #expect(watch.check(stops: stops, myOffset: 40_000).isEmpty)
        #expect(watch.check(stops: stops, myOffset: 47_900).isEmpty)       // 2.1 km
        let due = watch.check(stops: stops, myOffset: 48_050)               // 1.95 km
        #expect(due.map(\.stopId) == ["s1"])
        #expect(due.first?.distance == 1_950)
        #expect(watch.check(stops: stops, myOffset: 48_500).isEmpty)       // still driving up to it
    }

    @Test func notAgainWhenGPSJittersAroundTwoKilometres() {
        var watch = StopApproach()
        let stops = [stop("s1", at: 50_000)]
        #expect(watch.check(stops: stops, myOffset: 48_100).count == 1)
        #expect(watch.check(stops: stops, myOffset: 47_700).isEmpty)       // jumped back to 2.3 km
        #expect(watch.check(stops: stops, myOffset: 48_050).isEmpty)       // and in again
        #expect(watch.check(stops: stops, myOffset: 49_900).isEmpty)
    }

    @Test func notAgainAfterDrivingPast() {
        var watch = StopApproach()
        let stops = [stop("s1", at: 50_000)]
        #expect(watch.check(stops: stops, myOffset: 48_100).count == 1)
        #expect(watch.check(stops: stops, myOffset: 50_400).isEmpty)       // 400 m past it
        #expect(watch.check(stops: stops, myOffset: 49_000).isEmpty)       // an offset that wobbles back
    }

    @Test func neverForASkippedStopOrOneBehindTheCar() {
        var watch = StopApproach()
        let stops = [stop("skipped", at: 50_000, skipped: true), stop("behind", at: 30_000)]
        #expect(watch.check(stops: stops, myOffset: 49_000).isEmpty)
        #expect(watch.check(stops: stops, myOffset: 31_000).isEmpty)       // first seen 1 km past "behind"
        // A relaunch with the car already past the stop stays quiet too.
        var relaunched = StopApproach()
        #expect(relaunched.check(stops: [stop("behind", at: 30_000)], myOffset: 35_000).isEmpty)
    }

    @Test func skippedAfterItWasDueButBeforeItFiredNeverFires() {
        var watch = StopApproach()
        #expect(watch.check(stops: [stop("s1", at: 50_000)], myOffset: 40_000).isEmpty)
        #expect(watch.check(stops: [stop("s1", at: 50_000, skipped: true)], myOffset: 48_500).isEmpty)
    }

    @Test func neverForAMeetingPointOrWithoutAnOffsetOrStops() {
        var watch = StopApproach()
        #expect(watch.check(stops: [stop("m", at: 1_500, kind: .meet, minutes: nil, order: 0)], myOffset: 0).isEmpty)
        #expect(watch.check(stops: [stop("s1", at: 1_000)], myOffset: nil).isEmpty)
        #expect(watch.check(stops: [], myOffset: 10_000).isEmpty)
    }

    @Test func eachStopFiresOnItsOwnAndTheNearestComesFirst() {
        var watch = StopApproach()
        let stops = [stop("a", at: 50_000), stop("b", at: 51_000, name: "Ipoh Lama", order: 2)]
        #expect(watch.check(stops: stops, myOffset: 49_100).map(\.stopId) == ["a", "b"])
        var again = StopApproach()
        #expect(again.check(stops: stops, myOffset: 49_500).map(\.name) == ["R&R Tapah", "Ipoh Lama"])
    }

    @Test func pillStaysUntilNearlyThereSkippedOrPassed() {
        let s = stop("s1", at: 50_000)
        #expect(StopApproach.isShowing(s, distance: 1_900))
        #expect(!StopApproach.isShowing(s, distance: 100))
        #expect(!StopApproach.isShowing(s, distance: -50))
        #expect(!StopApproach.isShowing(stop("s1", at: 50_000, skipped: true), distance: 1_900))
        #expect(!StopApproach.isShowing(nil, distance: 1_900))
        #expect(!StopApproach.isShowing(s, distance: nil))
    }

    // MARK: Words

    @Test func wordsFollowTheKindOfStop() {
        func alert(_ kind: PlannedStopKind, minutes: Int?, name: String = "R&R Tapah", distance: Double = 1_950) -> TripAlert {
            AlertWording.stopApproach(
                tripId: "t", due: .init(stopId: "s1", name: name, kind: kind, minutes: minutes, distance: distance))
        }
        let fuel = alert(.fuel, minutes: 20)
        #expect(fuel.title == "R&R Tapah in 2 km")
        #expect(fuel.body == "Take the exit · Fuel · 20 min")
        #expect(fuel.spoken == "R&R Tapah in 2 km. Take the exit.")
        #expect(fuel.kind == .stopApproach)
        #expect(fuel.id == "s1@stopapproach")
        #expect(alert(.rest, minutes: nil).body == "Take the exit · Rest")
        #expect(alert(.toilet, minutes: 10).spoken == "R&R Tapah in 2 km. Take the exit.")
        let lunch = alert(.food, minutes: 45, name: "Lunch, Ipoh Lama", distance: 1_540)
        #expect(lunch.spoken == "Lunch, Ipoh Lama in 1.5 km. Food stop ahead.")
        #expect(lunch.body == "Food stop ahead · Food · 45 min")
        #expect(alert(.sight, minutes: nil).spoken == "R&R Tapah in 2 km. Coming up.")
    }

    // MARK: On the map model

    private final class Recorder: AlertAnnouncing {
        var alerts: [TripAlert] = []
        func announce(event: TripEvent, distance: Double?) async -> Bool { false }
        func announce(alert: TripAlert) -> Bool { alerts.append(alert); return true }
    }

    /// The demo convoy's lead (my car) is 30 km short of nothing in particular; stops are placed from it.
    private func demo(_ stops: [PlannedStop], tripId: String = "demo") -> (TripMapModel, Recorder, Double) {
        let model = MapDemo.model()
        let recorder = Recorder()
        model.startHazardAlerts(announcer: recorder, userId: "u-c1", tripId: tripId)
        model.setStops(stops)
        return (model, recorder, model.convoy.convoy.first?.convoyOffset ?? 0)
    }

    @Test func modelSpeaksOnceAndShowsThePillThenClearsItWhenTheStopIsSkipped() {
        let probe = MapDemo.model()
        let lead = probe.convoy.convoy.first?.convoyOffset ?? 0
        let (model, recorder, _) = demo([stop("s1", at: lead + 1_900)])
        model.setCars(model.cars)
        // 1.9 km minus what the lead has covered since its last fix (4 s at 96 km/h).
        #expect(recorder.alerts.map(\.spoken) == ["R&R Tapah in 1.8 km. Take the exit."])
        #expect(model.stopApproach?.eventId == "s1")
        model.setCars(model.cars)                                           // another fix
        #expect(recorder.alerts.count == 1)
        model.setStops([stop("s1", at: lead + 1_900, skipped: true)])
        model.setCars(model.cars)
        #expect(model.stopApproach == nil)
    }

    @Test func modelStaysQuietForAStopFarAheadOrBehindAndForATripWithNoStops() {
        let probe = MapDemo.model()
        let lead = probe.convoy.convoy.first?.convoyOffset ?? 0
        for stops in [[stop("far", at: lead + 9_000)], [stop("behind", at: lead - 3_000)], []] {
            let (model, recorder, _) = demo(stops)
            model.setCars(model.cars)
            #expect(recorder.alerts.isEmpty)
            #expect(model.stopApproach == nil)
        }
    }

    @Test func aStaleFixOfMyCarNeitherSpeaksNorShowsThePill() {
        let probe = MapDemo.model()
        let lead = probe.convoy.convoy.first?.convoyOffset ?? 0
        let (model, recorder, _) = demo([stop("s1", at: lead + 1_900)])
        // The demo's lead fix is 4 s old; make it 90 s old.
        let me = model.convoy.convoy[0]
        var old = me.position
        old.updatedAt = Date().addingTimeInterval(-90)
        model.apply(trip: nil, myCar: model.myCar, myCarId: model.myCarId, positions: ["c1": old], isTracker: true)
        model.setCars(model.cars)
        #expect(recorder.alerts.isEmpty)
        #expect(model.stopApproach == nil)
    }

    @Test func stopsAreKeptInRouteOrder() {
        let model = MapDemo.model()
        model.setStops([stop("b", at: 9_000), stop("a", at: 3_000)])
        #expect(model.stops.map(\.id) == ["a", "b"])
    }
}
