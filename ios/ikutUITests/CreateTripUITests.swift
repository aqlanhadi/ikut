import XCTest

/// Drives the organizer's path in a simulator: name, New trip, pick a destination, lobby, Start trip,
/// map. Needs the emulators and a simulated location (`xcrun simctl location <udid> set 3.139,101.687`).
/// `TEST_RUNNER_IKUT_DESTINATION` picks the search text (default Ipoh); `TEST_RUNNER_IKUT_HOLD_SECONDS`
/// stays on the map that long at the end.
@MainActor
final class CreateTripUITests: ConvoyUITestCase {
    func testCreateAndStartTrip() throws {
        let env = ProcessInfo.processInfo.environment
        let destination = env["IKUT_DESTINATION"] ?? "Ipoh"

        app = XCUIApplication()
        allowPermissionPrompts()
        app.launch()

        // Welcome on a first run, Home once a previous run got past it; the name sheet comes first when signed out.
        startNewTrip(as: "Organizer", homeTimeout: 15)

        let search = app.textFields["Destination"]
        XCTAssertTrue(search.waitForExistence(timeout: 15), "Didn't reach Where to?")
        search.tap()
        search.typeText(destination)

        let firstResult = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", destination)).firstMatch
        XCTAssertTrue(firstResult.waitForExistence(timeout: 20), "No search result for \(destination)")
        firstResult.tap()

        let startTrip = app.buttons["Start trip"]
        if !startTrip.waitForExistence(timeout: 30) {
            let errors = app.staticTexts.matching(identifier: "createTripError")
            let message = errors.firstMatch.exists ? errors.firstMatch.label : "no error shown"
            add(XCTAttachment(screenshot: app.screenshot()))
            XCTFail("Didn't reach the lobby (\(message))")
            return
        }
        add(XCTAttachment(screenshot: app.screenshot()))

        // Tracking starts in the lobby; the "Not now" sheet (screen off) may cover Start trip, and the map asks its own.
        let notNow = app.buttons["Not now"]
        if notNow.waitForExistence(timeout: 6) { notNow.tap() }
        startTrip.tap()
        app.dismissMapAsks(first: 3)
        XCTAssertTrue(app.buttons["Report"].waitForExistence(timeout: 20), "Didn't reach the map")
        add(XCTAttachment(screenshot: app.screenshot()))

        // TEST_RUNNER_IKUT_HOLD_SECONDS keeps the map open, e.g. to watch `qa/drive-trip.mjs` play the route.
        if let hold = env["IKUT_HOLD_SECONDS"].flatMap(Double.init) {
            _ = app.buttons["Never shown"].waitForExistence(timeout: hold)
        }
    }
}
