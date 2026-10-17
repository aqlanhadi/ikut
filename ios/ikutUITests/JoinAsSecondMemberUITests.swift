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

        // A simulator that already ran the app may still be signed in.
        let nameField = app.textFields["Your name"]
        let joinButton = app.buttons["Join a Trip"]
        if nameField.waitForExistence(timeout: 10), !joinButton.exists {
            nameField.tap()
            nameField.typeText(name)
            app.buttons["Continue"].tap()
        }

        XCTAssertTrue(joinButton.waitForExistence(timeout: 15))
        joinButton.tap()
        app.tap()  // Lets the interruption monitor handle a location prompt.

        let codeField = app.textFields["Trip code"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 15))
        codeField.tap()
        codeField.typeText(code)

        let newCar = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New car'")).firstMatch
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
        XCTAssertTrue(app.buttons["Go to map"].waitForExistence(timeout: 20), "Didn't reach the lobby")
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }
}
