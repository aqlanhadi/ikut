import XCTest

/// One real phone in the loop of the multi-car convoy scenario (see qa/README.md).
///
/// `qa/convoy-sim.mjs` drives four simulated cars through the emulators and `xcrun simctl location start`
/// drives this simulator along `qa/gpx/car5-app.gpx`; `qa/run-ui.mjs` starts all of it. This test joins the
/// simulated trip as the fifth car, then follows the scripted drive on the convoy panel:
///
///   1. before the drive: cars 1, 2, 3 and this one in order, car 4 under JOINING
///   2. signal drop: car 2 reads "Last seen ..." and falls down the list, then recovers
///   3. car 4 merges: JOINING disappears and it takes its place between cars 2 and 3
///   4. hazard: the marker appears, an approach alert is announced, the marker goes once everyone has passed
///   5. stop request: the card appears with the pinned place, this car agrees, the card goes when resolved
///
/// Skipped unless a code is given:
///
///     TEST_RUNNER_IKUT_JOIN_CODE=ABC123 TEST_RUNNER_IKUT_QA_SPEED=1 xcodebuild test ... -only-testing:ikutUITests/ConvoyScenarioUITests
///
/// Other variables: IKUT_JOIN_NAME (default "Faiz"), IKUT_QA_SPEED (the simulator's speed, scales waits),
/// IKUT_QA_SCREENS (directory for screenshots, default qa/screens in the repo).
@MainActor
final class ConvoyScenarioUITests: XCTestCase {
    private var app: XCUIApplication!
    private var speed = 1.0
    private var screens = ""

    override func setUp() {
        continueAfterFailure = false
    }

    func testFifthCarInSimulatedConvoy() throws {
        let env = ProcessInfo.processInfo.environment
        guard let code = env["IKUT_JOIN_CODE"] else {
            throw XCTSkip("Set TEST_RUNNER_IKUT_JOIN_CODE to the code printed by qa/convoy-sim.mjs")
        }
        let name = env["IKUT_JOIN_NAME"] ?? "Faiz"
        speed = Double(env["IKUT_QA_SPEED"] ?? "") ?? 1
        screens = env["IKUT_QA_SCREENS"]
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("qa/screens").path
        try? FileManager.default.createDirectory(atPath: screens, withIntermediateDirectories: true)

        app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "Location") { alert in
            for label in ["Allow While Using App", "Allow Once", "Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()

        try step("Join the trip as a new car, open the map") { try joinAndOpenMap(code: code, name: name) }

        // The sim starts the drive a few seconds after this phone's first position arrives.
        try step("1. Before the drive: cars 1, 2, 3 and the phone in order, car 4 JOINING") {
            let rows = ["convoy.row.1", "convoy.row.2", "convoy.row.3", "convoy.row.5"]
            try waitFor("all four convoy rows", timeout: 120) { rows.allSatisfy { exists($0) } }
            try waitFor("convoy order 1, 2, 3, 5", timeout: 60) { convoyOrder() == [1, 2, 3, 5] }
            let joining = element("joining.row.4")
            XCTAssertTrue(joining.exists, "car 4 should be under JOINING")
            XCTAssertTrue(joining.label.contains("Daniel"), "joining row should be Daniel's car: \(joining.label)")
            XCTAssertTrue(element("convoy.row.5").label.contains(name), "row 5 should be this phone's car: \(element("convoy.row.5").label)")
            XCTAssertTrue(element("convoy.header").label.hasPrefix("4 in Convoy"), "header: \(element("convoy.header").label)")
            shot("01-before-drive")
        }

        try step("2. Signal drop: car 2 goes stale (Last seen), others stay fresh") {
            try waitFor("car 2 row says Last seen", timeout: 330 / speed + 120) { element("convoy.row.2").label.contains("Last seen") }
            XCTAssertFalse(element("convoy.row.1").label.contains("Last seen"), "car 1 must not be stale")
            XCTAssertFalse(element("convoy.row.3").label.contains("Last seen"), "car 3 must not be stale")
            XCTAssertTrue(exists("joining.row.4"), "car 4 is still joining during the drop")
            // The stale car keeps its last position, so the others overtake it in the list.
            try waitFor("car 2 below car 3 while stale", timeout: 60 / speed + 30) {
                let order = convoyOrder()
                guard let two = order.firstIndex(of: 2), let three = order.firstIndex(of: 3) else { return false }
                return two > three
            }
            shot("02-car2-stale")
        }

        try step("3. Car 2 recovers") {
            try waitFor("car 2 no longer stale", timeout: 150 / speed + 60) { !element("convoy.row.2").label.contains("Last seen") }
            shot("03-car2-recovered")
        }

        try step("4. Car 4 merges: JOINING goes, order 1, 2, 4, 3, 5") {
            try waitFor("car 4 leaves JOINING", timeout: 120 / speed + 60) { !exists("joining.row.4") }
            try waitFor("convoy order 1, 2, 4, 3, 5", timeout: 60) { convoyOrder() == [1, 2, 4, 3, 5] }
            XCTAssertTrue(element("convoy.header").label.hasPrefix("5 in Convoy"), "header: \(element("convoy.header").label)")
            shot("04-car4-merged")
        }

        try step("5. Hazard: marker on the map") {
            app.buttons["Fit whole convoy"].tap() // the hazard is kilometres ahead of this car
            try waitFor("hazard marker", timeout: 160 / speed + 60) { hazardMarker().exists }
            XCTAssertTrue(hazardMarker().label.hasPrefix("Hazard: Debris"), "marker label: \(hazardMarker().label)")
            shot("05-hazard-marker")
        }

        try step("6. Approach alert for this car, 500 m before the hazard") {
            try waitFor("approach banner", timeout: 200 / speed + 60, poll: 0.3) { approachBanner().exists }
            let text = approachBanner().label
            XCTAssertTrue(text.contains("Debris ahead in"), "banner: \(text)")
            XCTAssertTrue(text.contains("meters"), "banner: \(text)")
            shot("06-approach-alert")
        }

        try step("7. Hazard marker clears once every car has passed it") {
            try waitFor("hazard marker gone", timeout: 90 / speed + 60) { !hazardMarker().exists }
            shot("07-hazard-cleared")
        }

        try step("8. Stop request: card with the pinned place, agree, then resolved") {
            let agree = app.buttons["Agree to Stop"]
            try waitFor("stop card", timeout: 100 / speed + 60) { agree.exists }
            try waitFor("pinned place on the card", timeout: 40 / speed + 30) {
                app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Petronas Tapah R&R'")).firstMatch.exists
            }
            // Let the card's entrance and the panel's collapse finish before capturing.
            Thread.sleep(forTimeInterval: 1)
            shot("08-stop-request")
            agree.tap()
            try waitFor("agreement shown", timeout: 15) {
                app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Agreed'")).firstMatch.exists
            }
            try waitFor("stop card gone after the lead resolves it", timeout: 120 / speed + 60) { !agree.exists && !app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Agreed'")).firstMatch.exists }
            try waitFor("convoy list back", timeout: 20) { convoyOrder().count == 5 }
            shot("09-after-stop")
        }
    }

    // MARK: Joining

    private func joinAndOpenMap(code: String, name: String) throws {
        // Welcome on a first run, Home ("Join Trip") once a previous run got past it.
        let joinButton = app.buttons
            .matching(NSPredicate(format: "label IN %@", ["Join with Code or QR", "Join Trip"])).firstMatch
        XCTAssertTrue(joinButton.waitForExistence(timeout: 20), "Welcome screen didn't show")
        joinButton.tap()

        let sheetName = app.textFields["Your name"]
        if sheetName.waitForExistence(timeout: 3), app.buttons["Continue"].exists {
            sheetName.tap()
            sheetName.typeText(name)
            app.buttons["Continue"].tap()
        }
        app.tap() // lets the interruption monitor handle a location prompt

        let codeField = app.textFields["Trip code"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 15))
        codeField.tap()
        codeField.typeText(code)

        let newCar = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'A new car'")).firstMatch
        XCTAssertTrue(newCar.waitForExistence(timeout: 20), "Trip preview didn't load (is the code right and the emulator up?)")

        let joinNameField = app.textFields["Your name"]
        if joinNameField.exists, (joinNameField.value as? String) != name { replaceText(in: joinNameField, with: name) }

        newCar.tap()
        let carName = app.textFields["Car name"]
        if carName.waitForExistence(timeout: 5) { replaceText(in: carName, with: "\(name)'s car") }

        app.buttons["Join Trip"].tap()
        let startTrip = app.buttons.matching(NSPredicate(format: "label IN %@", ["Start Trip", "Back to Map"])).firstMatch
        XCTAssertTrue(startTrip.waitForExistence(timeout: 20), "Didn't reach the lobby")

        // Tracking starts in the lobby; the Always explainer may come up once it does.
        let notNow = app.buttons["Not now"]
        if notNow.waitForExistence(timeout: 6) { notNow.tap() }
        startTrip.tap()
        XCTAssertTrue(app.buttons["Report"].waitForExistence(timeout: 20), "Didn't reach the map")
        if notNow.waitForExistence(timeout: 2) { notNow.tap() }
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }

    // MARK: Queries

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func exists(_ identifier: String) -> Bool { element(identifier).exists }

    private func hazardMarker() -> XCUIElement { element("hazard.marker") }

    private func approachBanner() -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'ahead in'")).firstMatch
    }

    /// Badge numbers of the convoy rows, front of the convoy first (top of the list).
    private func convoyOrder() -> [Int] {
        let prefix = "convoy.row."
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).allElementsBoundByIndex
        var seen = Set<Int>()
        return rows.sorted { $0.frame.minY < $1.frame.minY }.compactMap { row -> Int? in
            guard let n = Int(row.identifier.dropFirst(prefix.count)), seen.insert(n).inserted else { return nil }
            return n
        }
    }

    // MARK: Steps, waits, screenshots

    private func step(_ name: String, _ body: () throws -> Void) throws {
        print("QA STEP: \(name)")
        try body()
    }

    private func waitFor(
        _ what: String, timeout: TimeInterval, poll: TimeInterval = 2, _ condition: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: poll)
        }
        if condition() { return }
        shot("FAILED-\(what.replacingOccurrences(of: " ", with: "-"))")
        XCTFail("Timed out after \(Int(timeout)) s waiting for: \(what). Convoy order: \(convoyOrder())")
        throw WaitFailure()
    }

    private struct WaitFailure: Error {}

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: screens).appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
