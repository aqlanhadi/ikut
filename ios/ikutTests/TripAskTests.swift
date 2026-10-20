import Testing
import UserNotifications
@testable import ikut

@Suite("Trip asks") @MainActor
struct TripAskTests {
    private func next(
        _ n: NotificationAccess, answered: Bool = false, asked: Set<TripAsk> = [], explainer: Bool = false
    ) -> TripAsk? {
        TripAskPlanner.next(notifications: n, keepAwakeAnswered: answered, asked: asked, explainerShowing: explainer)
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
        #expect(next(.allowed) == .keepScreenOn)
    }

    @Test func screenAskFollowsTheAlertsAsk() {
        #expect(next(.notDetermined, asked: [.roadAlerts]) == .keepScreenOn)
        #expect(next(.denied, asked: [.roadAlertsOff]) == .keepScreenOn)
    }

    @Test func nothingLeftToAsk() {
        #expect(next(.allowed, answered: true) == nil)
        #expect(next(.allowed, asked: [.keepScreenOn]) == nil)
        #expect(next(.denied, answered: true, asked: [.roadAlertsOff]) == nil)
    }

    @Test func nothingWhileTheLocationExplainerIsUp() {
        #expect(next(.notDetermined, explainer: true) == nil)
        #expect(next(.allowed, explainer: true) == nil)
    }

    @Test func deniedAfterTheSystemPromptIsNotAskedAgainThisTrip() {
        // The system prompt was shown and refused: the status flips to denied, but road alerts was already asked.
        #expect(next(.denied, asked: [.roadAlerts, .roadAlertsOff]) == .keepScreenOn)
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
