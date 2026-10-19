import XCTest

/// Second phone of `qa/demo.mjs`: joins an existing trip as a new car (Daniel's City), holds on the map, and when the
/// marker file appears taps Pit stop > Fuel (the request sheet sends by itself after a short countdown).
/// Skipped unless TEST_RUNNER_IKUT_JOIN_CODE is set:
///
///     TEST_RUNNER_IKUT_JOIN_CODE=Y5REFN TEST_RUNNER_IKUT_JOIN_NAME=Daniel TEST_RUNNER_IKUT_CAR_NAME="Daniel's City" \
///       TEST_RUNNER_IKUT_STOP_MARKER=/tmp/stop TEST_RUNNER_IKUT_HOLD_SECONDS=900 xcodebuild test ...
@MainActor
final class DemoSecondPhoneUITests: XCTestCase {
    func testJoinHoldAndRequestStop() throws {
        let env = ProcessInfo.processInfo.environment
        guard let code = env["IKUT_JOIN_CODE"] else { throw XCTSkip("Set TEST_RUNNER_IKUT_JOIN_CODE to join a trip") }
        let name = env["IKUT_JOIN_NAME"] ?? "Daniel"
        let carName = env["IKUT_CAR_NAME"] ?? "\(name)'s car"
        let hold = env["IKUT_HOLD_SECONDS"].flatMap(Double.init) ?? 60
        let started = Date()

        let app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "Location") { alert in
            for label in ["Allow While Using App", "Allow Once", "Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()

        let joinButton = app.buttons
            .matching(NSPredicate(format: "label IN %@", ["Join with Code or QR", "Join Trip"])).firstMatch
        XCTAssertTrue(joinButton.waitForExistence(timeout: 15))
        joinButton.tap()

        let sheetName = app.textFields["Your name"]
        if sheetName.waitForExistence(timeout: 3), app.buttons["Continue"].exists {
            sheetName.tap()
            sheetName.typeText(name)
            app.buttons["Continue"].tap()
        }
        app.tap()

        let codeField = app.textFields["Trip code"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 15))
        codeField.tap()
        codeField.typeText(code)

        let newCar = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'A new car'")).firstMatch
        XCTAssertTrue(newCar.waitForExistence(timeout: 20), "Trip preview didn't load")

        let joinNameField = app.textFields["Your name"]
        if joinNameField.exists, (joinNameField.value as? String) != name { replaceText(in: joinNameField, with: name) }

        newCar.tap()
        let carField = app.textFields["Car name"]
        if carField.waitForExistence(timeout: 5) { replaceText(in: carField, with: carName) }

        app.buttons["Join Trip"].tap()
        let startTrip = app.buttons["Start Trip"]
        XCTAssertTrue(startTrip.waitForExistence(timeout: 20), "Didn't reach the lobby")
        startTrip.tap()
        let notNow = app.buttons["Not now"]
        if notNow.waitForExistence(timeout: 5) { notNow.tap() }
        XCTAssertTrue(app.buttons["Report"].waitForExistence(timeout: 20), "Didn't reach the map")

        // Stay on the map until the demo script writes the marker file, then request the stop from the UI.
        if let marker = env["IKUT_STOP_MARKER"] {
            let deadline = started.addingTimeInterval(hold)
            while !FileManager.default.fileExists(atPath: marker), Date() < deadline {
                _ = XCTWaiter().wait(for: [XCTestExpectation(description: "poll")], timeout: 1)
            }
            if FileManager.default.fileExists(atPath: marker) {
                let pitStop = app.buttons["Pit stop"]
                XCTAssertTrue(pitStop.waitForExistence(timeout: 10), "No Pit stop button on the map")
                pitStop.tap()
                let fuel = app.buttons["Fuel"]
                XCTAssertTrue(fuel.waitForExistence(timeout: 10), "Request sheet didn't show Fuel")
                fuel.tap()
                // It finds a place and sends by itself after the countdown; give it time to do so.
                _ = XCTWaiter().wait(for: [XCTestExpectation(description: "countdown")], timeout: 10)
            }
        }

        let remaining = hold - Date().timeIntervalSince(started)
        if remaining > 0 { _ = XCTWaiter().wait(for: [XCTestExpectation(description: "hold on the map")], timeout: remaining) }
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }
}
