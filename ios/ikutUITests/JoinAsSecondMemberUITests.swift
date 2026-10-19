import XCTest

/// Drives the app in a simulator as a second person joining an existing trip, so a phone
/// running the organizer's lobby can watch them arrive. Skipped unless a code is given:
///
///     TEST_RUNNER_IKUT_JOIN_CODE=Y5REFN TEST_RUNNER_IKUT_JOIN_NAME=Wyna \
///       xcodebuild test -scheme ikut -only-testing:ikutUITests ...
@MainActor
final class JoinAsSecondMemberUITests: XCTestCase {
    func testJoinTrip() throws {
        let env = ProcessInfo.processInfo.environment
        guard let code = env["IKUT_JOIN_CODE"] else {
            throw XCTSkip("Set TEST_RUNNER_IKUT_JOIN_CODE to join a trip")
        }
        let name = env["IKUT_JOIN_NAME"] ?? "Wyna"

        let app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "Location") { alert in
            for label in ["Allow While Using App", "Allow Once", "Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()

        // Welcome on a first run, Home ("Join Trip") once a previous run got past it.
        let joinButton = app.buttons
            .matching(NSPredicate(format: "label IN %@", ["Join with Code or QR", "Join Trip"])).firstMatch
        XCTAssertTrue(joinButton.waitForExistence(timeout: 15))
        joinButton.tap()

        // Signed out: the name sheet comes first.
        let sheetName = app.textFields["Your name"]
        if sheetName.waitForExistence(timeout: 3), app.buttons["Continue"].exists {
            sheetName.tap()
            sheetName.typeText(name)
            app.buttons["Continue"].tap()
        }

        app.tap()  // Lets the interruption monitor handle a location prompt.

        let codeField = app.textFields["Trip code"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 15))
        codeField.tap()
        codeField.typeText(code)

        let newCar = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'A new car'")).firstMatch
        XCTAssertTrue(newCar.waitForExistence(timeout: 20), "Trip preview didn't load")

        let joinNameField = app.textFields["Your name"]
        if joinNameField.exists, (joinNameField.value as? String) != name {
            replaceText(in: joinNameField, with: name)
        }

        newCar.tap()
        let carName = app.textFields["Car name"]
        if carName.waitForExistence(timeout: 5) {
            replaceText(in: carName, with: "\(name)'s car")
        }

        app.buttons["Join Trip"].tap()
        let startTrip = app.buttons["Start Trip"]
        XCTAssertTrue(startTrip.waitForExistence(timeout: 20), "Didn't reach the lobby")

        // Start Trip pushes the live map on the lobby's session.
        startTrip.tap()
        XCTAssertTrue(app.buttons["Report"].waitForExistence(timeout: 20), "Didn't reach the map")
        XCTAssertTrue(app.buttons["Trip menu"].exists)

        // TEST_RUNNER_IKUT_HOLD_SECONDS keeps the map open, e.g. for `qa/demo.mjs`.
        if let hold = env["IKUT_HOLD_SECONDS"].flatMap(Double.init) {
            _ = XCTWaiter().wait(for: [XCTestExpectation(description: "hold on the map")], timeout: hold)
        }
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }
}
