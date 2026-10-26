import XCTest

extension XCUIApplication {
    /// The driving mode's Report button, by identifier: it is there once Start or Show map has switched the trip screen
    /// to driving (the same screen, no push, D53).
    var drivingReport: XCUIElement { buttons["convoy.report"] }
    /// What continues below the convoy when the driving sheet is pulled up (the journey, code, trip, options, Leave or
    /// End), by identifier. There is no Back to the lobby any more (D53).
    var pulledUpSheet: XCUIElement { otherElements["trip.pulledUp"] }
    /// The convoy panel's header button when the list is folded.
    var expandConvoy: XCUIElement { buttons["Expand convoy list"] }

    /// Drags the convoy sheet up by its grabber until the lobby continues below the convoy; true once it does.
    @discardableResult
    func pullUpTripSheet() -> Bool {
        for _ in 0..<4 {
            if pulledUpSheet.exists { return true }
            let grabber = otherElements["Sheet Grabber"].firstMatch
            guard grabber.waitForExistence(timeout: 5) else { return false }
            grabber.swipeUp()
            _ = pulledUpSheet.waitForExistence(timeout: 2)
        }
        return pulledUpSheet.exists
    }

    /// Drags the convoy sheet down by its grabber once (pulled up to tall, or tall to short).
    func pullDownTripSheet() {
        let grabber = otherElements["Sheet Grabber"].firstMatch
        if grabber.waitForExistence(timeout: 5) { grabber.swipeDown() }
    }

    /// Pulls the convoy sheet up, scrolls it to the row with identifier `id` (lobby.endTrip, lobby.leaveTrip,
    /// lobby.pause) and taps it; false when it never became hittable.
    @discardableResult
    func tapPulledUpRow(_ id: String) -> Bool {
        guard pullUpTripSheet() else { return false }
        let row = buttons[id]
        var scrolls = 0
        while !(row.exists && row.isHittable), scrolls < 8 {
            pulledUpSheet.swipeUp()
            scrolls += 1
        }
        guard row.exists, row.isHittable else { return false }
        row.tap()
        return true
    }

    /// Answers "Not now" to whatever the map asks on arrival (road alerts, keep the screen on), one
    /// alert after another, plus the Always-location sheet. Waits `first` for the first, a shorter beat for the rest.
    func dismissMapAsks(first: TimeInterval = 5) {
        var wait = first
        for _ in 0..<4 {
            let notNow = buttons["Not now"]
            guard notNow.waitForExistence(timeout: wait) else { return }
            notNow.tap()
            wait = 2.5
        }
    }
}
