import CoreLocation
import Foundation
import Testing
@testable import ikut

/// Add a stop over the map (B6): the R&R list and its pins, selection, Stay, the Add button, gating.
@MainActor
struct AddStopTests {
    private func place(_ id: String, _ name: String, offset: Double, ours: Bool = true, kind: PlaceAlong.Kind = .services,
                       facilities: Set<PlaceFacility> = [.fuel, .food, .toilets]) -> PlaceAlong {
        let at = CLLocationCoordinate2D(latitude: 3 + offset / 100_000, longitude: 101.3)
        return PlaceAlong(
            id: id, kind: kind, name: name, coordinate: at, ring: nil, facilities: facilities, brands: [], offset: offset,
            distance: 40, side: .left, carriageway: ours ? .ours : .opposite, ours: ours,
            // The gate on our slip road, a few hundred metres off the R&R's middle.
            entrance: .init(latitude: at.latitude + 0.003, longitude: at.longitude + 0.002), slipEntrance: false,
            routeOffset: offset)
    }

    /// 200 km in 2 h 40 min, so 1 km is 48 s.
    private let length = 200_000.0, seconds = 9_600.0

    private var places: [PlaceAlong] {
        [place("c", "Tapah R&R", offset: 95_000), place("a", "Sungai Buloh R&R", offset: 25_000),
         place("x", "Behrang R&R (southbound)", offset: 70_000, ours: false), place("lay", "Hentian Sebelah Bikam", offset: 60_000),
         place("pump", "Petronas", offset: 50_000, kind: .fuel), place("b", "Behrang R&R", offset: 80_000)]
    }

    private func model(canMeet: Bool = false, canAdd: Bool = true) -> AddStopModel {
        AddStopModel(line: nil, routeSeconds: seconds, along: nil, canMeet: canMeet, canAdd: canAdd, candidates: places)
    }

    // MARK: The list and its pins

    @Test func theListIsOurSideR_Rs_inOrderNumberedFromOne() {
        let rows = AddStopLogic.rows(from: places, routeLength: length, routeSeconds: seconds)
        #expect(rows.map(\.name) == ["Sungai Buloh R&R", "Behrang R&R", "Tapah R&R"])
        #expect(rows.map(\.number) == [1, 2, 3])
    }

    @Test func thePinsCarryTheRowsNumbersAndIds() {
        let model = AddStopModel(line: RouteLine([.init(latitude: 3, longitude: 101.3), .init(latitude: 4, longitude: 101.3)]),
                                 routeSeconds: seconds, along: nil, canMeet: false, canAdd: true, candidates: places)
        #expect(model.pins.map(\.id) == model.rows.map(\.id))
        #expect(model.pins.map(\.kind) == [.candidate(number: 1, selected: false, taken: false), .candidate(number: 2, selected: false, taken: false),
                                            .candidate(number: 3, selected: false, taken: false)])
        model.select("c")
        #expect(model.pins.map(\.kind) == [.candidate(number: 1, selected: false, taken: false), .candidate(number: 2, selected: false, taken: false),
                                            .candidate(number: 3, selected: true, taken: false)])
    }

    @Test func theMinutesInLinesAreAboutHowFarIntoTheDrive() {
        let rows = AddStopLogic.rows(from: places, routeLength: length, routeSeconds: seconds)
        #expect(rows.map(\.line) == ["About 20 min in", "About 1 h 4 min in", "About 1 h 16 min in"])
        // Without the route's time, the distance says it.
        #expect(AddStopLogic.about(offset: 62_000, routeLength: nil, routeSeconds: nil) == "62 km in")
    }

    @Test func theSelectedRowAddsWhatThePlaceHas() {
        let rows = AddStopLogic.rows(from: places, routeLength: length, routeSeconds: seconds)
        #expect(AddStopLogic.detail(rows[2], selected: false) == "About 1 h 16 min in")
        #expect(AddStopLogic.detail(rows[2], selected: true) == "About 1 h 16 min in · fuel, food, toilets")
    }

    // MARK: Selection

    @Test func selectingMovesBetweenRowsAndPinsAndIgnoresUnknownIds() {
        let model = model()
        #expect(model.selected == nil && model.addTitle == nil && model.draft == nil)
        model.select("a")
        #expect(model.selected?.number == 1)
        model.select("c")
        #expect(model.selected?.number == 3)
        model.select("nope")
        #expect(model.selectedId == "c")
    }

    @Test func theCameraGoesToTheSelectedR_R() throws {
        let model = AddStopModel(line: nil, routeSeconds: seconds, along: nil, canMeet: false, canAdd: true, candidates: places)
        model.select("c")
        let target = LobbyMapTarget.stop(try #require(model.selectedId))
        let route = [CLLocationCoordinate2D(latitude: 3, longitude: 101.3), .init(latitude: 4, longitude: 101.3)]
        let region = try #require(LobbyMapLogic.region(for: target, route: route, pins: model.pins, bottomObscured: 0, topObscured: 0.2))
        let pin = try #require(model.pins.first { $0.id == "c" })
        #expect(region.span.latitudeDelta == LobbyMapLogic.stopSpan)
        #expect(region.center.longitude == pin.longitude)
        // The pin sits below the middle of the view, clear of the status bar's band at the top.
        #expect(region.center.latitude > pin.latitude)
    }

    @Test func anR_RAlreadyAStopIsMarkedAndCannotBeChosen() throws {
        let existing = SuggestStopsModel.existingOffsets([StopDraft(
            name: "Tapah R&R", coordinate: .init(latitude: 3.95, longitude: 101.3), kind: .rest, minutes: 20, routeOffset: 95_100)])
        let model = AddStopModel(line: nil, routeSeconds: seconds, along: nil, canMeet: false, canAdd: true, existing: existing, candidates: places)
        #expect(model.rows.map(\.alreadyStop) == [false, false, true])
        #expect(AddStopLogic.detail(model.rows[2], selected: false) == "Already a stop")
        model.select("c")
        #expect(model.selected == nil && model.draft == nil)
        #expect(model.pins.last?.kind == .candidate(number: 3, selected: false, taken: true))
        model.select("b")
        #expect(model.selected?.number == 2)
        // The planned stop's own pin is left out, since the R&R's pin stands for it.
        let stop = StopDraft(name: "Tapah R&R", coordinate: .init(latitude: 3.95, longitude: 101.3), kind: .rest, routeOffset: 95_100)
        let other = StopDraft(name: "Kopitiam", coordinate: .init(latitude: 3.5, longitude: 101.3), kind: .food, routeOffset: 10_000)
        let pins = LobbyMapLogic.pins(stops: [stop, other], destinationName: nil, destination: nil, isOrganizer: true, ownJoin: nil,
                                      coveredByCandidate: { model.covers($0) })
        #expect(pins.map(\.name) == ["Kopitiam"] && pins.first?.kind == .plannedStop)
    }

    @Test func addHandsTheDraftOverOnce() {
        let model = model()
        #expect(model.take() == nil)
        model.select("c")
        #expect(model.take()?.name == "Tapah R&R")
        #expect(model.take() == nil)
    }

    @Test func choosingAnotherR_RKeepsTheStay() {
        let model = model()
        model.select("a")
        model.step(1)
        model.select("c")
        #expect(model.stay == 30)
    }

    // MARK: Stay

    @Test func stayStartsAtTwentyAndStepsThroughTheExistingDurationsHeldAtTheEnds() {
        let model = model()
        #expect(model.stay == 20)
        model.step(1); #expect(model.stay == 30)
        model.step(1); #expect(model.stay == 60)
        model.step(1); #expect(model.stay == 60)
        #expect(!AddStopLogic.canStep(60, by: 1) && AddStopLogic.canStep(60, by: -1))
        model.step(-1); model.step(-1); model.step(-1); model.step(-1)
        #expect(model.stay == 10)
        #expect(!AddStopLogic.canStep(10, by: -1))
        #expect(Set(AddStopLogic.stays) == Set(PlannedStop.allowedMinutes))
    }

    // MARK: Add

    @Test func theAddButtonNamesThePlaceAndHandsOverARestWithTheStay() throws {
        let model = model()
        model.select("c")
        model.step(1)
        #expect(model.addTitle == "Add Tapah R&R")
        let draft = try #require(model.draft)
        #expect(draft.name == "Tapah R&R" && draft.kind == .rest && draft.minutes == 30 && draft.routeOffset == 95_000)
        // It goes in by our slip road, not the R&R's middle.
        let tapah = try #require(places.first { $0.id == "c" })
        #expect(draft.coordinate.latitude == tapah.entrance.latitude && draft.coordinate.longitude == tapah.entrance.longitude)
        #expect(draft.latitude != tapah.coordinate.latitude)
    }

    @Test func aFullListCannotAdd() {
        let model = model(canAdd: false)
        model.select("c")
        #expect(model.addTitle == "Add Tapah R&R")
        #expect(model.draft == nil)
        #expect(!StopListLogic.canAdd(among: (0..<PlannedStop.maxCount).map { StopDraft(name: "\($0)", coordinate: .init(latitude: 3, longitude: 101), kind: .fuel) }))
    }

    @Test func aMeetingPointIsOfferedOnlyForTheFirstStop() {
        #expect(AddStopLogic.kinds(canMeet: true) == [.meet, .fuel, .food, .rest, .toilet, .sight])
        #expect(AddStopLogic.kinds(canMeet: false) == [.fuel, .food, .rest, .toilet, .sight])
        #expect(StopListLogic.canMeet(among: []))
        #expect(!StopListLogic.canMeet(among: [StopDraft(name: "a", coordinate: .init(latitude: 3, longitude: 101), kind: .fuel)]))
    }

    // MARK: A searched place

    private let searched = DestinationResult(name: "Petronas Sungai Buloh", subtitle: "Selangor", coordinate: .init(latitude: 3.2, longitude: 101.58))

    @Test func aSearchedPlaceKeepsItsKindStayAndMeetTime() throws {
        let model = model(canMeet: true)
        model.pick(searched)
        #expect(model.addTitle == "Add Petronas Sungai Buloh")
        model.kind = .food
        model.searchedMinutes = 30
        let food = try #require(model.draft)
        #expect(food.kind == .food && food.minutes == 30)
        model.kind = .meet
        model.searchedMinutes = 30
        model.meetClock = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())
        let meet = try #require(model.draft)
        #expect(meet.isMeeting && meet.minutes == nil && meet.meetAt != nil)
    }

    // MARK: Back

    @Test func backFromASearchedPlaceGoesToTheListAndBackFromTheListLeaves() {
        let model = model()
        model.select("a")
        model.pick(searched)
        #expect(model.back())
        #expect(model.picked == nil)
        // Leaving hands nothing over: only Add returns a draft, so the lobby's stops are as they were.
        #expect(!model.back())
    }
}
