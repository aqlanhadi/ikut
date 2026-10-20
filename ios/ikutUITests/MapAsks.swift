import XCTest

extension XCUIApplication {
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
