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

    @Test func theRankingIsHazardStopToastStopApproachPassedErrorPausedThenTheRest() {
        let order: [M] = [.hazardApproach, .stopPill, .toast, .stopApproach, .passed, .error, .paused]
        for (i, higher) in order.enumerated() {
            for lower in order[(i + 1)...] + [.catchUp, .alertBanner, .routeNotice] {
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
        #expect(shown([.passed, .error]) == .passed)
        #expect(shown([.passed, .paused, .catchUp]) == .passed)
        #expect(shown([.toast, .passed]) == .toast)
    }

    @Test func theNewestOfTheRestShows() {
        let later = t0.addingTimeInterval(5)
        #expect(shown([.catchUp, .routeNotice], [.catchUp: t0, .routeNotice: later]) == .routeNotice)
        #expect(shown([.catchUp, .routeNotice], [.catchUp: later, .routeNotice: t0]) == .catchUp)
        // Up this very frame, with no arrival yet: counts as the newest.
        #expect(shown([.catchUp, .routeNotice], [.catchUp: t0]) == .routeNotice)
    }

    @Test func anEqualArrivalGoesToTheBannerThenTheCatchUpThenTheNotice() {
        #expect(shown([.catchUp, .alertBanner, .routeNotice]) == .alertBanner)
        #expect(shown([.catchUp, .routeNotice]) == .catchUp)
    }

    @Test func anErrorHeldBehindAnotherMessageIsReportedForTheDot() {
        #expect(BannerSlot.resolve(present: [.error, .hazardApproach]).errorHeld)
        #expect(!BannerSlot.resolve(present: [.error]).errorHeld)
        #expect(!BannerSlot.resolve(present: [.hazardApproach, .paused]).errorHeld)
    }

    @Test func anErrorShowsOverPausedAndComesBackToItAfterClosing() {
        // A failed Resume must be seen: the error has the slot, no dot, and Paused returns once it is closed.
        #expect(BannerSlot.resolve(present: [.paused, .error]) == .init(shown: .error, errorHeld: false))
        #expect(BannerSlot.resolve(present: [.paused]) == .init(shown: .paused, errorHeld: false))
    }

    @Test func anErrorBehindAHazardStopOrTimedMessageGetsTheDot() {
        for top in [M.hazardApproach, .stopPill, .toast, .stopApproach, .passed] {
            #expect(BannerSlot.resolve(present: [.paused, .error, top]) == .init(shown: top, errorHeld: true), "\(top)")
        }
    }

    @Test func theErrorBeatsTheRestWhateverTheirArrival() {
        let arrivals: [M: Date] = [.error: t0, .catchUp: t0.addingTimeInterval(9)]
        #expect(BannerSlot.resolve(present: [.error, .catchUp], arrivals: arrivals) == .init(shown: .error, errorHeld: false))
    }

    @Test func thePresentSetFollowsTheInputs() {
        var inputs = BannerSlot.Inputs()
        #expect(BannerSlot.present(inputs).isEmpty)
        inputs.paused = true
        inputs.error = "Couldn’t resume. Try again in a moment."
        // Paused with its own failed Resume: both are up, and the slot shows the error with no dot.
        let both = BannerSlot.present(inputs)
        #expect(both == [.paused: "paused", .error: "Couldn’t resume. Try again in a moment."])
        #expect(BannerSlot.resolve(present: Set(both.keys)) == .init(shown: .error, errorHeld: false))
        // A hazard comes: it takes the slot and the error waits with its dot.
        inputs.hazardApproachId = "h@approach"
        let held = BannerSlot.resolve(present: Set(BannerSlot.present(inputs).keys))
        #expect(held == .init(shown: .hazardApproach, errorHeld: true))
        // The toast's identity is what it announces under.
        inputs = BannerSlot.Inputs(toast: .reported(label: "debris", eventId: "e"))
        #expect(BannerSlot.present(inputs) == [.toast: "Reported debris. You can undo it."])
        inputs = BannerSlot.Inputs(stopApproachId: "s", toast: .sending(label: "debris"), catchUpId: "c")
        #expect(Set(BannerSlot.present(inputs).keys) == [.toast, .stopApproach, .catchUp])
    }

    @Test func yourReportShowsOverTheStopApproachButUnderAHazardAndAStopRequest() {
        for state in [ReportToastModel.State.sending(label: "debris"), .reported(label: "debris", eventId: "e"), .failed(message: "No signal")] {
            let present = Set(BannerSlot.present(BannerSlot.Inputs(stopApproachId: "s", toast: state)).keys)
            #expect(shown(present) == .toast)
        }
        #expect(shown([.toast, .stopApproach, .hazardApproach]) == .hazardApproach)
        #expect(shown([.toast, .stopApproach, .stopPill]) == .stopPill)
    }

    @MainActor @Test func theStopApproachComesBackAfterTheToastsEightSeconds() {
        var present: Set<M> = [.toast, .stopApproach]
        #expect(shown(present) == .toast)
        present.remove(.toast)  // the model hides it after `ReportToastModel.undoTime`
        #expect(shown(present) == .stopApproach)
        #expect(ReportToastModel.undoTime == .seconds(8))
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
