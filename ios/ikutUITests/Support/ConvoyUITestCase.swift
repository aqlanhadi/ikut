import XCTest

/// One place for what every driven-by-a-script UI test needs: finding elements, polling, screenshots,
/// the permission prompt, and the first-run steps (name sheet, New Trip, joining with a code).
/// `TwoPhoneConvoyBase` (and through it the demos) and `ConvoyScenarioUITests` build on it.
@MainActor
class ConvoyUITestCase: XCTestCase {
    struct WaitFailure: Error {}

    var app: XCUIApplication!
    /// Where screenshots are written (set by the subclass before the first `shot`).
    var screens = ""

    /// Seconds between checks in `waitFor`.
    var pollInterval: TimeInterval { 1 }
    /// Put in front of every screenshot file name (the two-phone tests say which phone).
    var shotPrefix: String { "" }

    override func setUp() {
        continueAfterFailure = false
    }

    /// Taps Allow on a system permission prompt (the test has to tap the app once for the monitor to run).
    func allowPermissionPrompts(_ labels: [String] = ["Allow While Using App", "Allow Once", "Allow"]) {
        addUIInterruptionMonitor(withDescription: "Permissions") { alert in
            for label in labels where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    // MARK: Steps, waits, screenshots

    func step(_ name: String, _ body: () throws -> Void) throws {
        print("QA STEP: \(name)")
        try body()
    }

    func waitFor(_ what: String, timeout: TimeInterval, poll: TimeInterval? = nil, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: poll ?? pollInterval)
        }
        if condition() { return }
        shot("FAILED-\(what.replacingOccurrences(of: " ", with: "-"))")
        XCTFail("Timed out after \(Int(timeout)) s waiting for: \(what). Convoy order: \(convoyOrder())")
        throw WaitFailure()
    }

    func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let file = "\(shotPrefix)\(name).png"
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: screens).appendingPathComponent(file))
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = file
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Queries

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func labelled(_ format: String, _ value: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: format, value)).firstMatch
    }

    func button(beginningWith prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// "Start Trip" in a lobby that hasn't started, "Back to Map" once the trip is on the road.
    var lobbyActionButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Start Trip", "Back to Map"])).firstMatch
    }

    /// Badge numbers of the convoy rows, front of the convoy first (top of the list).
    func convoyOrder() -> [Int] {
        guard app != nil else { return [] }
        let prefix = "convoy.row."
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).allElementsBoundByIndex
        var seen = Set<Int>()
        return rows.sorted { $0.frame.minY < $1.frame.minY }.compactMap { row -> Int? in
            guard let n = Int(row.identifier.dropFirst(prefix.count)), seen.insert(n).inserted else { return nil }
            return n
        }
    }

    // MARK: Shared flows

    /// Clears the field (cursor to the end, a delete for every character it holds, more than once if the first pass leaves
    /// some), types `text` and checks the field now holds exactly that. A field that is empty reports its
    /// placeholder as its value, which is not text to delete.
    func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        // A tap lands the cursor where it hit, and deletes only remove what is before it: tap the far right
        // end of the field so the cursor is after the last character (this is what left "FaizAisha").
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        for _ in 0..<3 {
            let current = field.value as? String ?? ""
            if current.isEmpty || current == field.placeholderValue { break }
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text, "the field should hold exactly what was typed")
    }

    /// Fills the "Your name" sheet when it comes up (signed out), then taps the app so the interruption
    /// monitor can answer a permission prompt.
    func enterNameIfAsked(_ name: String) {
        let sheetName = app.textFields["Your name"]
        if sheetName.waitForExistence(timeout: 3), app.buttons["Continue"].exists {
            sheetName.tap()
            sheetName.typeText(name)
            app.buttons["Continue"].tap()
        }
        app.tap()
    }

    /// Welcome (first run) or Home to the name sheet and on: taps New Trip.
    func startNewTrip(as name: String, homeTimeout: TimeInterval = 20) {
        let getStarted = app.buttons["Get Started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }
        let newTrip = app.buttons["New Trip"]
        XCTAssertTrue(newTrip.waitForExistence(timeout: homeTimeout), "Home didn't show New Trip")
        newTrip.tap()
        enterNameIfAsked(name)
    }

    /// The organizer's lobby: the six-letter join code from the "Join code ..." label.
    func readJoinCode() -> String {
        let codeLabel = labelled("label BEGINSWITH %@", "Join code ")
        XCTAssertTrue(codeLabel.waitForExistence(timeout: 15), "Lobby shows no join code")
        let code = codeLabel.label.replacingOccurrences(of: "Join code ", with: "").replacingOccurrences(of: " ", with: "")
        XCTAssertEqual(code.count, 6, "code: \(code)")
        return code
    }

    /// A phone that still holds an earlier trip opens in its lobby or map, not Home: say so instead of
    /// letting the next step report a field it cannot find.
    func failIfAlreadyInATrip() {
        if lobbyActionButton.waitForExistence(timeout: 3) {
            XCTFail("This phone is already in a trip (its lobby or map is open) and should start from Home: it holds an earlier session. Uninstall the app first (qa/run-convoy2.mjs does).")
        }
    }

    /// Welcome or Home to the join form with `code` typed in (the name sheet comes first when signed out).
    func openJoinForm(code: String, name: String, homeTimeout: TimeInterval = 30) {
        failIfAlreadyInATrip()
        let joinButton = app.buttons
            .matching(NSPredicate(format: "label IN %@", ["Join with Code or QR", "Join Trip"])).firstMatch
        XCTAssertTrue(joinButton.waitForExistence(timeout: homeTimeout), "Home didn't show Join Trip")
        joinButton.tap()
        enterNameIfAsked(name)
        let codeField = app.textFields["Trip code"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 15), "Join screen didn't show the code field")
        codeField.tap()
        codeField.typeText(code)
    }

    /// Home (or Welcome) to the lobby of `code`, as a new car named "<name>'s car".
    func join(code: String, name: String) throws {
        openJoinForm(code: code, name: name)
        let newCar = button(beginningWith: "A new car")
        XCTAssertTrue(newCar.waitForExistence(timeout: 30), "Trip preview didn't load for \(code) (is the code right and the emulator up?)")
        let joinNameField = app.textFields["Your name"]
        if joinNameField.exists, (joinNameField.value as? String) != name { replaceText(in: joinNameField, with: name) }
        newCar.tap()
        let carName = app.textFields["Car name"]
        if carName.waitForExistence(timeout: 5) { replaceText(in: carName, with: "\(name)'s car") }

        app.buttons["Join Trip"].tap()
        XCTAssertTrue(lobbyActionButton.waitForExistence(timeout: 30), "Didn't reach the lobby")
        let notNow = app.buttons["Not now"]
        if notNow.waitForExistence(timeout: 4) { notNow.tap() }
    }
}
