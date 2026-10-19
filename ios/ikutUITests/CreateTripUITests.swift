import XCTest

/// Drives the organizer's path in a simulator: name, New Trip, pick a destination, lobby, Start Trip,
/// map. Needs the emulators and a simulated location (`xcrun simctl location <udid> set 3.139,101.687`).
/// `TEST_RUNNER_IKUT_DESTINATION` picks the search text (default Ipoh); `TEST_RUNNER_IKUT_HOLD_SECONDS`
/// stays on the map that long at the end.
@MainActor
final class CreateTripUITests: XCTestCase {
    func testCreateAndStartTrip() throws {
        let env = ProcessInfo.processInfo.environment
        let destination = env["IKUT_DESTINATION"] ?? "Ipoh"

        let app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "Location") { alert in
            for label in ["Allow While Using App", "Allow Once", "Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()

        // Welcome on a first run, Home once a previous run got past it.
        let getStarted = app.buttons["Get Started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }
        let newTrip = app.buttons["New Trip"]
        XCTAssertTrue(newTrip.waitForExistence(timeout: 15), "Home didn't show New Trip")
        newTrip.tap()

        // Signed out: the name sheet comes first.
        let sheetName = app.textFields["Your name"]
        if sheetName.waitForExistence(timeout: 3), app.buttons["Continue"].exists {
            sheetName.tap()
            sheetName.typeText("Organizer")
            app.buttons["Continue"].tap()
        }

        app.tap()  // Lets the interruption monitor handle a location prompt.

        let search = app.textFields["Destination"]
        XCTAssertTrue(search.waitForExistence(timeout: 15), "Didn't reach Where to?")
        search.tap()
        search.typeText(destination)

        let firstResult = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", destination)).firstMatch
        XCTAssertTrue(firstResult.waitForExistence(timeout: 20), "No search result for \(destination)")
        firstResult.tap()

        let startTrip = app.buttons["Start Trip"]
        if !startTrip.waitForExistence(timeout: 30) {
            let errors = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Error: '"))
            let message = errors.firstMatch.exists ? errors.firstMatch.label : "no error shown"
            add(XCTAttachment(screenshot: app.screenshot()))
            XCTFail("Didn't reach the lobby (\(message))")
            return
        }
        add(XCTAttachment(screenshot: app.screenshot()))

        startTrip.tap()
        XCTAssertTrue(app.buttons["Report"].waitForExistence(timeout: 20), "Didn't reach the map")
        add(XCTAttachment(screenshot: app.screenshot()))

        // TEST_RUNNER_IKUT_HOLD_SECONDS keeps the map open, e.g. to watch `qa/drive-trip.mjs` play the route.
        if let hold = env["IKUT_HOLD_SECONDS"].flatMap(Double.init) {
            _ = app.buttons["Never shown"].waitForExistence(timeout: hold)
        }
    }
}
