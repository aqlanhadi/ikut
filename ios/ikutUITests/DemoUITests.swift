import XCTest

/// The phones of the two live demos (`qa/demo.mjs`, `qa/demo-two-cars.mjs`; see qa/README.md, "Live demo").
/// A phone is the organizer:
///   DemoOrganizerUITests  phone 1 in both demos: Aisha creates the trip, starts it, and then does whatever the script
///                         asks through marker files (report debris, OK on the stop, We've stopped)
///   DemoPassengerUITests  phone 2 of the organizer demo: Faiz joins Aisha's car as a passenger (co-pilot)
///   DemoOwnCarUITests     phone 2 of the two-cars demo: Faiz joins as "A new car" and drives behind Aisha
///
/// Same marker-file handshake as the two-phone convoy test (`TwoPhoneConvoyBase`, TEST_RUNNER_IKUT_SYNC_DIR), with the
/// script's markers `code`, `cars.joined`, `report.a`, `report.b`, `stop.b`, `agree`, `arrive`, `end`. After setup the
/// tests only follow the script and hold the map open until `end` (or TEST_RUNNER_IKUT_HOLD_SECONDS). Cosmetic checks
/// are logged ("QA CHECK: NOTE ...") and never fail the demo; a failed core step (a tap that does the demo's job, the
/// request showing up) is logged as FAIL and fails the test at the end, after the demo has played out.
@MainActor
class DemoBase: TwoPhoneConvoyBase {
    var coreFailures: [String] = []
    var holdUntil = Date()
    let env = ProcessInfo.processInfo.environment
    var demoName: String { env["IKUT_DEMO_NAME"] ?? "Aisha" }
    var stopButton: XCUIElement { app.buttons["stop.button"] }

    func startDemo(as who: String) throws {
        try launch(as: who)
        holdUntil = Date().addingTimeInterval(env["IKUT_HOLD_SECONDS"].flatMap(Double.init) ?? 1500)
    }

    // MARK: Marker loop and soft checks

    func hasMarker(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: (sync as NSString).appendingPathComponent(name))
    }

    /// Does each action once, when its marker appears, until `end` (or the hold runs out, or the script aborts).
    func follow(_ actions: [(String, () -> Void)]) {
        var done = Set<String>()
        while Date() < holdUntil, !hasMarker("end"), !hasMarker("abort") {
            for (marker, action) in actions where !done.contains(marker) && hasMarker(marker) {
                done.insert(marker)
                print("QA STEP: \(who) \(marker)")
                action()
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        shot("end-of-demo")
    }

    /// Last line of every test, after anything done at the end: fails the test if a core step failed.
    func finish() {
        XCTAssertTrue(coreFailures.isEmpty, "Core steps failed: \(coreFailures.joined(separator: "; "))")
    }

    func note(_ name: String, _ pass: Bool, core: Bool = false) {
        print("QA CHECK: \(pass ? "PASS" : (core ? "FAIL" : "NOTE")) \(who) \(name)")
        if !pass, core { coreFailures.append(name) }
    }

    /// Waits for the condition, logs the outcome, carries on either way.
    @discardableResult
    func soft(_ name: String, timeout: TimeInterval, core: Bool = false, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var ok = condition()
        while !ok, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            ok = condition()
        }
        note(name, ok, core: core)
        if !ok { shot("MISSING-\(name.replacingOccurrences(of: " ", with: "-"))") }
        return ok
    }

    // MARK: Flows

    /// Waits for the lobby, dismissing the "Keep sharing while the screen is off" sheet (Not now) that covers it.
    func waitForLobby(timeout: TimeInterval) -> Bool {
        let start = lobbyPresence
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.buttons["Not now"].exists { app.buttons["Not now"].tap(); Thread.sleep(forTimeInterval: 1) }
            if start.exists, start.isHittable { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    /// Lobby to the map (no "Fit whole convoy": the map keeps following the car).
    func openDemoMap() {
        let start = lobbyActionButton
        // A passenger waits for the organizer to start the trip: the button is Show map once it has; tap until the map shows.
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline, !app.buttons["Report"].exists {
            if app.buttons["Not now"].exists { app.buttons["Not now"].tap() }
            else if start.exists, start.isHittable { start.tap() }
            Thread.sleep(forTimeInterval: 3)
        }
        // The map's asks (road alerts, keep the screen on) come one after another once it shows.
        app.dismissMapAsks(first: 3)
        note("on the map", app.buttons["Report"].exists, core: true)
    }

    /// Joins `code` from Home. `ridingIn`: the car tile to pick as a passenger; otherwise a new car named `carName`.
    func joinDemo(code: String, name: String, ridingIn tile: String? = nil, carName: String? = nil) throws {
        openJoinForm(code: code, name: name)

        let choice = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", tile ?? "A new car")).firstMatch
        if !choice.waitForExistence(timeout: 30) { shot("FAILED-no-tile") }
        XCTAssertTrue(choice.exists, "Trip preview didn't show \(tile ?? "A new car") for \(code)")
        let joinNameField = app.textFields["Your name"]
        if joinNameField.exists, (joinNameField.value as? String) != name { replaceText(in: joinNameField, with: name) }
        choice.tap()
        if tile != nil {
            // The car's tile sets the role from whether it is tracked already; say Passenger either way.
            let passenger = labelled("label == %@", "Passenger")
            if passenger.waitForExistence(timeout: 5) { passenger.tap() }
            shot("join-as-passenger")
            let joinIn = button(beginningWith: "Join in ")
            XCTAssertTrue(joinIn.waitForExistence(timeout: 5), "No Join in … button")
            joinIn.tap()
        } else {
            let carField = app.textFields["Car name"]
            if carField.waitForExistence(timeout: 5), let carName { replaceText(in: carField, with: carName) }
            shot("join-as-new-car")
            app.buttons["Join trip"].tap()
        }
        XCTAssertTrue(waitForLobby(timeout: 60), "Didn't reach the lobby")
    }

    func reportDebris() {
        guard app.buttons["Report"].exists else { note("Report button", false, core: true); return }
        app.buttons["Report"].tap()
        let debris = app.buttons["Debris"]
        guard debris.waitForExistence(timeout: 10) else { note("Report sheet opened", false, core: true); return }
        soft("report sheet has a location fix", timeout: 30) { debris.isEnabled }
        shot("report-sheet")
        debris.tap()
        soft("toast Reported debris", timeout: 15) { labelled("label CONTAINS[c] %@", "Reported debris").exists }
        soft("debris marker on the map", timeout: 40) { hazardMarker("Debris").exists }
        shot("debris-marker")
    }

    /// Pit stop > Fuel > Add a message > Tell the convoy: Faiz asks with a passenger's message.
    func requestFuelStop() {
        let pitStop = stopButton
        guard soft("Pit stop button", timeout: 20, core: true, {
            // The "Get road alerts?" question can still be up over the map.
            if app.buttons["Not now"].exists { app.buttons["Not now"].tap(); Thread.sleep(forTimeInterval: 1) }
            return pitStop.exists && pitStop.isHittable
        }) else { return }
        pitStop.tap()
        let fuel = app.buttons["stop.reason.stopFuel"]
        guard fuel.waitForExistence(timeout: 10) else { note("the stop card opened", false, core: true); return }
        shot("pit-stop-tiles")
        fuel.tap()
        let addMessage = app.buttons["stop.addMessage"]
        guard soft("Add a message is ready", timeout: 30, core: true, { addMessage.exists && addMessage.isHittable }) else { return }
        shot("pit-stop-fuel")
        addMessage.tap()
        // A moving phone asks "Are you a passenger?" before the message field.
        if app.buttons["stop.passenger"].waitForExistence(timeout: 5) {
            shot("pit-stop-passenger")
            app.buttons["stop.passenger"].tap()
        }
        let field = element("stop.messageField")
        guard soft("the message field", timeout: 15, core: true, { field.exists }) else { return }
        field.tap()
        field.typeText("Low on fuel, next R&R please")
        shot("pit-stop-message")
        app.buttons["stop.messageDone"].tap()
        let send = app.buttons["stop.send"]
        guard soft("Tell the convoy is ready", timeout: 30, core: true, { send.exists && send.isEnabled }) else { return }
        send.tap()
        soft("the request is sent and the card shows the message", timeout: 90, core: true) { element("stop.message").exists }
        shot("stop-requested")
        app.buttons["stop.card.close"].tap()
        soft("Faiz's own request on the button", timeout: 30) { pitStop.label.hasPrefix("Fuel stop") }
        mark("b.stopRequested")
    }

    /// Waits for the lead car's We've stopped: the request closes and the button is Pit stop again.
    func watchStopped() {
        soft("the button is Pit stop again after We've stopped", timeout: 120, core: true) { stopButton.label == "Pit stop" }
        shot("stop-closed")
        mark("b.sawStopped")
    }
}

/// Phone 1 of both demos: Aisha, organizer, lead car.
final class DemoOrganizerUITests: DemoBase {
    func testOrganizer() throws {
        try startDemo(as: "A")

        try step("1. creates the trip (name, New trip, Where to? Ipoh, lobby)") {
            startNewTrip(as: demoName)
            let search = app.textFields["Destination"]
            // A first-run sign-in can fail once ("Network error ..." under the name field); Continue tries again.
            for _ in 0..<12 where !search.exists {
                if search.waitForExistence(timeout: 4) { break }
                if app.buttons["Continue"].exists { app.buttons["Continue"].tap() }
            }
            if !search.exists { shot("FAILED-no-destination-field") }
            XCTAssertTrue(search.exists, "Didn't reach Where to?")
            search.tap()
            search.typeText("Ipoh")
            let result = button(beginningWith: "Ipoh")
            XCTAssertTrue(result.waitForExistence(timeout: 30), "No search result for Ipoh")
            result.tap()
            if !waitForLobby(timeout: 120) {
                shot("FAILED-no-lobby")
                let error = labelled("identifier == %@", "createTripError")
                XCTFail("Didn't reach the lobby (\(error.exists ? error.label : "no error shown"))")
                throw WaitFailure()
            }
            let code = readJoinCode()
            shot("lobby-created")
            mark("a.code", code)
        }

        try step("2. lobby with the other cars; Start trip opens the map") {
            try waitMark("cars.joined", timeout: 420)
            soft("lobby shows Faiz and the scripted cars", timeout: 60) {
                labelled("label CONTAINS %@", "Hafiz").exists && labelled("label CONTAINS %@", "Faiz").exists
            }
            shot("lobby-full")
            openDemoMap()
            mark("a.map")
        }

        follow([("report.a", reportDebris), ("agree", okOnTheStop), ("arrive", weHaveStopped)])
        if env["IKUT_END_TRIP"] == "1" { endTrip() }
        finish()
    }

    /// --end-trip, and always against production: the organizer ends the trip from the lobby's Trip options menu.
    func endTrip() {
        guard app.buttons["Back to lobby"].exists else { note("Back to lobby to end the trip", false, core: true); return }
        endTripFromLobby()
        confirm("End trip")
        soft("the trip ended and phone 1 shows the recap", timeout: 30, core: true) { app.buttons["Share recap"].exists }
    }

    /// The organizer's Pit stop button shows the stop. If her car is asked, she taps OK on the pill (or the card);
    /// the card then stays open so the OKs can be watched coming in.
    func okOnTheStop() {
        guard soft("the Pit stop button shows the stop on phone 1", timeout: 90, core: true, { stopButton.label.hasPrefix("Fuel stop") })
        else { return }
        shot("stop-button")
        let pillOK = app.buttons["stop.pill.button"]
        if pillOK.exists {
            shot("stop-pill")
            pillOK.tap()
        }
        stopButton.tap()
        guard soft("the stop card shows the request", timeout: 30, core: true, { element("stop.message").exists }) else { return }
        let ok = app.buttons["stop.ok"]
        // Her own car asked (the passenger demo), or the pill already said OK: nothing to tap.
        if ok.exists, ok.label == "OK" { ok.tap() }
        shot("stop-card-oks")
        mark("a.ok")
    }

    /// Everyone has pulled in: We've stopped closes the request on every phone.
    func weHaveStopped() {
        let stopped = app.buttons["stop.stopped"]
        guard soft("We've stopped is on the card", timeout: 30, core: true, { stopped.exists }) else { return }
        stopped.tap()
        soft("the card closes and the button is Pit stop again on phone 1", timeout: 60, core: true) {
            !element("stop.card").exists && stopButton.label == "Pit stop"
        }
        shot("stop-closed")
        mark("a.stopped")
    }
}

/// Phone 2 of the organizer demo: Faiz, a passenger in Aisha's car. He reports the debris from his Report sheet.
final class DemoPassengerUITests: DemoBase {
    func testPassenger() throws {
        try startDemo(as: "B")

        try step("1. joins Aisha's car as a passenger with the code") {
            let code = try waitMark("code", timeout: 420)
            try joinDemo(code: code, name: demoName, ridingIn: "Aisha")
            shot("lobby-joined")
            mark("b.lobby")
        }

        try step("2. lobby with the other cars; opens the map once Aisha has started the trip") {
            try waitMark("cars.joined", timeout: 240)
            soft("lobby shows Aisha and the scripted cars", timeout: 60) {
                labelled("label CONTAINS %@", "Hafiz").exists && labelled("label CONTAINS %@", "Aisha").exists
            }
            shot("lobby-full")
            try waitMark("a.map", timeout: 240)
            openDemoMap()
            mark("b.map")
        }

        follow([("report.b", reportDebris), ("stop.b", requestFuelStop), ("a.stopped", watchStopped)])
        finish()
    }
}

/// Phone 2 of the two-cars demo: Faiz, his own car ("Faiz’s Axia", location sharing on), driving behind Aisha.
final class DemoOwnCarUITests: DemoBase {
    func testOwnCar() throws {
        try startDemo(as: "B")

        try step("1. joins as a new car with the code, location sharing on") {
            let code = try waitMark("code", timeout: 420)
            try joinDemo(code: code, name: demoName, carName: env["IKUT_CAR_NAME"] ?? "\(demoName)’s car")
            shot("lobby-joined")
            mark("b.lobby")
        }

        try step("2. lobby with the other cars; opens the map once Aisha has started the trip") {
            try waitMark("cars.joined", timeout: 240)
            soft("lobby shows Aisha and the scripted cars", timeout: 60) {
                labelled("label CONTAINS %@", "Hafiz").exists && labelled("label CONTAINS %@", "Aisha").exists
            }
            shot("lobby-full")
            try waitMark("a.map", timeout: 240)
            openDemoMap()
            mark("b.map")
        }

        follow([("report.a", watchDebris), ("stop.b", requestFuelStop), ("a.stopped", watchStopped)])
        finish()
    }

    /// Aisha's debris, ahead of Faiz: the marker, then the approach alert.
    func watchDebris() {
        soft("debris marker on phone 2", timeout: 60) { hazardMarker("Debris").exists }
        soft("approach alert for the debris", timeout: 150) { approachShowing }
        // The convoy list folds and the camera settles on the hazard before the shot.
        Thread.sleep(forTimeInterval: 1.5)
        shot("approach-alert")
        Thread.sleep(forTimeInterval: 3)
    }
}
