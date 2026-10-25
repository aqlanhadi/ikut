import CoreLocation
import Foundation
import Testing
@testable import ikut

/// The Suggest stops sheet's logic (SuggestStops.dc.html): the stepper and its default, the short trip, an existing
/// stop near the mark, and the 20 min stop Add hands to the planner.
@MainActor
@Suite("Suggest stops sheet")
struct SuggestStopsSheetTests {
    static let line = PlacesAlongTests.northbound
    /// 111 km in 2 h 25 min, like KL to Ipoh; the R&R at 3.5 is 55 km along, 72 min.
    static let seconds: Double = 8_700
    static let rows = PlaceSide.along(sites: [PlacesAlongTests.west], fuel: [], line: line)

    static func model(
        seconds: Double = seconds, existing: [Double] = [], candidates: [PlaceAlong]? = rows, line: RouteLine? = line
    ) -> SuggestStopsModel {
        SuggestStopsModel(line: line, routeSeconds: seconds, existing: existing, sites: [PlacesAlongTests.west], fuel: [],
                          candidates: candidates)
    }

    @Test func defaultIsTwoHoursOnALongTripAndHalfwayOnAShortOne() {
        #expect(SuggestAfter.defaultSeconds(routeSeconds: 5 * 3600) == 7_200)
        #expect(SuggestAfter.defaultSeconds(routeSeconds: 9_001) == 7_200)
        // 2 h 25 min: half is 72 min, rounded up to 1 h 30 min (the canvas's first frame).
        #expect(SuggestAfter.defaultSeconds(routeSeconds: 8_700) == 5_400)
        #expect(SuggestAfter.defaultSeconds(routeSeconds: 9_000) == 5_400)
        #expect(SuggestAfter.defaultSeconds(routeSeconds: 6_000) == 3_600)
        // Never under 1 h, whatever the trip.
        #expect(SuggestAfter.defaultSeconds(routeSeconds: 1_200) == 3_600)
    }

    @Test func stepperMovesInHalfHoursWithinOneToThreeHours() {
        #expect(SuggestAfter.stepped(5_400, by: 1) == 7_200)
        #expect(SuggestAfter.stepped(5_400, by: -1) == 3_600)
        #expect(SuggestAfter.stepped(3_600, by: -1) == 3_600)
        #expect(SuggestAfter.stepped(10_800, by: 1) == 10_800)
        #expect(!SuggestAfter.canStep(3_600, by: -1))
        #expect(!SuggestAfter.canStep(10_800, by: 1))
        #expect(SuggestAfter.canStep(3_600, by: 1))
        #expect(SuggestStopsModel.stepperText(5_400) == "Suggest after about 1 h 30 min")
        #expect(SuggestStopsModel.stepperText(7_200) == "Suggest after about 2 h")
    }

    @Test func halfwayDefaultPicksTheRnRNearHalfway() throws {
        let model = Self.model()
        #expect(model.after == 5_400)
        #expect(model.state == .ready)
        #expect(try #require(model.picks.first).place.id == PlacesAlongTests.west.id)
        model.step(1)
        #expect(model.after == 7_200)
        #expect(model.picks.map(\.place.id) == [PlacesAlongTests.west.id], "2 h is 48 min from the R&R: inside the window")
    }

    @Test func aTripUnderNinetyMinutesDrivesStraightThrough() {
        let model = Self.model(seconds: 3_000)
        #expect(model.state == .short)
        #expect(model.picks.isEmpty)
    }

    @Test func aStopAlreadyNearTheMarkIsItsBreak() throws {
        let offset = try #require(Self.rows.first?.routeOffset)
        let model = Self.model(existing: [offset])
        #expect(model.state == .nothing)
        #expect(model.picks.isEmpty)
    }

    @Test func noRouteOrNoPlacesCannotSuggestYet() {
        #expect(Self.model(line: nil).state == .cantSuggest)
        let none = SuggestStopsModel(line: Self.line, routeSeconds: Self.seconds, existing: [], sites: [], fuel: [])
        #expect(none.state == .cantSuggest)
    }

    @Test func loadingFindsTheRnR() async {
        let model = Self.model(candidates: nil)
        #expect(model.state == .loading)
        await model.load()
        #expect(model.state == .ready)
    }

    @Test func addHandsThePlannerATwentyMinuteRestAtTheGate() throws {
        let model = Self.model()
        let pick = try #require(model.picks.first)
        let draft = model.draft(for: pick)
        #expect(draft.kind == .rest)
        #expect(draft.minutes == 20)
        #expect(draft.coordinate.latitude == pick.place.entrance.latitude)
        #expect(draft.coordinate.longitude == pick.place.entrance.longitude)
        #expect(draft.name == "Test Rest Area North Bound")
        #expect(draft.routeOffset == pick.place.routeOffset)
        #expect(StopFormat.detail(draft) == "Rest · 20 min")
        #expect(!model.allAdded)
        model.markAdded(pick)
        #expect(model.allAdded)
    }

    @Test func theCardSaysHowFarAlongAndWhatItHas() throws {
        let model = Self.model()
        let pick = try #require(model.picks.first)
        #expect(SuggestStopsModel.along(pick).contains(" along · "))
        #expect(SuggestStopsModel.chips(pick.place) == ["Fuel", "Food", "Toilets", "EV charging"])
    }

    @Test func aSecondAddOfTheSamePickDoesNothing() throws {
        let model = Self.model()
        let pick = try #require(model.picks.first)
        var drafts: [StopDraft] = []
        for _ in 0..<2 where model.markAdded(pick) { drafts.append(model.draft(for: pick)) }
        #expect(drafts.count == 1)
    }

    @Test func existingOffsetsLeaveOutTheMeetingPointAndUnplacedStops() {
        let at = CLLocationCoordinate2D(latitude: 3.5, longitude: 101.5)
        let items = [
            StopDraft(name: "Meet", coordinate: at, kind: .meet, routeOffset: 0),
            StopDraft(name: "Rest", coordinate: at, kind: .rest, minutes: 20, routeOffset: 55_000),
            StopDraft(name: "New", coordinate: at, kind: .food),
        ]
        #expect(SuggestStopsModel.existingOffsets(items) == [55_000])
    }

    @Test func anRnRAddedInTheSheetCountsWhenTheTimeMoves() throws {
        let model = Self.model()
        let pick = try #require(model.picks.first)
        model.markAdded(pick)
        model.step(-1)
        #expect(model.picks.isEmpty)
        #expect(model.state == .nothing)
    }
}
