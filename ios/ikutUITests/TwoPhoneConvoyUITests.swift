import XCTest

/// Two real phones in one convoy (see qa/README.md, "Two-phone convoy"). `qa/run-convoy2.mjs` runs
/// `ConvoyOrganizerUITests` on one simulator and `ConvoyJoinerUITests` on another at the same time,
/// drives both simulators along the trip's route and plays two scripted cars (3 and 4).
///
/// The two tests and the script take turns through marker files in a shared directory on the Mac
/// (`TEST_RUNNER_IKUT_SYNC_DIR`): each side writes `<who>.<step>` when it is done with a step and waits
/// for the other side's file before the next one. A file named `abort` ends every wait at once.
///
/// Phone A (organizer, car 1) and phone B (joiner, car 2):
///   A creates the trip, B joins with the code, both lobbies show 4 cars once the script joins cars 3 and 4,
///   both open the map; convoy order 1, 3, 2, 4 on both; A reports debris, B sees the marker and gets the
///   approach alert; car 3 (scripted) reports an accident, both see it; B asks for a fuel stop, A agrees,
///   pins and resolves it; B pauses and resumes sharing (A sees "Paused"), leaves (A sees the car go),
///   rejoins as a new car, A ends the trip and B's lobby says "Trip ended".
@MainActor
class TwoPhoneConvoyBase: XCTestCase {
    var app: XCUIApplication!
    var sync = ""
    var screens = ""
    var who = "?"

    override func setUp() {
        continueAfterFailure = false
    }

    /// Reads the environment and launches the app. Throws XCTSkip outside `run-convoy2.mjs`.
    func launch(as who: String) throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["IKUT_SYNC_DIR"] else {
            throw XCTSkip("Run through qa/run-convoy2.mjs (TEST_RUNNER_IKUT_SYNC_DIR is not set)")
        }
        self.who = who
        sync = dir
        screens = env["IKUT_QA_SCREENS"] ?? (dir as NSString).appendingPathComponent("screens")
        try? FileManager.default.createDirectory(atPath: screens, withIntermediateDirectories: true)

        app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "Permissions") { alert in
            for label in ["Allow While Using App", "Allow Once", "Allow", "Don’t Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
    }

    // MARK: Marker files

    func mark(_ name: String, _ content: String = "") {
        let path = (sync as NSString).appendingPathComponent(name)
        FileManager.default.createFile(atPath: path, contents: Data(content.utf8))
        print("QA MARK: \(name)")
    }

    /// Waits for the other side's marker and returns its content.
    @discardableResult
    func waitMark(_ name: String, timeout: TimeInterval) throws -> String {
        let path = (sync as NSString).appendingPathComponent(name)
        let abort = (sync as NSString).appendingPathComponent("abort")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: abort) {
                XCTFail("Aborted while waiting for \(name): \((try? String(contentsOfFile: abort, encoding: .utf8)) ?? "")")
                throw WaitFailure()
            }
            if let s = try? String(contentsOfFile: path, encoding: .utf8), FileManager.default.fileExists(atPath: path) {
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        shot("FAILED-mark-\(name)")
        XCTFail("Timed out after \(Int(timeout)) s waiting for marker \(name)")
        throw WaitFailure()
    }

    // MARK: Steps and checks

    func step(_ name: String, _ body: () throws -> Void) throws {
        print("QA STEP: \(who) \(name)")
        do {
            try body()
            print("QA CHECK: PASS \(who) \(name)")
        } catch {
            print("QA CHECK: FAIL \(who) \(name)")
            mark("abort", "\(who) failed: \(name)")
            throw error
        }
    }

    func waitFor(_ what: String, timeout: TimeInterval, poll: TimeInterval = 1, _ condition: () -> Bool) throws {
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

    struct WaitFailure: Error {}

    func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let file = "\(who)-\(name).png"
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

    func hazardMarker(_ type: String) -> XCUIElement {
        labelled("label BEGINSWITH %@", "Hazard: \(type)")
    }

    /// The approach pill ("..., Show it on the map").
    var approachShowing: Bool {
        labelled("label CONTAINS %@", "Show it on the map").exists
    }

    /// Badge numbers of the convoy rows, front of the convoy first.
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

    func dismissNotNow() {
        let notNow = app.buttons["Not now"]
        if notNow.exists { notNow.tap() }
    }


    func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }

    /// Home (or Welcome) to the lobby of `code`, as a new car named "<name>'s car".
    func join(code: String, name: String) throws {
        let joinButton = app.buttons
            .matching(NSPredicate(format: "label IN %@", ["Join with Code or QR", "Join Trip"])).firstMatch
        XCTAssertTrue(joinButton.waitForExistence(timeout: 30), "Home didn't show Join Trip")
        joinButton.tap()

        let sheetName = app.textFields["Your name"]
        if sheetName.waitForExistence(timeout: 3), app.buttons["Continue"].exists {
            sheetName.tap()
            sheetName.typeText(name)
            app.buttons["Continue"].tap()
        }
        app.tap() // lets the interruption monitor handle a permission prompt

        let codeField = app.textFields["Trip code"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 15), "Join screen didn't show the code field")
        codeField.tap()
        codeField.typeText(code)

        let newCar = button(beginningWith: "A new car")
        XCTAssertTrue(newCar.waitForExistence(timeout: 30), "Trip preview didn't load for \(code)")
        let joinNameField = app.textFields["Your name"]
        if joinNameField.exists, (joinNameField.value as? String) != name { replaceText(in: joinNameField, with: name) }
        newCar.tap()
        let carName = app.textFields["Car name"]
        if carName.waitForExistence(timeout: 5) { replaceText(in: carName, with: "\(name)'s car") }

        app.buttons["Join Trip"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label IN %@", ["Start Trip", "Back to Map"])).firstMatch.waitForExistence(timeout: 30), "Didn't reach the lobby")
        let notNow = app.buttons["Not now"]
        if notNow.waitForExistence(timeout: 4) { notNow.tap() }
    }

    /// Lobby: 4 cars, all tracking, with the expected names.
    func checkLobbyHasFourCars() throws {
        try waitFor("lobby shows 4 of 4 ready", timeout: 90) { labelled("label CONTAINS %@", "4 of 4 ready").exists }
        // ("Wyna" only: typing an apostrophe may come out curly with smart punctuation.)
        for car in ["Wyna", "Hafiz’s Hilux", "Daniel’s City"] {
            XCTAssertTrue(labelled("label CONTAINS %@", car).exists, "lobby is missing \(car)")
        }
    }

    func openMap() throws {
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Start Trip", "Back to Map"])).firstMatch.tap()
        XCTAssertTrue(app.buttons["Report"].waitForExistence(timeout: 30), "Didn't reach the map")
        if app.buttons["Not now"].waitForExistence(timeout: 3) { app.buttons["Not now"].tap() }
        // The convoy sheet opens collapsed; open it for the steps that read the rows.
        let expand = app.buttons["Expand convoy list"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5), "The convoy sheet should open collapsed")
        expand.tap()
        // The whole convoy in view, so every car and hazard marker is on screen.
        let fit = app.buttons["Fit whole convoy"]
        if fit.waitForExistence(timeout: 5) { fit.tap() }
    }

    func openTripMenuItem(_ menu: String, _ item: String) {
        app.buttons[menu].tap()
        let button = app.buttons[item]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(menu) has no \(item)")
        button.tap()
    }

    /// Taps the destructive button of a confirmation dialog (it repeats the menu item's title).
    func confirm(_ title: String) {
        let buttons = app.buttons.matching(NSPredicate(format: "label == %@", title))
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, buttons.count == 0 { Thread.sleep(forTimeInterval: 0.2) }
        buttons.element(boundBy: buttons.count - 1).tap()
    }
}

/// Phone A: the organizer, car 1, at the front of the convoy.
final class ConvoyOrganizerUITests: TwoPhoneConvoyBase {
    func testOrganizer() throws {
        try launch(as: "A")
        let long: TimeInterval = 300

        try step("1. creates the trip (name, New Trip, Where to?, lobby)") {
            let getStarted = app.buttons["Get Started"]
            if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }
            let newTrip = app.buttons["New Trip"]
            XCTAssertTrue(newTrip.waitForExistence(timeout: 20), "Home didn't show New Trip")
            newTrip.tap()
            let sheetName = app.textFields["Your name"]
            if sheetName.waitForExistence(timeout: 3), app.buttons["Continue"].exists {
                sheetName.tap()
                sheetName.typeText("Aisha")
                app.buttons["Continue"].tap()
            }
            app.tap()
            let search = app.textFields["Destination"]
            XCTAssertTrue(search.waitForExistence(timeout: 20), "Didn't reach Where to?")
            search.tap()
            search.typeText("Ipoh")
            let result = button(beginningWith: "Ipoh")
            XCTAssertTrue(result.waitForExistence(timeout: 30), "No search result for Ipoh")
            result.tap()
            if !app.buttons["Start Trip"].waitForExistence(timeout: 45) {
                let error = labelled("label BEGINSWITH %@", "Error: ")
                XCTFail("Didn't reach the lobby (\(error.exists ? error.label : "no error shown"))")
                throw WaitFailure()
            }
            let notNow = app.buttons["Not now"]
            if notNow.waitForExistence(timeout: 4) { notNow.tap() }
            let codeLabel = labelled("label BEGINSWITH %@", "Join code ")
            XCTAssertTrue(codeLabel.waitForExistence(timeout: 15), "Lobby shows no join code")
            let code = codeLabel.label.replacingOccurrences(of: "Join code ", with: "").replacingOccurrences(of: " ", with: "")
            XCTAssertEqual(code.count, 6, "code: \(code)")
            shot("01-lobby-created")
            mark("a.code", code)
        }

        try step("2. lobby shows B and the scripted cars 3 and 4") {
            try waitMark("cars.joined", timeout: long)
            try checkLobbyHasFourCars()
            shot("02-lobby-4-cars")
            mark("a.lobby4")
        }

        try step("3. Start Trip opens the map; convoy order 1, 3, 2, 4") {
            try waitMark("b.lobby4", timeout: 120)
            try openMap()
            mark("a.map")
            try waitMark("go", timeout: 120)
            try waitFor("convoy order 1, 3, 2, 4", timeout: 120) { convoyOrder() == [1, 3, 2, 4] }
            XCTAssertTrue(element("convoy.row.2").label.contains("Wyna"), "row 2: \(element("convoy.row.2").label)")
            shot("03-map-order")
            mark("a.order")
        }

        try step("4. reports debris from the Report sheet; the marker shows") {
            try waitMark("b.order", timeout: 180)
            app.buttons["Report"].tap()
            let debris = app.buttons["Debris"]
            XCTAssertTrue(debris.waitForExistence(timeout: 10), "Report sheet didn't open")
            try waitFor("report sheet has a location fix", timeout: 30) { debris.isEnabled }
            shot("04-report-sheet")
            debris.tap()
            try waitFor("toast Reported debris", timeout: 15, poll: 0.3) { labelled("label CONTAINS[c] %@", "Reported debris").exists }
            mark("a.reported")
            try waitFor("debris marker on A's map", timeout: 30) { hazardMarker("Debris").exists }
            shot("05-debris-marker")
        }

        try step("5. sees the scripted car's accident report") {
            try waitMark("cars.reported", timeout: 240)
            try waitFor("accident marker on A's map", timeout: 60) { hazardMarker("Accident").exists }
            XCTAssertFalse(approachShowing, "the organizer is ahead of both hazards and must not be alerted")
            shot("06-accident-marker")
            mark("a.sawAccident")
        }

        try step("6. B's pit stop: card, agree, scripted votes, pin, resolve") {
            try waitMark("b.stopRequested", timeout: 240)
            let agree = app.buttons["Agree to Stop"]
            try waitFor("stop card on A", timeout: 60) { agree.exists }
            shot("07-stop-card")
            agree.tap()
            // Agreeing folds the card into its chip; a tap opens it again.
            let chip = app.buttons["stopChip"]
            try waitFor("A's card folded after agreeing", timeout: 20) { chip.exists && !agree.exists }
            shot("07b-stop-chip")
            chip.tap()
            try waitFor("A's agreement shown", timeout: 20) { button(beginningWith: "Agreed").exists }
            try waitMark("cars.voted", timeout: 120)
            try waitFor("votes from all four cars", timeout: 60) {
                let votes = labelled("label BEGINSWITH %@", "Votes: ")
                return votes.exists && votes.label.contains("of 4 agreed")
                    && !votes.label.hasPrefix("Votes: 0") && !votes.label.hasPrefix("Votes: 1")
                    && !votes.label.hasPrefix("Votes: 2")
            }
            let pin = app.buttons["Pin this stop"].exists ? app.buttons["Pin this stop"] : button(beginningWith: "Pin ")
            try waitFor("a pin button", timeout: 30) { pin.exists }
            shot("08-stop-votes")
            pin.tap()
            try waitFor("stop pinned for everyone", timeout: 30) { button(beginningWith: "Agreed · Pinned").exists }
            shot("09-stop-pinned")
            mark("a.pinned")
            try waitMark("b.sawPin", timeout: 120)
            let arrived = app.buttons["Everyone has arrived"]
            XCTAssertTrue(arrived.waitForExistence(timeout: 10), "lead has no Everyone has arrived")
            arrived.tap()
            try waitFor("stop card gone on A", timeout: 60) {
                !button(beginningWith: "Agreed").exists && !agree.exists && !app.buttons["stopChip"].exists
            }
            try waitFor("convoy list back on A", timeout: 30) { convoyOrder().count == 4 }
            shot("10-stop-resolved")
            mark("a.resolved")
        }

        try step("7. sees B paused, then sharing again") {
            try waitMark("b.paused", timeout: 180)
            try waitFor("row 2 says Paused", timeout: 60) { element("convoy.row.2").label.contains("Paused") }
            shot("11-b-paused")
            mark("a.sawPaused")
            try waitMark("b.resumed", timeout: 120)
            try waitFor("row 2 sharing again", timeout: 90) {
                let row = element("convoy.row.2")
                return row.exists && !row.label.contains("Paused") && !row.label.contains("Last seen")
            }
            shot("12-b-resumed")
            mark("a.sawResumed")
        }

        try step("8. B leaves: its car goes from A's list") {
            try waitMark("b.left", timeout: 180)
            try waitFor("car 2 gone", timeout: 90) { !element("convoy.row.2").exists }
            shot("13-b-left")
            mark("a.sawLeft")
        }

        try step("9. B rejoins as car 5; A ends the trip") {
            try waitMark("b.rejoined", timeout: 240)
            try waitFor("car 5 in A's list", timeout: 90) { element("convoy.row.5").exists }
            shot("14-b-rejoined")
            openTripMenuItem("Trip menu", "End trip")
            confirm("End trip")
            // Ending the trip opens its recap (ae9efbb), not Home.
            try waitFor("recap after ending", timeout: 30) { labelled("label CONTAINS %@", "Share Recap").exists }
            shot("15-ended-recap")
            mark("a.ended")
        }
        try waitMark("b.done", timeout: 120)
    }
}

/// Phone B: joins as car 2 and drives behind A.
final class ConvoyJoinerUITests: TwoPhoneConvoyBase {
    func testJoiner() throws {
        try launch(as: "B")
        let long: TimeInterval = 400
        var code = ""

        try step("1. joins with A's code as a new car") {
            code = try waitMark("code", timeout: long)
            try join(code: code, name: "Wyna")
            shot("01-lobby-joined")
            mark("b.lobby")
        }

        try step("2. lobby shows A and the scripted cars 3 and 4") {
            try waitMark("cars.joined", timeout: 180)
            try checkLobbyHasFourCars()
            XCTAssertTrue(labelled("label CONTAINS %@", "Lead").exists, "lobby is missing the organizer's (lead) car")
            shot("02-lobby-4-cars")
            mark("b.lobby4")
        }

        try step("3. Start Trip opens the map; convoy order 1, 3, 2, 4") {
            try waitMark("a.lobby4", timeout: 120)
            try openMap()
            mark("b.map")
            try waitMark("go", timeout: 120)
            try waitFor("convoy order 1, 3, 2, 4", timeout: 120) { convoyOrder() == [1, 3, 2, 4] }
            XCTAssertTrue(element("convoy.row.2").label.hasPrefix("Me"), "row 2 should be this phone's car: \(element("convoy.row.2").label)")
            shot("03-map-order")
            mark("b.order")
        }

        try step("4. sees A's debris marker, then the approach alert") {
            try waitMark("a.reported", timeout: 180)
            try waitFor("debris marker on B's map", timeout: 60) { hazardMarker("Debris").exists }
            shot("04-debris-marker")
            try waitFor("approach alert for the debris", timeout: 150, poll: 0.5) { approachShowing }
            // Let the convoy list finish folding and the camera settle on the hazard.
            Thread.sleep(forTimeInterval: 1.5)
            shot("05-approach-alert")
            let title = labelled("label CONTAINS %@", "Debris")
            XCTAssertTrue(title.exists, "the approach alert should name the debris")
            mark("b.alerted")
        }

        try step("5. sees the scripted car's accident, and its approach alert") {
            try waitMark("cars.reported", timeout: 120)
            try waitFor("accident marker on B's map", timeout: 60) { hazardMarker("Accident").exists }
            shot("06-accident-marker")
            try waitFor("approach alert for the accident", timeout: 120, poll: 0.5) {
                labelled("label CONTAINS %@", "Accident ahead").exists
            }
            // Let the convoy list finish folding (it may be re-opening after the debris).
            Thread.sleep(forTimeInterval: 1.5)
            shot("07-accident-alert")
            mark("b.sawAccident")
        }

        try step("6. asks for a fuel stop from the Pit stop sheet") {
            try waitMark("a.sawAccident", timeout: 120)
            let pitStop = app.buttons["Pit stop"]
            try waitFor("Pit stop button", timeout: 20) { pitStop.exists && pitStop.isHittable }
            pitStop.tap()
            let fuel = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Fuel'")).firstMatch
            XCTAssertTrue(fuel.waitForExistence(timeout: 10), "Pit stop sheet didn't open")
            fuel.tap()
            Thread.sleep(forTimeInterval: 1)
            shot("08-pit-stop-sheet")
            // It finds a place ahead (or none) and sends by itself after a 5 s countdown.
            try waitFor("request sent and the sheet closed", timeout: 90) { !app.staticTexts["Need gas"].exists }
            // The requester's own card starts folded into its chip.
            try waitFor("B's own request chip", timeout: 30) { app.buttons["stopChip"].exists }
            shot("09-stop-requested")
            mark("b.stopRequested")
        }

        try step("7. sees the lead's pin, then the stop resolved") {
            try waitMark("a.pinned", timeout: 240)
            try waitFor("pinned place on B's card", timeout: 60) {
                labelled("label CONTAINS %@", "pinned by the lead car").exists
                    || button(beginningWith: "Agreed · Pinned").exists
            }
            shot("10-stop-pinned")
            mark("b.sawPin")
            try waitMark("a.resolved", timeout: 120)
            try waitFor("stop card gone on B", timeout: 60) {
                !button(beginningWith: "Agreed").exists && !app.buttons["stopChip"].exists
            }
            shot("11-stop-resolved")
        }

        try step("8. pauses sharing in the lobby, then resumes") {
            openTripMenuItem("Trip menu", "Back to lobby")
            XCTAssertTrue(app.buttons["Trip options"].waitForExistence(timeout: 15), "lobby has no Trip options")
            openTripMenuItem("Trip options", "Pause sharing")
            try waitFor("paused banner", timeout: 20) { labelled("label CONTAINS %@", "Sharing paused").exists }
            shot("12-paused")
            mark("b.paused")
            try waitMark("a.sawPaused", timeout: 120)
            let resume = app.buttons["Resume"]
            XCTAssertTrue(resume.waitForExistence(timeout: 5), "paused banner has no Resume")
            resume.tap()
            // A started trip's lobby says "Trip in progress", not "Sharing location"; A checks the car is live.
            try waitFor("sharing again", timeout: 30) {
                !labelled("label CONTAINS %@", "Sharing paused").exists && !app.buttons["Resume"].exists
            }
            shot("13-resumed")
            mark("b.resumed")
        }

        try step("9. leaves the trip") {
            try waitMark("a.sawResumed", timeout: 150)
            openTripMenuItem("Trip options", "Leave trip")
            confirm("Leave trip")
            let joinTrip = app.buttons["Join Trip"]
            XCTAssertTrue(joinTrip.waitForExistence(timeout: 30), "B didn't return Home after leaving")
            shot("14-left-home")
            mark("b.left")
        }

        try step("10. rejoins as a new car; sees the trip end") {
            try waitMark("a.sawLeft", timeout: 150)
            try join(code: code, name: "Wyna")
            shot("15-rejoined")
            mark("b.rejoined")
            try waitMark("a.ended", timeout: 240)
            try waitFor("lobby says Trip ended", timeout: 60) { labelled("label CONTAINS %@", "Trip ended").exists }
            XCTAssertFalse(app.buttons["Trip options"].exists, "an ended trip has no options left")
            shot("16-trip-ended")
            mark("b.done")
        }
    }
}
