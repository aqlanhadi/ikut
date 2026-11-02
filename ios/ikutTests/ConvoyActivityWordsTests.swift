import Foundation
import Testing
@testable import ikut

@Suite("Live Activity words")
struct ConvoyActivityWordsTests {
    typealias Input = ConvoyActivityInput
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func convoy() -> Input {
        var i = Input(now: now, tripName: "Balik kampung raya", destination: "Ipoh")
        i.myOffset = 50_000
        i.dots = [
            .init(name: "Aisha", color: "#D9480F", offset: 51_800, gapAhead: nil),
            .init(name: "Aqlan", color: "#2563EB", offset: 50_000, gapAhead: 1_800, isMine: true),
            .init(name: "Daniel", color: "#7C3AED", offset: 47_200, gapAhead: 2_800),
        ]
        i.destinationMeters = 63_000
        i.destinationSeconds = 41 * 60
        i.spreadMeters = 6_800
        i.carCount = 4
        i.readyCars = 3
        i.organizerName = "Aisha"
        i.newestOtherData = now.addingTimeInterval(-10)
        i.nextStop = .init(name: "R&R Tapah", offset: 59_000, meters: 18_000, seconds: 12 * 60, isHere: false)
        return i
    }

    func words(_ i: Input, stale: Bool = false, at date: Date? = nil) -> ActivityWords {
        let s = ConvoyActivityLogic.state(i).state
        return ActivityWords(s, display: ConvoyActivityPresentation.display(s, isStale: stale), now: date ?? i.now)
    }

    @Test func inTheConvoyWhileAStopIsAhead() {
        let w = words(convoy())
        #expect(w.title == "Balik kampung raya")
        #expect(w.subtitle == "Ipoh 63 km · spread 6.8 km")
        #expect(w.big == "12 min" && w.caption == "R&R Tapah · 18 km")
        #expect(w.line == "Aisha 1.8 km ahead · Daniel 2.8 km behind")
    }

    @Test func lastLegNamesTheDestinationAndDropsItFromTheSubtitle() {
        var i = convoy()
        i.nextStop = nil
        let w = words(i)
        #expect(w.subtitle == "spread 6.8 km")
        #expect(w.big == "41 min" && w.caption == "Ipoh · 63 km")
    }

    @Test func gapLineLeavesOutTheMissingHalf() {
        var i = convoy()
        i.dots[0].isMine = true
        i.dots[1].isMine = false
        i.myOffset = 51_800
        #expect(words(i).line == "Aqlan 1.8 km behind")
    }

    @Test func atAStopSaysLeavingAtThenLeaveNow() {
        var i = convoy()
        i.nextStop = .init(name: "R&R Tapah", offset: 50_050, meters: 0, seconds: nil, isHere: true)
        let leave = now.addingTimeInterval(12 * 60)
        i.stopHere = .init(here: 3, total: 4, leaveAt: leave, toGoSeconds: 29 * 60)
        var w = words(i)
        #expect(w.title == "At R&R Tapah" && w.big == "3 of 4" && w.caption == "here")
        #expect(w.leave?.text == "Leaving at \(ConvoyFormat.clock(leave)) · Ipoh by \(ConvoyFormat.clock(leave.addingTimeInterval(29 * 60)))")
        // Past the leaving time the arrival counts from now, not from the plan.
        let later = leave.addingTimeInterval(9 * 60)
        w = words(i, at: later)
        #expect(w.leave?.text == "Leave now · Ipoh by \(ConvoyFormat.clock(later.addingTimeInterval(29 * 60)))")
    }

    @Test func notUpdatingSaysSinceWhenTheNewestDataCame() {
        let w = words(convoy(), stale: true)
        #expect(w.line == "Not updating since \(ConvoyFormat.clock(now.addingTimeInterval(-10)))")
        #expect(w.lineIsWarning && w.request == nil)
    }

    @Test func hazardTitleIsBuiltFromTheType() {
        var i = convoy()
        i.hazard = .init(type: "debris", reporter: "Wyna", meters: 350, offset: nil)
        var w = words(i)
        #expect(w.title == "Debris ahead" && w.subtitle == "Reported by Wyna’s car" && w.big == "350 m" && w.caption == "ahead")
        i.hazard = .init(type: "somethingNew", reporter: nil, meters: nil, offset: nil)
        w = words(i)
        #expect(w.title == "Hazard ahead" && w.big == nil && w.subtitle == nil)
    }

    @Test func stopRequestUsesTheReasonsSymbolAndWords() {
        var i = convoy()
        i.request = .init(requesterName: "Wyna", reason: .food, meters: -5_000, okCount: 2, total: 4, iSaidOK: false, iAsked: false, owesMyAnswer: true, since: now)
        let w = words(i)
        #expect(w.title == "Wyna needs food" && w.subtitle == "5.0 km behind you" && w.line == "2 of 4 OK")
        #expect(w.symbol == Symbol.food && w.isAlert)
        i.request?.meters = 2_000
        #expect(words(i).subtitle == "2.0 km ahead of you")
    }

    @Test func requestLineAfterOKAndForMyOwnRequest() {
        var i = convoy()
        i.request = .init(requesterName: "Wyna", reason: .fuel, meters: -5_000, okCount: 3, total: 4, iSaidOK: true, iAsked: false, owesMyAnswer: false, since: now)
        var w = words(i)
        #expect(w.request?.text == "Wyna’s fuel stop" && w.request?.detail == "You said OK · 3 of 4" && w.request?.symbol == Symbol.fuel)
        i.request = .init(requesterName: "Aqlan", reason: .toilet, meters: nil, okCount: 3, total: 4, iSaidOK: false, iAsked: true, owesMyAnswer: false, since: now)
        w = words(i)
        #expect(w.request?.text == "You asked for a toilet break" && w.request?.detail == "3 of 4 OK · waiting for 1" && w.request?.symbol == Symbol.toilet)
    }

    @Test func pausedCountsDownToItsEndAndStoppedCountsUp() {
        var i = convoy()
        i.pausedUntil = now.addingTimeInterval(23 * 60)
        var w = words(i)
        #expect(w.title == "Sharing paused" && w.pauseEnd == i.pausedUntil && w.big == nil)
        i.pausedUntil = nil
        i.convoyStopSince = now.addingTimeInterval(-12 * 60)
        w = words(i)
        #expect(w.title == "Convoy stopped" && w.big == "12 min" && w.line == "The lead car taps Continue when everyone’s ready")
        i.mayEndConvoyStop = true
        #expect(words(i).line == "Tap Continue in ikut when everyone’s ready")
    }

    @Test func waitingArrivedAndEnded() {
        var i = convoy()
        i.tripStarted = false
        #expect(words(i).line == "Waiting for Aisha to start the trip")
        i.isOrganizer = true
        #expect(words(i).line == "3 of 4 cars ready")
        i = convoy()
        i.arrived = .init(count: 3, total: 4, driveSeconds: 2 * 3600 + 41 * 60)
        var w = words(i)
        #expect(w.title == "Arrived in Ipoh" && w.big == "2 h 41 min" && w.line == "3 of 4 arrived")
        i.arrived = .init(count: 4, total: 4, driveSeconds: nil)
        w = words(i)
        #expect(w.line == "Everyone’s arrived" && w.big == nil)
        i.arrived = nil
        i.tripEnded = true
        #expect(words(i).title == "Trip ended")
    }
}
