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
