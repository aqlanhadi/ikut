import CoreLocation
import Foundation
import Observation

/// What Add a stop (B6) shows and does, apart from how it looks: the R&Rs along the trip's route in order (the same
/// pool as Suggest stops), which is selected, how long to stay, and the searched place that isn't an R&R.
enum AddStopLogic {
    /// One row of "R&R along the way, in order" and its pin on the map: the same number.
    struct Row: Identifiable {
        var id: String { place.id }
        var number: Int
        var place: PlaceAlong
        var name: String
        /// "About 20 min in".
        var line: String
        /// "fuel, food, toilets".
        var facilities: String
        var pinId: String { place.id }
        /// Already one of the trip's stops: shown dimmed and not selectable.
        var alreadyStop = false
    }

    /// How close (meters along the route) a stop must be to an R&R to count as that R&R.
    static let sameStop: Double = 500

    /// The R&Rs on our side of the route, nearest the start first, numbered from 1.
    /// `existing` are the route offsets of the stops already planned (`SuggestStopsModel.existingOffsets`): an R&R
    /// within `sameStop` of one is marked.
    static func rows(from places: [PlaceAlong], routeLength: Double?, routeSeconds: Double?, existing: [Double] = []) -> [Row] {
        var seen = Set<String>()
        let rnrs = places.filter { $0.ours && SuggestStops.isRnR($0) && seen.insert($0.id).inserted }
            .sorted { $0.routeOffset < $1.routeOffset }
        return rnrs.enumerated().map { index, place in
            Row(number: index + 1, place: place, name: RequestPlaces.name(place),
                line: about(offset: place.routeOffset, routeLength: routeLength, routeSeconds: routeSeconds),
                facilities: SuggestStops.facilityWords(place),
                alreadyStop: existing.contains { abs($0 - place.routeOffset) <= sameStop })
        }
    }

    /// "About 1 h 35 min in", or "62 km in" when the route's time isn't known: as the stop list words it.
    static func about(offset: Double, routeLength: Double?, routeSeconds: Double?) -> String {
        if let routeLength, routeLength > 0, let routeSeconds, routeSeconds > 0 {
            return "About \(ConvoyFormat.duration(routeSeconds * min(1, offset / routeLength))) in"
        }
        return "\(StopFormat.along(meters: offset)) in"
    }

    /// The row's second line: the selected one adds what the place has.
    static func detail(_ row: Row, selected: Bool) -> String {
        if row.alreadyStop { return "Already a stop" }
        return selected && !row.facilities.isEmpty ? "\(row.line) · \(row.facilities)" : row.line
    }

    /// The Stay stepper: the existing durations, one step at a time, held at both ends.
    static let stays = PlannedStop.allowedMinutes
    static let defaultStay = 20  // as Suggest stops adds an R&R (#324)
    static func stepped(_ minutes: Int, by direction: Int) -> Int {
        let index = stays.firstIndex(of: minutes) ?? stays.firstIndex(of: defaultStay) ?? 0
        return stays[max(0, min(stays.count - 1, index + direction))]
    }
    static func canStep(_ minutes: Int, by direction: Int) -> Bool { stepped(minutes, by: direction) != minutes }

    /// "Add Tapah R&R".
    static func addTitle(_ name: String) -> String { "Add \(name)" }

    /// The R&R as a stop: a Rest of `minutes` at the R&R's gate on our slip road (as Suggest stops adds it).
    static func draft(_ row: Row, minutes: Int) -> StopDraft {
        StopDraft(name: row.name, coordinate: row.place.entrance, kind: .rest, minutes: minutes, routeOffset: row.place.routeOffset)
    }

    /// The kinds a searched place can be: a meeting point only when it would be the first stop.
    static func kinds(canMeet: Bool) -> [PlannedStopKind] { (canMeet ? [.meet] : []) + [.fuel, .food, .rest, .toilet, .sight] }

    /// Meeting point: no stay, the time is optional. Any other kind: the stay is optional.
    static func searchedDraft(_ place: DestinationResult, kind: PlannedStopKind, minutes: Int?, meetClock: Date?, now: Date = Date(),
                              calendar: Calendar = .current) -> StopDraft {
        var meetAt: Date?
        if kind == .meet, let meetClock {
            let parts = calendar.dateComponents([.hour, .minute], from: meetClock)
            meetAt = StopFormat.nextTime(hour: parts.hour ?? 9, minute: parts.minute ?? 0, after: now)
        }
        return StopDraft(name: place.name, coordinate: place.coordinate, kind: kind,
                         minutes: kind == .meet ? nil : minutes, meetAt: meetAt)
    }
}

@MainActor @Observable
final class AddStopModel {
    private(set) var rows: [AddStopLogic.Row] = []
    private(set) var loading = true
    /// The R&R selected, on its row and its pin.
    private(set) var selectedId: String?
    private(set) var stay = AddStopLogic.defaultStay
    /// Meeting points are offered only for what would be the first stop.
    let canMeet: Bool
    let canAdd: Bool
    /// The search for a place that isn't an R&R; its results are ordered along the route.
    var search = CreateTripModel()
    /// A searched place, being given a kind and a stay.
    var picked: DestinationResult?
    var kind: PlannedStopKind = .fuel
    var searchedMinutes: Int?
    var meetClock: Date?

    private let line: RouteLine?
    private let routeSeconds: Double?
    private let sites: [PlaceSite]
    private let fuel: [FuelStation]
    private let existing: [Double]
    /// The draft was handed over: Add gives it once.
    private var handedOver = false

    init(line: RouteLine?, routeSeconds: Double?, along: AlongRoute?, canMeet: Bool, canAdd: Bool,
         sites: [PlaceSite] = OurSide.bundledSites, fuel: [FuelStation] = OurSide.bundledFile?.fuel ?? [],
         existing: [Double] = [], candidates: [PlaceAlong]? = nil) {
        self.existing = existing
        self.line = line
        self.routeSeconds = routeSeconds
        self.canMeet = canMeet
        self.canAdd = canAdd
        self.sites = sites
        self.fuel = fuel
        search.along = along
        if let candidates { apply(candidates) }
    }

    /// Looks through the places along the route, off the main thread.
    func load() async {
        guard loading else { return }
        guard let line, line.segmentCount > 0 else { loading = false; return }
        let sites = sites, fuel = fuel
        let found = await Task.detached(priority: .userInitiated) { PlaceSide.along(sites: sites, fuel: fuel, line: line) }.value
        apply(found)
    }

    private func apply(_ places: [PlaceAlong]) {
        rows = AddStopLogic.rows(from: places, routeLength: line?.length, routeSeconds: routeSeconds, existing: existing)
        loading = false
    }

    var selected: AddStopLogic.Row? { rows.first { $0.id == selectedId } }

    /// A tap on a row or on its pin. Another place keeps the current stay; an R&R that is already a stop can't be chosen.
    func select(_ id: String) {
        guard rows.contains(where: { $0.id == id && !$0.alreadyStop }), selectedId != id else { return }
        selectedId = id
    }

    func step(_ direction: Int) { stay = AddStopLogic.stepped(stay, by: direction) }

    /// "Add Tapah R&R", or the searched place's name; nil with nothing chosen.
    var addTitle: String? {
        if let picked { return AddStopLogic.addTitle(picked.name) }
        return selected.map { AddStopLogic.addTitle($0.name) }
    }

    /// A planned stop that is one of the listed R&Rs, which then has only its own (already-a-stop) pin.
    func covers(_ stop: StopDraft) -> Bool {
        guard let offset = stop.routeOffset else { return false }
        return rows.contains { $0.alreadyStop && abs($0.place.routeOffset - offset) <= AddStopLogic.sameStop }
    }

    /// The stop the Add button hands to the planner; nil with nothing chosen or when the list is full.
    var draft: StopDraft? {
        guard canAdd else { return nil }
        if let picked { return AddStopLogic.searchedDraft(picked, kind: kind, minutes: searchedMinutes, meetClock: meetClock) }
        return selected.map { AddStopLogic.draft($0, minutes: stay) }
    }

    /// The Add button's hand-over: the draft once, nil after that (a second tap adds nothing).
    func take() -> StopDraft? {
        guard !handedOver, let draft else { return nil }
        handedOver = true
        return draft
    }

    /// Back in the sheet: from a searched place's details to the list (true: the sheet stays), else out to the lobby
    /// (false), where nothing has changed.
    func back() -> Bool {
        guard picked != nil else { return false }
        picked = nil
        return true
    }

    func pick(_ result: DestinationResult) {
        picked = result
        kind = PlannedStopKind(guessing: result)
        searchedMinutes = nil
        meetClock = nil
    }

    /// What the pins on the map are: the rows' numbers, the selected one highlighted.
    var pins: [LobbyPin] {
        rows.map {
            LobbyPin(id: $0.pinId, kind: .candidate(number: $0.number, selected: $0.id == selectedId, taken: $0.alreadyStop), name: $0.name,
                     latitude: $0.place.coordinate.latitude, longitude: $0.place.coordinate.longitude)
        }
    }
}
