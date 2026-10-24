import Testing
import UserNotifications
@testable import ikut

@Suite("Trip asks") @MainActor
struct TripAskTests {
    private func next(
        _ n: NotificationAccess, asked: Set<TripAsk> = [], explainer: Bool = false
    ) -> TripAsk? {
        TripAskPlanner.next(notifications: n, asked: asked, explainerShowing: explainer)
    }

    @Test func notificationStatusMapping() {
        #expect(NotificationAccess(.notDetermined) == .notDetermined)
        #expect(NotificationAccess(.denied) == .denied)
        #expect(NotificationAccess(.authorized) == .allowed)
        #expect(NotificationAccess(.provisional) == .allowed)
        #expect(NotificationAccess(.ephemeral) == .allowed)
    }

    @Test func roadAlertsComeFirst() {
        #expect(next(.notDetermined) == .roadAlerts)
        #expect(next(.denied) == .roadAlertsOff)
        #expect(next(.allowed) == nil)
    }

    @Test func neverAsksAboutTheScreen() {
        for n in [NotificationAccess.notDetermined, .denied, .allowed] {
            for asked in [Set<TripAsk>(), [.roadAlerts], [.roadAlertsOff], [.roadAlerts, .roadAlertsOff]] {
                let ask = next(n, asked: asked)
                #expect(ask == nil || ask == .roadAlerts || ask == .roadAlertsOff)
            }
        }
    }

    @Test func keepAwakeIsOnUntilThePersonChooses() {
        #expect(ScreenAwake.preference(answered: false, stored: false))
        #expect(ScreenAwake.preference(answered: true, stored: true))
        #expect(!ScreenAwake.preference(answered: true, stored: false))
    }

    @Test func oldStoredAsksStillParse() {
        #expect(TripAskMemory.asked(in: "T1|keepScreenOn,roadAlerts", tripId: "T1") == [.roadAlerts])
        #expect(TripAskMemory.asked(in: "T1|keepScreenOn", tripId: "T1").isEmpty)
    }

    @Test func nothingLeftToAsk() {
        #expect(next(.allowed) == nil)
        #expect(next(.denied, asked: [.roadAlertsOff]) == nil)
        #expect(next(.notDetermined, asked: [.roadAlerts]) == nil)
    }

    @Test func nothingWhileTheLocationExplainerIsUp() {
        #expect(next(.notDetermined, explainer: true) == nil)
        #expect(next(.allowed, explainer: true) == nil)
    }

    @Test func deniedAfterTheSystemPromptIsNotAskedAgainThisTrip() {
        // The system prompt was shown and refused: the status flips to denied, but road alerts was already asked.
        #expect(next(.denied, asked: [.roadAlerts]) == nil)
    }

    @Test func refusingTheSystemPromptNeverLeadsToTheSettingsAsk() {
        // What the app really stores after answering road alerts, then the status reading denied.
        let stored = TripAskMemory.recording(.roadAlerts, in: "", tripId: "T1")
        let asked = TripAskMemory.asked(in: stored, tripId: "T1")
        #expect(next(.denied, asked: asked) == nil)
    }

    @Test func asksAreRememberedPerTrip() {
        var stored = TripAskMemory.recording(.roadAlerts, in: "", tripId: "T1")
        #expect(TripAskMemory.asked(in: stored, tripId: "T1") == [.roadAlerts, .roadAlertsOff])
        #expect(TripAskMemory.asked(in: stored, tripId: "T2").isEmpty)
        stored = TripAskMemory.recording(.roadAlertsOff, in: "", tripId: "T2")
        #expect(TripAskMemory.asked(in: stored, tripId: "T1").isEmpty)
        #expect(next(.denied, asked: TripAskMemory.asked(in: stored, tripId: "T2")) == nil)
    }

    @Test func theSheetWaitsWhileAnAskIsUp() {
        #expect(!TripSessionLogic.explainerVisible(wanted: true, askShowing: true))
        #expect(TripSessionLogic.explainerVisible(wanted: true, askShowing: false))
        #expect(!TripSessionLogic.explainerVisible(wanted: false, askShowing: false))
        // While the sheet is wanted, the planner holds every ask, so the two never take turns wrongly.
        #expect(next(.notDetermined, explainer: true) == nil)
    }

    @Test func screenHeldOnlyOnScreenForARunningTripInFront() {
        var calls: [Bool] = []
        let awake = ScreenAwake { calls.append($0) }
        awake.update(preference: true, onScreen: true, tripRunning: true, appActive: true)
        awake.update(preference: true, onScreen: true, tripRunning: true, appActive: true)
        #expect(calls == [true])
        awake.update(preference: true, onScreen: true, tripRunning: true, appActive: false)
        awake.update(preference: true, onScreen: true, tripRunning: true, appActive: true)
        awake.update(preference: true, onScreen: true, tripRunning: false, appActive: true)
        awake.update(preference: true, onScreen: true, tripRunning: true, appActive: true)
        awake.update(preference: true, onScreen: false, tripRunning: true, appActive: true)
        awake.update(preference: true, onScreen: true, tripRunning: true, appActive: true)
        awake.update(preference: false, onScreen: true, tripRunning: true, appActive: true)
        #expect(calls == [true, false, true, false, true, false, true, false])
        #expect(!awake.isHeld)
    }

    @Test func neverHeldWithoutPreference() {
        var calls: [Bool] = []
        let awake = ScreenAwake { calls.append($0) }
        awake.update(preference: false, onScreen: true, tripRunning: true, appActive: true)
        #expect(calls.isEmpty)
    }
}
