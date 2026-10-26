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
///   approach alert; car 3 (scripted) reports an accident, both see it; B asks for a fuel stop with a message,
///   A taps OK on the pill, cars 3 and 4 say OK, A (the lead) taps We've stopped; B pauses and resumes sharing (A sees "Paused"), leaves (A sees the car go),
///   rejoins as a new car, A ends the trip and B's lobby says "Trip ended".
@MainActor
class TwoPhoneConvoyBase: ConvoyUITestCase {
    var sync = ""
    var who = "?"

    override var shotPrefix: String { "\(who)-" }

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
        if env["IKUT_USE_PRODUCTION"] == "1" { app.launchEnvironment["IKUT_USE_PRODUCTION"] = "1" } // Backend.swift
        allowPermissionPrompts(["Allow While Using App", "Allow Once", "Allow", "Don’t Allow"])
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

    override func step(_ name: String, _ body: () throws -> Void) throws {
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

    // MARK: Queries

    func hazardMarker(_ type: String) -> XCUIElement {
        labelled("label BEGINSWITH %@", "Hazard: \(type)")
    }

    /// The approach pill ("..., Show it on the map").
    var approachShowing: Bool {
        labelled("label CONTAINS %@", "Show it on the map").exists
    }

    // MARK: Shared flows

    func dismissNotNow() {
        let notNow = app.buttons["Not now"]
        if notNow.exists { notNow.tap() }
    }

    /// Lobby: 4 cars, all tracking, with the expected names.
    func checkLobbyHasFourCars() throws {
        // The cars sit below the fold of the sheet at medium.
        pullLobbySheetUp()
        try waitFor("lobby shows 4 of 4 ready", timeout: 90) { labelled("label CONTAINS %@", "4 of 4 ready").exists }
        // ("Wyna" only: typing an apostrophe may come out curly with smart punctuation.)
        for car in ["Wyna", "Hafiz’s Hilux", "Daniel’s City"] {
            XCTAssertTrue(labelled("label CONTAINS %@", car).exists, "lobby is missing \(car)")
        }
    }

    func openMap() throws {
        // The organizer's phone taps Start trip; the other waits for it, then taps Show map.
        XCTAssertTrue(lobbyActionButton.waitForExistence(timeout: 120), "The organizer didn't start the trip")
        lobbyActionButton.tap()
        XCTAssertTrue(app.buttons["Report"].waitForExistence(timeout: 30), "Didn't reach the map")
        app.dismissMapAsks(first: 3)
        // The convoy sheet opens collapsed; open it for the steps that read the rows.
        let expand = app.buttons["Expand convoy list"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5), "The convoy sheet should open collapsed")
        expand.tap()
        // The whole convoy in view, so every car and hazard marker is on screen.
        let fit = app.buttons["Fit whole convoy"]
        if fit.waitForExistence(timeout: 5) { fit.tap() }
    }

    /// A row of the lobby's tall sheet (Pause sharing, Leave trip, End trip), by identifier: pulls the sheet up if it
    /// is at medium, then scrolls the list until the row can be tapped.
    func tapLobbyRow(_ id: String) {
        let row = app.buttons[id]
        if !row.exists {
            let grabber = app.otherElements["Sheet Grabber"]
            if grabber.exists { grabber.swipeUp() }
        }
        var scrolls = 0
        while !(row.exists && row.isHittable), scrolls < 8 {
            app.collectionViews.firstMatch.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(row.exists && row.isHittable, "the lobby has no \(id) row")
        row.tap()
    }

    /// The map's back button, then the lobby's End trip row: the map no longer has trip controls.
    func endTripFromLobby() {
        app.buttons["Back to lobby"].tap()
        XCTAssertTrue(waitForLobby(timeout: 15), "no lobby after Back to lobby")
        tapLobbyRow("lobby.endTrip")
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

        try step("1. creates the trip (name, New trip, Where to?, lobby)") {
            startNewTrip(as: "Aisha")
            let search = app.textFields["Destination"]
            XCTAssertTrue(search.waitForExistence(timeout: 20), "Didn't reach Where to?")
            search.tap()
            search.typeText("Ipoh")
            let result = button(beginningWith: "Ipoh")
            XCTAssertTrue(result.waitForExistence(timeout: 30), "No search result for Ipoh")
            result.tap()
            tapCreateTrip()
            if !waitForLobby(timeout: 45) {
                let error = labelled("identifier == %@", "createTripError")
                XCTFail("Didn't reach the lobby (\(error.exists ? error.label : "no error shown"))")
                throw WaitFailure()
            }
            let notNow = app.buttons["Not now"]
            if notNow.waitForExistence(timeout: 4) { notNow.tap() }
            let code = readJoinCode()
            shot("01-lobby-created")
            mark("a.code", code)
        }

        try step("2. lobby shows B and the scripted cars 3 and 4") {
            try waitMark("cars.joined", timeout: long)
            try checkLobbyHasFourCars()
            shot("02-lobby-4-cars")
            mark("a.lobby4")
        }

        try step("3. Start trip opens the map; convoy order 1, 3, 2, 4") {
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

        try step("6. B's pit stop: button and pill, OK, We've stopped") {
            try waitMark("b.stopRequested", timeout: 240)
            // A request never opens the card by itself: the Pit stop button shows it, with a badge, and
            // the pill asks for one OK.
            let stopButton = app.buttons["stop.button"]
            try waitFor("A's Pit stop button shows the stop", timeout: 60) { stopButton.label.hasPrefix("Fuel stop") }
            XCTAssertFalse(element("stop.card").exists, "the stop card must not open by itself")
            shot("07-stop-button")
            // The pill says who and what; the pill's OK is the one tap. If the pill has already gone quiet
            // (20 s), the card has the same OK.
            let pillOK = app.buttons["stop.pill.button"]
            if pillOK.waitForExistence(timeout: 20) {
                shot("07a-stop-pill")
                pillOK.tap()
                try waitFor("You said OK on the pill", timeout: 15) { element("stop.pill.confirm").exists }
                shot("07b-stop-pill-ok")
            } else {
                stopButton.tap()
                let ok = app.buttons["stop.ok"]
                try waitFor("OK on A's stop card", timeout: 30) { ok.exists }
                ok.tap()
                app.buttons["stop.card.close"].tap()
            }
            mark("a.ok")
            try waitMark("cars.voted", timeout: 120)
            stopButton.tap()
            let stopped = app.buttons["stop.stopped"]
            try waitFor("the stop card on A, with We've stopped", timeout: 30) { stopped.exists }
            try waitFor("OK from all four cars (the asking car counts)", timeout: 60) {
                // The panel (and its button) is hidden under the open card: count the OK cars on the card.
                app.descendants(matching: .any)
                    .matching(NSPredicate(format: "identifier BEGINSWITH 'stop.voter.' AND label ENDSWITH ', OK'")).count >= 4
            }
            // B's passenger message is on the card in full.
            XCTAssertTrue(element("stop.message").exists, "the passenger's message is not on the card")
            shot("08-stop-card-oks")
            stopped.tap()
            try waitFor("the card closes by itself and the button is Pit stop again", timeout: 60) {
                !element("stop.card").exists && stopButton.label == "Pit stop"
            }
            try waitFor("convoy list back on A", timeout: 30) { convoyOrder().count == 4 }
            shot("10-stop-closed")
            mark("a.stopped")
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
            endTripFromLobby()
            confirm("End trip")
            // Ending the trip opens its recap (ae9efbb), not Home.
            try waitFor("recap after ending", timeout: 30) { labelled("label CONTAINS %@", "Share recap").exists }
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
            XCTAssertTrue(labelled("identifier == %@", "lobby.car.1").exists, "lobby is missing the organizer's car (car 1)")
            // A taps Start trip only after this mark, so until then B has only the waiting line, no Start trip.
            let waiting = element("lobbyWaiting")
            XCTAssertTrue(waiting.waitForExistence(timeout: 10), "B's lobby has no waiting line")
            XCTAssertEqual(waiting.label, "Waiting for Aisha to start the trip")
            XCTAssertFalse(app.buttons["Start trip"].exists, "A passenger must not be offered Start trip")
            shot("02-lobby-4-cars")
            mark("b.lobby4")
        }

        try step("3. B waits, then Show map opens the map; convoy order 1, 3, 2, 4") {
            try waitMark("a.lobby4", timeout: 120)
            try openMap()
            mark("b.map")
            try waitMark("go", timeout: 120)
            try waitFor("convoy order 1, 3, 2, 4", timeout: 120) { convoyOrder() == [1, 3, 2, 4] }
            XCTAssertTrue(element("convoy.row.2").label.contains("Wyna"), "row 2 should be this phone's car: \(element("convoy.row.2").label)")
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

        try step("6. asks for a fuel stop with a message from the stop card") {
            try waitMark("a.sawAccident", timeout: 120)
            let pitStop = app.buttons["stop.button"]
            try waitFor("Pit stop button", timeout: 20) { pitStop.exists && pitStop.isHittable }
            pitStop.tap()
            let fuel = app.buttons["stop.reason.stopFuel"]
            XCTAssertTrue(fuel.waitForExistence(timeout: 10), "the stop card didn't open")
            fuel.tap()
            // Nothing is sent until the explicit "Tell the convoy". The phone drives at 90 km/h, so a
            // message asks "Are you a passenger?" first.
            let addMessage = app.buttons["stop.addMessage"]
            try waitFor("Add a message is ready", timeout: 30) { addMessage.exists && addMessage.isHittable }
            shot("08-stop-card-ask")
            addMessage.tap()
            if app.buttons["stop.passenger"].waitForExistence(timeout: 5) {
                shot("08a-passenger-check")
                app.buttons["stop.passenger"].tap()
            }
            let field = element("stop.messageField")
            try waitFor("the message field", timeout: 15) { field.exists }
            field.tap()
            field.typeText("Need fuel, next R and R please")
            shot("08b-message-typed")
            app.buttons["stop.messageDone"].tap()
            let send = app.buttons["stop.send"]
            try waitFor("Tell the convoy is ready", timeout: 30) { send.exists && send.isEnabled }
            send.tap()
            // The card then shows the request with a row per car.
            try waitFor("request sent: the card shows the request", timeout: 90) { element("stop.message").exists || app.buttons["stop.cancel"].exists }
            shot("09-stop-requested")
            app.buttons["stop.card.close"].tap()
            try waitFor("B's own request on the button", timeout: 30) { pitStop.label.hasPrefix("Fuel stop") }
            mark("b.stopRequested")
        }

        try step("7. sees the OKs, then the stop closed by the lead") {
            try waitMark("a.ok", timeout: 240)
            let stopButton = app.buttons["stop.button"]
            try waitFor("the OKs on B's button (its own car, A, cars 3 and 4)", timeout: 60) {
                stopButton.label.contains("4 of 4 cars said OK")
            }
            shot("10-stop-oks")
            try waitMark("a.stopped", timeout: 120)
            try waitFor("the button is Pit stop again on B", timeout: 60) { stopButton.label == "Pit stop" }
            shot("11-stop-closed")
        }

        try step("8. pauses sharing in the lobby, then resumes") {
            app.buttons["Back to lobby"].tap()
            XCTAssertTrue(waitForLobby(timeout: 15), "no lobby after Back to lobby")
            tapLobbyRow("lobby.pause")
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
            tapLobbyRow("lobby.leaveTrip")
            confirm("Leave trip")
            let joinTrip = app.buttons["homeJoin"]
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
            XCTAssertFalse(app.buttons["lobby.leaveTrip"].exists || app.buttons["lobby.endTrip"].exists, "an ended trip has no options left")
            shot("16-trip-ended")
            mark("b.done")
        }
    }
}
