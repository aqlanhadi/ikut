import CoreLocation
import Foundation
import Testing
@testable import ikut

struct LobbyContentTests {
    private let utc = TimeZone(identifier: "UTC")!
    private func noon() -> Date { Date(timeIntervalSince1970: 12 * 3600) }

    private func car(_ name: String, tracker: String? = "u", route: String? = nil, merge: Double? = nil) -> LobbyCar {
        LobbyCar(car: Car(id: name, name: name, color: "#2563EB", trackerUserId: tracker, isLead: false,
                          route: route, mergeOffset: merge, state: .convoy, number: 1), members: [])
    }

    // MARK: Header

    @Test func theHeaderNamesTheTripUntilItStarts() {
        #expect(LobbyContent.headerTitle(tripName: "Balik kampung", started: false, ended: false) == "Balik kampung")
        #expect(LobbyContent.headerTitle(tripName: "Balik kampung", started: true, ended: false) == "Trip in progress")
        #expect(LobbyContent.headerTitle(tripName: "Balik kampung", started: false, ended: true) == "Trip ended")
    }

    @Test func theSubtitleHasTheMeetingTimeOnlyWhenThereIsOne() {
        #expect(LobbyContent.subtitle(destination: "Ipoh", meetAt: noon(), code: "K7M2QX", started: false, ended: false,
                                      startedAt: nil, timeZone: utc) == "To Ipoh · meet 12:00 · code K7M 2QX")
        #expect(LobbyContent.subtitle(destination: "Ipoh", meetAt: nil, code: "K7M2QX", started: false, ended: false,
                                      startedAt: nil, timeZone: utc) == "To Ipoh · code K7M 2QX")
    }

    @Test func afterTheStartTheSubtitleIsTheSinceLine() {
        let line = LobbyContent.subtitle(destination: "Ipoh", meetAt: noon(), code: "K7M2QX", started: true, ended: false,
                                         startedAt: noon(), locale: Locale(identifier: "en_US"), timeZone: utc)
        #expect(line == LobbyLogic.sinceLine(startedAt: noon(), locale: Locale(identifier: "en_US"), timeZone: utc))
        #expect(line?.hasPrefix("Since ") == true)
        #expect(LobbyContent.subtitle(destination: "Ipoh", meetAt: nil, code: "K7M2QX", started: true, ended: false,
                                      startedAt: nil) == nil)
        #expect(LobbyContent.subtitle(destination: "Ipoh", meetAt: nil, code: "K7M2QX", started: false, ended: true,
                                      startedAt: nil) == nil)
    }

    // MARK: Cars

    @Test func theCarsHeaderCountsTheCarsSharing() {
        let cars = [car("A"), car("B"), car("C", tracker: nil)]
        #expect(LobbyContent.carsHeader(cars) == "Cars · 2 of 3 ready")
        #expect(LobbyContent.carsHeader([]) == "Cars")
    }

    @Test func eachCarLineSaysWhatIsKnownOfIt() {
        let me = LobbyContent.carText(car("Aqlan’s Myvi"), mine: true, viewerLeavesFromTheStart: true)
        #expect(me.name == "Aqlan’s Myvi · You")
        #expect(me.line == "Ready · leaves from your start")
        #expect(me.trailing == "Ready")
        let withMe = LobbyContent.carText(car("Wyna’s X70", merge: 300), mine: false, viewerLeavesFromTheStart: true)
        #expect(withMe.name == "Wyna’s X70")
        #expect(withMe.line == "Leaves with you")
        // A participant who joins part-way doesn't leave with the cars that start at the front.
        #expect(LobbyContent.carText(car("Wyna’s X70", merge: 300), mine: false, viewerLeavesFromTheStart: false).line
            == "Leaves with the convoy")
        let joiner = car("Daniel’s City", route: Polyline.encode([.init(latitude: 3, longitude: 101), .init(latitude: 3.1, longitude: 101.1)]), merge: 35_000)
        #expect(LobbyContent.carText(joiner, mine: false, viewerLeavesFromTheStart: true).line == "Joins the convoy")
        // The slot for the join towns.
        #expect(LobbyContent.carText(joiner, mine: false, viewerLeavesFromTheStart: true, joinPlace: "Rawang").line == "Joins near Rawang")
        #expect(LobbyContent.carText(car("Hafiz’s Hilux", merge: 20_000), mine: false, viewerLeavesFromTheStart: true).line == "Joins the convoy")
        #expect(LobbyContent.carText(car("Aisha’s Vios"), mine: false, viewerLeavesFromTheStart: true).line == "Sharing location")
    }

    @Test func aCarWithNoPhoneSharingIsWaiting() {
        let siti = LobbyContent.carText(car("Siti’s Bezza", tracker: nil), mine: false, viewerLeavesFromTheStart: true)
        #expect(siti.line == "Not sharing location yet")
        #expect(siti.trailing == "Waiting")
        #expect(!siti.ready)
        // Even yours: nothing is "ready" before it shares.
        #expect(LobbyContent.carText(car("Mine", tracker: nil), mine: true, viewerLeavesFromTheStart: true).line == "Not sharing location yet")
    }

    // MARK: Above Start trip

    @Test func theWaitingLineAndTheConfirmFollowHowManyAreNotSharing() {
        let ready = [car("A"), car("B")]
        #expect(LobbyContent.waitingLine(ready) == nil)
        #expect(LobbyContent.startConfirm(ready) == nil)
        let one = ready + [car("Siti’s Bezza", tracker: nil)]
        #expect(LobbyContent.waitingLine(one) == "Waiting for Siti’s Bezza to share location. You can start anyway.")
        #expect(LobbyContent.startConfirm(one) == "Siti’s Bezza isn’t sharing yet")
        let two = one + [car("Faiz’s Alza", tracker: nil)]
        #expect(LobbyContent.waitingLine(two) == "Waiting for 2 cars to share location. You can start anyway.")
        #expect(LobbyContent.startConfirm(two) == "2 cars aren’t sharing yet")
    }

    // MARK: Stops

    private func stop(_ id: String, kind: PlannedStopKind, offset: Double?, minutes: Int? = nil, meetAt: Date? = nil) -> StopDraft {
        StopDraft(id: id, name: id, coordinate: .init(latitude: 4, longitude: 101), kind: kind, minutes: minutes, meetAt: meetAt, routeOffset: offset)
    }

    @Test func stopRowsReadLikeTheCanvasAndNumberLikeThePins() {
        let stops = [
            stop("Petronas", kind: .meet, offset: 0, meetAt: noon()),
            stop("Tapah", kind: .fuel, offset: 100_000, minutes: 20),
            stop("Gopeng", kind: .food, offset: 50_000),
        ]
        let texts = LobbyContent.stopTexts(stops, routeLength: 200_000, routeSeconds: 9_000, timeZone: utc)
        #expect(texts.map(\.number) == [nil, 1, 2])
        #expect(texts[0].detail == "Meeting point · meet 12:00")
        #expect(texts[1].detail == "About 1 h 15 min in · stay 20 min")
        #expect(texts[2].detail == "About 38 min in")
        // The same numbers the map's pins carry.
        let pins = LobbyMapLogic.pins(stops: stops, destinationName: nil, destination: nil, isOrganizer: true, ownJoin: nil)
        let pinNumbers = pins.compactMap { pin -> Int? in if case .stop(let n) = pin.kind { n } else { nil } }
        #expect(pinNumbers == texts.compactMap(\.number))
    }

    @Test func aStopWithoutTheRoutesTimeSaysHowFarAlongItIs() {
        let texts = LobbyContent.stopTexts([stop("Tapah", kind: .rest, offset: 62_000, minutes: 15)], routeLength: nil, routeSeconds: nil)
        #expect(texts[0].detail == "\(StopFormat.along(meters: 62_000)) in · stay 15 min")
        let bare = LobbyContent.stopTexts([stop("X", kind: .food, offset: nil), stop("Y", kind: .meet, offset: nil)], routeLength: 1, routeSeconds: 1)
        #expect(bare[0].detail == "Food")
        #expect(bare[1].detail == "Meeting point")
    }

    @Test func theSuggestCaptionIsTheDefaultFirstBreak() {
        #expect(LobbyContent.suggestCaption(routeSeconds: 2 * 3600 + 25 * 60) == "After about 1 h 30 min")
        #expect(LobbyContent.suggestCaption(routeSeconds: nil) == nil)
    }

    // MARK: Who gets which rows

    @Test func theOrganiserEditsBeforeTheStartAndAParticipantOnlyReads() {
        let organiser = LobbyContent.rows(isOrganizer: true, started: false, ended: false, isLiveMember: true, trackingOrPaused: true)
        #expect(organiser == .init(canRename: true, canChangeDestination: true, canEditStops: true, canPause: true,
                                   canLeave: false, canEnd: true, ownWay: false))
        let participant = LobbyContent.rows(isOrganizer: false, started: false, ended: false, isLiveMember: true, trackingOrPaused: false)
        #expect(participant == .init(canRename: false, canChangeDestination: false, canEditStops: false, canPause: false,
                                     canLeave: true, canEnd: false, ownWay: true))
    }

    @Test func afterTheStartTheStopsAreFixedAndTheOrganiserCanLeave() {
        let started = LobbyContent.rows(isOrganizer: true, started: true, ended: false, isLiveMember: true, trackingOrPaused: false)
        #expect(!started.canEditStops && started.canChangeDestination && started.canLeave && started.canEnd)
        let ended = LobbyContent.rows(isOrganizer: true, started: true, ended: true, isLiveMember: false, trackingOrPaused: true)
        #expect(!ended.canEnd && !ended.canLeave && !ended.canPause && !ended.canRename)
    }
}

// MARK: Join towns (D50 piece 3)

@MainActor
struct JoinTownsTests {
    /// A straight main route about 111 km long, due north.
    private let main = RouteLine([
        CLLocationCoordinate2D(latitude: 3.0, longitude: 101.0), CLLocationCoordinate2D(latitude: 4.0, longitude: 101.0)])
    private func car(_ id: String, tracker: String? = "u", merge: Double? = nil, route: String? = nil) -> LobbyCar {
        LobbyCar(car: Car(id: id, name: id, color: "#2563EB", trackerUserId: tracker, isLead: false,
                          route: route, mergeOffset: merge, state: .convoy, number: 1), members: [])
    }
    private func joins(_ cars: [LobbyCar], meeting: Bool = false) -> [String: LobbyContent.CarJoin] {
        Dictionary(cars.map {
            ($0.car.id!, LobbyContent.carJoin(of: $0.car, main: main, hasMeetingPoint: meeting))
        }, uniquingKeysWith: { _, last in last })
    }
    private func ask(_ towns: JoinTowns, _ cars: [LobbyCar], meeting: Bool = false) async {
        towns.request(cars: cars, joins: joins(cars, meeting: meeting), main: main)
        await towns.settle()
    }

    /// A fake geocoder: records each lookup, answers with `answers` in order (nil for a failure), and notes the most
    /// lookups it had in flight at once.
    @MainActor final class Fake {
        var calls: [CLLocationCoordinate2D] = []
        var inFlight = 0
        var most = 0
        var answers: [String?]
        init(_ answers: [String?]) { self.answers = answers }
        func place(_ c: CLLocationCoordinate2D) async -> String? {
            calls.append(c)
            inFlight += 1
            most = max(most, inFlight)
            await Task.yield()
            inFlight -= 1
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }

    private func towns(_ fake: Fake) -> JoinTowns { JoinTowns(place: { await fake.place($0) }, pause: .milliseconds(1)) }

    @Test func aCarJoiningAlongTheWayReadsJoinsNearItsTown() async {
        let fake = Fake(["Rawang"])
        let towns = towns(fake)
        let joiner = car("Wyna", merge: 50_000)
        await ask(towns, [joiner])
        let join = LobbyContent.join(of: joiner.car, main: main, hasMeetingPoint: false)
        let place = towns.town(carId: "Wyna", join: join, mainLength: main.length)
        #expect(place == "Rawang")
        #expect(LobbyContent.carText(joiner, mine: false, viewerLeavesFromTheStart: true, joinPlace: place, join: join).line
            == "Joins near Rawang")
        #expect(abs(fake.calls[0].latitude - 3.45) < 0.01)
    }

    @Test func aFailedLookupKeepsJoinsTheConvoyAndIsAskedOnceMoreOnALaterOpenOnly() async {
        let fake = Fake([nil, nil, "Rawang"])
        let towns = towns(fake)
        let joiner = car("Wyna", merge: 50_000)
        await ask(towns, [joiner])
        await ask(towns, [joiner])
        let join = LobbyContent.join(of: joiner.car, main: main, hasMeetingPoint: false)
        #expect(towns.town(carId: "Wyna", join: join, mainLength: main.length) == nil)
        #expect(LobbyContent.carText(joiner, mine: false, viewerLeavesFromTheStart: true, join: join).line == "Joins the convoy")
        #expect(fake.calls.count == 1)
        towns.open()
        await ask(towns, [joiner])
        #expect(fake.calls.count == 2)
        // Twice is all a car's offset gets, even on yet another open.
        towns.open()
        await ask(towns, [joiner])
        #expect(fake.calls.count == 2)
    }

    @Test func oneLookupPerCarAndOffsetThenTheCacheAnswers() async {
        let fake = Fake(["Rawang", "Tapah", "Bidor"])
        let towns = towns(fake)
        let a = car("A", merge: 50_000)
        await ask(towns, [a])
        await ask(towns, [a, a])
        #expect(fake.calls.count == 1)
        var moved = a
        moved.car.mergeOffset = 60_000
        await ask(towns, [moved, car("B", merge: 50_000)])
        #expect(fake.calls.count == 3)
    }

    @Test func theTownsOfATripSurviveReopeningItsLobby() async {
        JoinTowns.forgetAll()
        #expect(JoinTowns.shared(for: "t1") === JoinTowns.shared(for: "t1"))
        #expect(JoinTowns.shared(for: "t1") !== JoinTowns.shared(for: "t2"))
        JoinTowns.forgetAll()
    }

    @Test func carsThatStartWithTheConvoyOrAreNotSharingAreNeverLookedUp() async {
        let fake = Fake(["x", "y", "z"])
        let towns = towns(fake)
        let startsWith = car("A", merge: 100)
        await ask(towns, [startsWith, car("B", tracker: nil, merge: 50_000), car("C")])
        #expect(fake.calls.isEmpty)
        #expect(LobbyContent.carText(startsWith, mine: false, viewerLeavesFromTheStart: true).line == "Leaves with you")
        #expect(LobbyContent.carText(car("Aqlan"), mine: true, viewerLeavesFromTheStart: true).line == "Ready · leaves from your start")
    }

    private var farRoute: String {
        Polyline.encode([
            CLLocationCoordinate2D(latitude: 3.0, longitude: 102.0), CLLocationCoordinate2D(latitude: 4.0, longitude: 102.0)])
    }

    @Test func aCarWhoseRouteNeverMeetsTheMainOneMeetsAtTheDestination() {
        let lone = car("Siti", route: farRoute)
        let join = LobbyContent.join(of: lone.car, main: main, hasMeetingPoint: false)
        #expect(join == .meetsAtDestination)
        #expect(LobbyContent.carText(lone, mine: false, viewerLeavesFromTheStart: true, join: join, destination: "Ipoh").line
            == "Meets you at Ipoh")
        #expect(LobbyContent.carText(lone, mine: false, viewerLeavesFromTheStart: false, join: join, destination: "Ipoh").line
            == "Meets the convoy at Ipoh")
        #expect(JoinTowns.joinOffset(join, length: main.length) == nil)
    }

    @Test func aCarDrivingToTheMeetingPointMeetsYouThereWithNoLookup() async {
        // Its own road ends at the main route's start, as a route to the meeting point does.
        let own = Polyline.encode([
            CLLocationCoordinate2D(latitude: 2.9, longitude: 101.0), CLLocationCoordinate2D(latitude: 3.0, longitude: 101.0)])
        let driver = car("Wyna", route: own)
        let found = LobbyContent.carJoin(of: driver.car, main: main, hasMeetingPoint: true)
        #expect(found.meetsAtMeeting)
        let text = LobbyContent.carText(driver, mine: false, viewerLeavesFromTheStart: true, join: found.join, meeting: "Petronas Jalan Duta")
        #expect(text.line == "Meets you at Petronas Jalan Duta")
        #expect(LobbyContent.carText(driver, mine: false, viewerLeavesFromTheStart: false, join: found.join, meeting: "Petronas Jalan Duta").line
            == "Meets the convoy at Petronas Jalan Duta")
        let fake = Fake(["x"])
        await ask(towns(fake), [driver], meeting: true)
        #expect(fake.calls.isEmpty)
    }

    @Test func anOffsetThatIsNotANumberOrHugeNeverCrashesAndIsClamped() async {
        for bad in [Double.nan, .infinity, -.infinity, 1e300, -1e300] {
            let wild = car("W", merge: bad)
            #expect(LobbyContent.join(of: wild.car, main: main, hasMeetingPoint: false) != .meetsAtDestination)
            let withRoute = car("R", merge: bad, route: farRoute)
            _ = LobbyContent.carJoin(of: withRoute.car, main: main, hasMeetingPoint: false)
            let fake = Fake(["Somewhere"])
            let towns = towns(fake)
            await ask(towns, [wild, withRoute])
            #expect(fake.calls.count <= 1)
            #expect(JoinTowns.key(carId: "W", offset: 1e300).hasPrefix("W|"))
        }
        // Not a number: nothing to look up. Huge: the end of the route.
        #expect(JoinTowns.joinOffset(.merges(offset: .nan), length: 1000) == nil)
        #expect(JoinTowns.joinOffset(.onRoute(offset: .infinity), length: 5000) == nil)
        #expect(JoinTowns.joinOffset(.onRoute(offset: 1e300), length: 5000) == 5000)
        #expect(JoinTowns.joinOffset(.onRoute(offset: -.infinity), length: 5000) == nil)
    }

    @Test func cancellingStopsTheLookupsAndALaterRequestAsksAgain() async {
        let fake = Fake(["A", "B", "C", "A2", "B2", "C2"])
        let towns = JoinTowns(place: { await fake.place($0) }, pause: .seconds(30))
        let cars = (1...3).map { car("C\($0)", merge: Double($0) * 10_000) }
        towns.request(cars: cars, joins: joins(cars), main: main)
        while fake.calls.isEmpty { await Task.yield() }
        towns.cancel()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fake.calls.count == 1)
        // Nothing was answered for the queued cars (or the one in flight), so a new request asks for all of them.
        towns.request(cars: cars, joins: joins(cars), main: main)
        while fake.calls.count < 2 { await Task.yield() }
        towns.cancel()
        #expect(fake.calls.count >= 2)
    }

    @Test func lookupsRunOneAtATime() async {
        let fake = Fake(["A", "B", "C", "D"])
        let towns = towns(fake)
        let cars = (1...4).map { car("C\($0)", merge: Double($0) * 10_000) }
        towns.request(cars: cars, joins: joins(cars), main: main)
        towns.request(cars: cars, joins: joins(cars), main: main)
        await towns.settle()
        #expect(fake.calls.count == 4)
        #expect(fake.most == 1)
    }
}
