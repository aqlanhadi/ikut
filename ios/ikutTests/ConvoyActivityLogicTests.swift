import Foundation
import Testing
@testable import ikut

@Suite("Live Activity state")
struct ConvoyActivityLogicTests {
    typealias Input = ConvoyActivityInput
    typealias Kind = ConvoyActivityAttributes.Kind
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Aqlan in car 2, between Aisha (ahead 1.8 km) and Daniel (2.8 km behind); Wyna last. A stop 9 km ahead.
    func convoy() -> Input {
        var i = Input(now: now, tripName: "Balik kampung raya", destination: "Ipoh")
        i.myOffset = 50_000
        i.dots = [
            .init(name: "Aisha", color: "#D9480F", offset: 51_800, gapAhead: nil),
            .init(name: "Aqlan", color: "#2563EB", offset: 50_000, gapAhead: 1_800, isMine: true),
            .init(name: "Daniel", color: "#7C3AED", offset: 47_200, gapAhead: 2_800),
            .init(name: "Wyna", color: "#0D9488", offset: 44_000, gapAhead: 3_200),
        ]
        i.destinationMeters = 63_000
        i.destinationSeconds = 41 * 60
        i.spreadMeters = 6_800
        i.carCount = 4
        i.readyCars = 3
        i.newestOtherData = now.addingTimeInterval(-10)
        i.nextStop = .init(name: "R&R Tapah", offset: 59_000, meters: 9_000, seconds: 12 * 60, isHere: false)
        return i
    }

    func request(owes: Bool, since: TimeInterval = 0, asked: Bool = false, said: Bool = false) -> Input.Request {
        .init(requesterName: "Wyna", reason: .fuel, meters: -5_000, okCount: 2, total: 4, iSaidOK: said, iAsked: asked,
              owesMyAnswer: owes, since: now.addingTimeInterval(-since))
    }

    func kind(_ i: Input) -> Kind { ConvoyActivityLogic.kind(i) }

    // MARK: The order of note 4

    @Test func everyStateWinsOverTheOnesBelowIt() {
        var i = convoy()
        #expect(kind(i) == .inConvoy)

        i.parkedAhead = .init(name: "Aisha", meters: 24_000)
        #expect(kind(i) == .parkedAhead)
        i.nextStop?.isHere = true
        #expect(kind(i) == .atStop)
        i.convoyStopSince = now.addingTimeInterval(-600)
        #expect(kind(i) == .stopped)
        i.headsUp = .init(name: "Aisha", meters: 3_300, seconds: 120)
        #expect(kind(i) == .catchUp)
        i.request = request(owes: true)
        #expect(kind(i) == .stopRequest)
        i.hazard = .init(label: "Debris", reporter: "Wyna", meters: 350, offset: 50_350)
        #expect(kind(i) == .hazardAhead)
        i.pausedUntil = now.addingTimeInterval(23 * 60)
        #expect(kind(i) == .sharingPaused)
        i.tripEnded = true
        #expect(kind(i) == .tripEnded)
        i.arrived = .init(count: 3, total: 4, driveSeconds: 9_660)
        #expect(kind(i) == .arrived)
    }

    @Test func waitingAndJoiningAreBaseStates() {
        var i = convoy()
        i.tripStarted = false
        #expect(kind(i) == .waiting)
        i.tripStarted = true
        i.myOffset = nil
        i.dots = []
        i.joining = .init(place: "Rawang", meetsAtDestination: false, amount: .distance(14_000))
        #expect(kind(i) == .joining)
        // A planned stop's "here" still outranks the base state; a stop request does too.
        i.request = request(owes: true)
        #expect(kind(i) == .stopRequest)
    }

    @Test func aStopRequestOwnsTheActivityForTwoMinutesOnly() {
        var i = convoy()
        i.request = request(owes: true, since: 60)
        #expect(kind(i) == .stopRequest)
        i.request = request(owes: true, since: 121)
        #expect(kind(i) == .inConvoy)
        // Ignored for two minutes: nothing about it stays on the Lock Screen (the app still asks).
        #expect(ConvoyActivityLogic.state(i).state.requesterName == nil)
        // After my OK the line takes the slot, and the state goes straight back.
        i.request = request(owes: false, said: true)
        let s = ConvoyActivityLogic.state(i).state
        #expect(s.kind == .inConvoy)
        #expect(s.requesterName == "Wyna" && s.iSaidOK && s.okCount == 2 && s.okTotal == 4)
        i.request = request(owes: false, asked: true)
        #expect(ConvoyActivityLogic.state(i).state.iAsked)
    }

    // MARK: Big value

    @Test func bigValueIsTheNextStopsTimeWhileOneIsAhead() {
        let s = ConvoyActivityLogic.state(convoy()).state
        #expect(s.stopName == "R&R Tapah" && s.stopSeconds == 720 && s.stopMeters == 9_000)
        // The destination's time is never carried while a stop is ahead; its distance is (the subtitle).
        #expect(s.destinationSeconds == nil && s.destinationMeters == 63_000)
        #expect(ConvoyActivityPresentation.trailing(s, now: now) == .value("12m", .ring))
    }

    @Test func lastLegShowsTheDestinationsTime() {
        var i = convoy()
        i.nextStop = nil
        let s = ConvoyActivityLogic.state(i).state
        #expect(s.stopName == nil && s.destinationSeconds == 2_460 && s.destinationMeters == 63_000)
        #expect(s.stopRing == nil)
        #expect(ConvoyActivityPresentation.trailing(s, now: now) == .value("41m", .flag))
    }

    // MARK: Gaps, spread, track

    @Test func gapLineHasOneFormBothWaysAndDropsTheEnds() {
        var s = ConvoyActivityLogic.state(convoy()).state
        #expect(s.aheadName == "Aisha" && s.aheadMeters == 1_800)
        #expect(s.behindName == "Daniel" && s.behindMeters == 2_800)
        #expect(s.spreadMeters == 6_800)

        var lead = convoy()
        lead.dots = Array(lead.dots.enumerated().map { n, d in
            var d = d
            d.isMine = n == 0
            return d
        })
        lead.myOffset = lead.dots[0].offset
        s = ConvoyActivityLogic.state(lead).state
        #expect(s.aheadName == nil && s.behindName == "Aqlan")

        var last = convoy()
        last.dots = last.dots.enumerated().map { n, d in
            var d = d
            d.isMine = n == 3
            return d
        }
        last.myOffset = last.dots[3].offset
        s = ConvoyActivityLogic.state(last).state
        #expect(s.aheadName == "Daniel" && s.behindName == nil)
    }

    @Test func trackWindowIsTenKilometresAndLeavesFarCarsOff() {
        var i = convoy()
        i.dots.append(.init(name: "Hafiz", color: "#000000", offset: 30_000, gapAhead: 14_000))  // 20 km behind: out
        let s = ConvoyActivityLogic.state(i).state
        #expect(s.cars.count == 4)
        #expect(s.cars.first { $0.isMine }?.at == 0.5)
        // Aisha 1.8 km ahead = 9% right of the middle; 1 km = 5%.
        #expect(s.cars.map(\.at).contains(0.59))
        // The stop's ring, 9 km ahead.
        #expect(s.stopRing == 0.95)
        // A stop 12 km ahead is outside the window: no ring.
        i.nextStop?.offset = 62_000
        #expect(ConvoyActivityLogic.state(i).state.stopRing == nil)
    }

    @Test func hazardNarrowsTheWindowAndRoundsTo50Metres() {
        var i = convoy()
        i.hazard = .init(label: "Debris", reporter: "Wyna", meters: 362, offset: 50_362)
        let s = ConvoyActivityLogic.state(i).state
        #expect(s.hazardMeters == 350)
        // 350 m ahead on a 1 km window: 50% + 17.5%.
        #expect(s.hazardMark == 0.68)
        // Aisha is 1.8 km ahead: outside the 1 km window.
        #expect(s.cars.count == 1)
        // No fresh fix: no metres, and the label stays.
        i.hazard?.meters = nil
        let none = ConvoyActivityLogic.state(i).state
        #expect(none.hazardMeters == nil && none.hazardLabel == "Debris")
        #expect(ConvoyActivityPresentation.trailing(none, now: now) == .nothing)
        // A hazard beyond the window stays on the edge.
        i.hazard?.offset = 55_000
        #expect(ConvoyActivityLogic.state(i).state.hazardMark == 1)
    }

    // MARK: At a stop, stopped, paused

    @Test func atAStopCarriesTheCountAndTheTimes() {
        var i = convoy()
        i.nextStop = .init(name: "R&R Tapah", offset: 50_050, meters: 0, seconds: nil, isHere: true)
        let leave = now.addingTimeInterval(12 * 60)
        i.stopHere = .init(here: 3, total: 4, leaveAt: leave, arriveAt: leave.addingTimeInterval(29 * 60))
        let s = ConvoyActivityLogic.state(i).state
        #expect(s.kind == .atStop && s.stopName == "R&R Tapah" && s.hereCount == 3 && s.hereTotal == 4)
        #expect(s.leaveAt == leave && s.arriveAt == leave.addingTimeInterval(1_740))
        // No ring on the track at a stop: the card says where the car is.
        #expect(s.stopRing == nil)
        #expect(ConvoyActivityPresentation.trailing(s, now: now) == .value("3/4", .ring))
    }

    @Test func stoppedWinsOverAtAStopAndNamesTheStop() {
        var i = convoy()
        i.nextStop = .init(name: "R&R Tapah", offset: 50_050, meters: 0, seconds: nil, isHere: true)
        i.convoyStopSince = now.addingTimeInterval(-12 * 60)
        i.mayEndConvoyStop = true
        let s = ConvoyActivityLogic.state(i).state
        #expect(s.kind == .stopped && s.stopName == "R&R Tapah" && s.mayEndStop)
        #expect(ConvoyActivityPresentation.trailing(s, now: now) == .value("12m", .none))
        i.nextStop = convoy().nextStop
        #expect(ConvoyActivityLogic.state(i).state.stopName == nil)
    }

    @Test func pausedStateGoesStaleAtThePausesEnd() {
        var i = convoy()
        i.pausedUntil = now.addingTimeInterval(23 * 60)
        let (s, stale) = ConvoyActivityLogic.state(i)
        #expect(s.kind == .sharingPaused && stale == i.pausedUntil)
        #expect(ConvoyActivityPresentation.trailing(s, now: now) == .value("23m", .none))
    }

    // MARK: Stale date

    @Test func staleDateIsTheNewestOtherCarsDataPlusTwoMinutes() {
        var i = convoy()
        i.newestOtherData = now.addingTimeInterval(-45)
        #expect(ConvoyActivityLogic.state(i).staleDate == now.addingTimeInterval(75))
        // Not this phone's own sends: nothing in the input but the others' data moves it.
        i.now = now.addingTimeInterval(30)
        #expect(ConvoyActivityLogic.state(i).staleDate == now.addingTimeInterval(75))
        // With no other car's data yet (alone, the lobby): two minutes from this update.
        i.newestOtherData = nil
        #expect(ConvoyActivityLogic.state(i).staleDate == i.now.addingTimeInterval(120))
        #expect(ConvoyActivityLogic.state(i).state.dataAt == i.now)
    }

    @Test func finalStatesHaveNoStaleDateAndAreNeverGreyed() {
        var i = convoy()
        i.arrived = .init(count: 3, total: 4, driveSeconds: 9_660)
        let (s, stale) = ConvoyActivityLogic.state(i)
        #expect(stale == nil && s.driveSeconds == 9_660 && s.arrivedCount == 3)
        #expect(ConvoyActivityPresentation.display(s, isStale: true) == .state(.arrived))
        i.arrived = nil
        i.tripEnded = true
        #expect(ConvoyActivityLogic.state(i).staleDate == nil)
        #expect(ConvoyActivityPresentation.trailing(ConvoyActivityLogic.state(i).state, now: now) == .cross)
    }

    @Test func staleGreysWhateverTheStateWas() {
        let s = ConvoyActivityLogic.state(convoy()).state
        #expect(ConvoyActivityPresentation.display(s, isStale: false) == .state(.inConvoy))
        #expect(ConvoyActivityPresentation.display(s, isStale: true) == .notUpdating(was: .inConvoy))
        #expect(ConvoyActivityPresentation.display(s, isStale: true).kind == .inConvoy)
    }

    // MARK: Compact values

    @Test func compactFormsAreAtMostFiveCharacters() {
        let d = ConvoyActivityPresentation.compactDistance
        #expect(d(350) == "350 m" && d(3_300) == "3.3km" && d(14_000) == "14 km" && d(160_000) == "160km")
        #expect(d(999.6) == "1.0km")
        #expect(d(9_960) == "10 km" && d(2_000_000) == "999km")
        let t = ConvoyActivityPresentation.compactDuration
        #expect(t(41 * 60) == "41m" && t(161 * 60) == "2h41" && t(120 * 60) == "2h00" && t(10) == "1m")
        for meters in stride(from: 0.0, through: 3_000_000, by: 137) {
            #expect(d(meters).count <= 5, "\(meters)")
        }
        for seconds in stride(from: 0.0, through: 400_000, by: 311) {
            #expect(t(seconds).count <= 5, "\(seconds)")
        }
        #expect(ConvoyActivityPresentation.count(3, of: 4) == "3/4" && ConvoyActivityPresentation.count(120, of: 120).count == 5)
    }

    @Test func everyStatesTrailingValueFitsTheIsland() {
        var states: [ConvoyActivityAttributes.ContentState] = []
        var i = convoy()
        states.append(ConvoyActivityLogic.state(i).state)
        i.nextStop = nil
        states.append(ConvoyActivityLogic.state(i).state)
        i.tripStarted = false
        i.isOrganizer = true
        states.append(ConvoyActivityLogic.state(i).state)
        i = convoy()
        i.myOffset = nil
        i.joining = .init(place: "Rawang", meetsAtDestination: false, amount: .time(9 * 60))
        states.append(ConvoyActivityLogic.state(i).state)
        i.joining = .init(place: nil, meetsAtDestination: true, amount: .distance(160_000))
        states.append(ConvoyActivityLogic.state(i).state)
        i = convoy()
        i.headsUp = .init(name: "Aisha", meters: 3_300, seconds: 120)
        states.append(ConvoyActivityLogic.state(i).state)
        i.hazard = .init(label: "Debris", reporter: nil, meters: 350, offset: nil)
        states.append(ConvoyActivityLogic.state(i).state)
        i.hazard = nil
        i.request = request(owes: true)
        states.append(ConvoyActivityLogic.state(i).state)
        for s in states {
            switch ConvoyActivityPresentation.trailing(s, now: now) {
            case .value(let text, _): #expect(text.count <= ConvoyActivityPresentation.maxCharacters, "\(s.kind) \(text)")
            default: break
            }
        }
        #expect(ConvoyActivityPresentation.trailing(states[2], now: now) == .value("3/4", .tick))
        // A passenger's Waiting is the cars glyph, not a count.
        i = convoy()
        i.tripStarted = false
        #expect(ConvoyActivityPresentation.trailing(ConvoyActivityLogic.state(i).state, now: now) == .cars)
    }

    @Test func minutesCountUpAndDown() {
        let p = ConvoyActivityPresentation.self
        #expect(p.minutes(since: now.addingTimeInterval(-12 * 60 - 20), now: now) == 12)
        #expect(p.minutes(since: now, now: now) == 1)
        #expect(p.minutes(until: now.addingTimeInterval(22 * 60 + 5), now: now) == 23)
    }

    // MARK: Size and privacy

    @Test func worstCaseStaysFarUnder4KB() throws {
        var i = convoy()
        let long = String(repeating: "Muhammad ", count: 6)
        i.tripName = long
        i.destination = long
        i.dots = (0..<9).map { n in
            .init(name: long, color: "#D9480F", offset: 50_000 + Double(4 - n) * 900, gapAhead: 900, isMine: n == 4)
        }
        i.nextStop = .init(name: long, offset: 54_000, meters: 4_000, seconds: 300, isHere: false)
        i.request = request(owes: false, said: true)
        let (s, _) = ConvoyActivityLogic.state(i)
        let attributes = ConvoyActivityAttributes(tripId: String(repeating: "a", count: 20))
        let bytes = try JSONEncoder().encode(s).count + JSONEncoder().encode(attributes).count
        #expect(bytes < 2_000, "\(bytes) bytes")
        // Names and counts and fractions only: nothing that is an id or a coordinate.
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        #expect(!json.contains("latitude") && !json.contains("userId") && !json.contains("carId"))
    }
}
