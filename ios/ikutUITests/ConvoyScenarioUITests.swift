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
///   5. stop request: the card has the message, this car taps OK, the card goes when the lead taps We've stopped
///
/// Skipped unless a code is given:
///
///     TEST_RUNNER_IKUT_JOIN_CODE=ABC123 TEST_RUNNER_IKUT_QA_SPEED=1 xcodebuild test ... -only-testing:ikutUITests/ConvoyScenarioUITests
///
/// Other variables: IKUT_JOIN_NAME (default "Faiz"), IKUT_QA_SPEED (the simulator's speed, scales waits),
/// IKUT_QA_SCREENS (directory for screenshots, default qa/screens in the repo).
@MainActor
final class ConvoyScenarioUITests: ConvoyUITestCase {
    private var speed = 1.0

    override var pollInterval: TimeInterval { 2 }

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
        allowPermissionPrompts()
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
            XCTAssertTrue(element("convoy.row.5").label.hasPrefix("Me"), "row 5 should be this phone's car: \(element("convoy.row.5").label)")
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
            XCTAssertTrue(text.contains("Show it on the map"), "banner: \(text)")
            // Let the convoy list finish folding and the camera settle on the hazard.
            Thread.sleep(forTimeInterval: 1.5)
            shot("06-approach-alert")
        }

        try step("7. Hazard marker clears once every car has passed it") {
            try waitFor("hazard marker gone", timeout: 90 / speed + 60) { !hazardMarker().exists }
            shot("07-hazard-cleared")
        }

        try step("8. Stop request: the button shows it, the card has its message, OK, then closed") {
            let stopButton = app.buttons["stop.button"]
            try waitFor("the Pit stop button shows the stop", timeout: 100 / speed + 60) { stopButton.label.hasPrefix("Fuel stop") }
            XCTAssertFalse(element("stop.card").exists, "the stop card must not open by itself")
            // A tap on the stop the button shows opens the card. Its buttons all work while the phone drives.
            stopButton.tap()
            let ok = app.buttons["stop.ok"]
            try waitFor("the stop card", timeout: 20) { element("stop.card").exists }
            try waitFor("the passenger's message on the card", timeout: 40 / speed + 30) { element("stop.message").exists }
            Thread.sleep(forTimeInterval: 1)
            shot("08-stop-request")
            // The phone is the fifth car: it taps OK (the card may already show it from the pill).
            if ok.exists, ok.label == "OK" {
                ok.tap()
                try waitFor("the OK is shown", timeout: 15) { app.buttons["stop.ok"].label == "You said OK" }
            }
            try waitFor("the card closes by itself after the lead says we've stopped", timeout: 120 / speed + 60) {
                !element("stop.card").exists && stopButton.label == "Pit stop"
            }
            try waitFor("convoy list back", timeout: 20) { convoyOrder().count == 5 }
            shot("09-after-stop")
        }
    }

    // MARK: Joining

    private func joinAndOpenMap(code: String, name: String) throws {
        openJoinForm(code: code, name: name, homeTimeout: 20)

        let newCar = button(beginningWith: "A new car")
        XCTAssertTrue(newCar.waitForExistence(timeout: 20), "Trip preview didn't load (is the code right and the emulator up?)")

        let joinNameField = app.textFields["Your name"]
        if joinNameField.exists, (joinNameField.value as? String) != name { replaceText(in: joinNameField, with: name) }

        newCar.tap()
        let carName = app.textFields["Car name"]
        if carName.waitForExistence(timeout: 5) { replaceText(in: carName, with: "\(name)'s car") }

        app.buttons["Join Trip"].tap()
        let startTrip = lobbyActionButton
        XCTAssertTrue(startTrip.waitForExistence(timeout: 20), "Didn't reach the lobby")

        // Tracking starts in the lobby; the Always explainer may come up once it does.
        let notNow = app.buttons["Not now"]
        if notNow.waitForExistence(timeout: 6) { notNow.tap() }
        startTrip.tap()
        app.dismissMapAsks(first: 3)
        XCTAssertTrue(app.buttons["Report"].waitForExistence(timeout: 20), "Didn't reach the map")
        if notNow.waitForExistence(timeout: 2) { notNow.tap() }
        // The convoy sheet opens collapsed; open it to read the rows.
        let expand = app.buttons["Expand convoy list"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5), "The convoy sheet should open collapsed")
        expand.tap()
    }

    // MARK: Queries

    private func exists(_ identifier: String) -> Bool { element(identifier).exists }

    private func hazardMarker() -> XCUIElement { element("hazard.marker") }

    private func approachBanner() -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'ahead in'")).firstMatch
    }
}
