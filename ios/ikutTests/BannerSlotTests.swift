import Foundation
import Testing
@testable import ikut

struct BannerSlotTests {
    typealias M = BannerSlot.Message
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func shown(_ present: Set<M>, _ arrivals: [M: Date] = [:]) -> M? {
        BannerSlot.resolve(present: present, arrivals: arrivals).shown
    }

    @Test func emptyWhenNothingIsUp() {
        #expect(BannerSlot.resolve(present: []) == .init(shown: nil, errorHeld: false))
    }

    @Test func eachMessageShowsAlone() {
        for message in M.allCases { #expect(shown([message]) == message) }
    }

    @Test func theRankingIsHazardStopStopApproachPassedPausedThenTheRest() {
        let order: [M] = [.hazardApproach, .stopPill, .stopApproach, .toast, .passed, .paused]
        for (i, higher) in order.enumerated() {
            for lower in order[(i + 1)...] + [.catchUp, .alertBanner, .routeNotice, .error] {
                #expect(shown([higher, lower]) == higher, "\(higher) over \(lower)")
                #expect(shown([lower, higher]) == higher, "\(higher) over \(lower)")
            }
        }
    }

    @Test func aHazardTakesTheSlotFromEveryOtherMessage() {
        #expect(shown(Set(M.allCases)) == .hazardApproach)
        #expect(shown(Set(M.allCases).subtracting([.hazardApproach])) == .stopPill)
    }

    @Test func theTimedMessagesShowOverPausedAndTheRest() {
        // Undo and Passed run on timers: a standing message must not use their time up unseen.
        #expect(shown([.toast, .paused, .error]) == .toast)
        #expect(shown([.passed, .paused, .catchUp]) == .passed)
        #expect(shown([.toast, .passed]) == .toast)
    }

    @Test func theNewestOfTheRestShows() {
        let later = t0.addingTimeInterval(5)
        #expect(shown([.catchUp, .routeNotice], [.catchUp: t0, .routeNotice: later]) == .routeNotice)
        #expect(shown([.catchUp, .routeNotice], [.catchUp: later, .routeNotice: t0]) == .catchUp)
        #expect(shown([.alertBanner, .error], [.alertBanner: later, .error: t0]) == .alertBanner)
        #expect(shown([.alertBanner, .error], [.alertBanner: t0, .error: later]) == .error)
    }

    @Test func anEqualArrivalGoesToTheErrorThenTheBannerThenTheCatchUp() {
        #expect(shown([.catchUp, .alertBanner, .routeNotice, .error]) == .error)
        #expect(shown([.catchUp, .alertBanner, .routeNotice]) == .alertBanner)
        #expect(shown([.catchUp, .routeNotice]) == .catchUp)
    }

    @Test func anErrorHeldBehindAnotherMessageIsReportedForTheDot() {
        #expect(BannerSlot.resolve(present: [.error, .hazardApproach]).errorHeld)
        #expect(BannerSlot.resolve(present: [.error, .paused]).errorHeld)
        #expect(!BannerSlot.resolve(present: [.error]).errorHeld)
        #expect(!BannerSlot.resolve(present: [.hazardApproach, .paused]).errorHeld)
        // An error that is the newest of the rest has the slot itself.
        #expect(!BannerSlot.resolve(present: [.error, .catchUp], arrivals: [.catchUp: t0, .error: t0.addingTimeInterval(1)]).errorHeld)
    }

    @Test func aWaitingMessageComesBackWhenTheTopOneGoes() {
        var present: Set<M> = [.hazardApproach, .stopApproach, .error]
        #expect(shown(present) == .hazardApproach)
        present.remove(.hazardApproach)
        #expect(shown(present) == .stopApproach)
        present.remove(.stopApproach)
        #expect(shown(present) == .error)
    }

    @Test func arrivalsKeepTheFirstTimeAndRestartForAnotherMessageOfTheSameKind() {
        var arrivals = BannerSlot.Arrivals()
        arrivals.update(present: [.catchUp: "a"], now: t0)
        arrivals.update(present: [.catchUp: "a", .error: "x"], now: t0.addingTimeInterval(5))
        #expect(arrivals.dates[.catchUp] == t0)
        #expect(arrivals.dates[.error] == t0.addingTimeInterval(5))
        arrivals.update(present: [.catchUp: "b", .error: "x"], now: t0.addingTimeInterval(9))
        #expect(arrivals.dates[.catchUp] == t0.addingTimeInterval(9))
        arrivals.update(present: [.catchUp: "b"], now: t0.addingTimeInterval(10))
        #expect(arrivals.dates[.error] == nil)
    }

    @MainActor @Test func aMessageBackFromWaitingIsNotSaidAgainButANewOneIs() {
        let spoken = SpokenBanners()
        #expect(spoken.claim("stop-1"))
        // It waits behind a hazard: still live, so coming back says nothing.
        spoken.keep(["stop-1", "hazard-1"])
        #expect(!spoken.claim("stop-1"))
        // Gone for good, then up again: spoken again.
        spoken.keep(["hazard-1"])
        #expect(spoken.claim("stop-1"))
    }
}
