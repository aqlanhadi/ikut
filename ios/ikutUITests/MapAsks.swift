import XCTest

extension XCUIApplication {
    /// The driving mode's Report button, by identifier: it is there once Start or Show map has switched the trip screen
    /// to driving (the same screen, no push, D53).
    var drivingReport: XCUIElement { buttons["convoy.report"] }
    /// The driving mode's Back, by identifier: it switches the trip screen back to the lobby.
    var backToLobby: XCUIElement { buttons["map.backToLobby"] }

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
