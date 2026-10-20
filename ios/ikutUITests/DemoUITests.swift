import XCTest

/// The phones of the two live demos (`qa/demo.mjs`, `qa/demo-two-cars.mjs`; see qa/README.md, "Live demo").
/// A phone is the organizer:
///   DemoOrganizerUITests  phone 1 in both demos: Aisha creates the trip, starts it, and then does whatever the script
///                         asks through marker files (report debris, agree to the stop and pin it, Everyone has arrived)
///   DemoPassengerUITests  phone 2 of the organizer demo: Faiz joins Aisha's car as a passenger (co-pilot)
///   DemoOwnCarUITests     phone 2 of the two-cars demo: Faiz joins as "A new car" and drives behind Aisha
///
/// Same marker-file handshake as the two-phone convoy test (`TwoPhoneConvoyBase`, TEST_RUNNER_IKUT_SYNC_DIR), with the
/// script's markers `code`, `cars.joined`, `report.a`, `report.b`, `stop.b`, `agree`, `arrive`, `end`. After setup the
/// tests only follow the script and hold the map open until `end` (or TEST_RUNNER_IKUT_HOLD_SECONDS). Cosmetic checks
/// are logged ("QA CHECK: NOTE ...") and never fail the demo; a failed core step (a tap that does the demo's job, the
/// pin showing up) is logged as FAIL and fails the test at the end, after the demo has played out.
@MainActor
class DemoBase: TwoPhoneConvoyBase {
    var coreFailures: [String] = []
    var holdUntil = Date()
    let env = ProcessInfo.processInfo.environment
    var demoName: String { env["IKUT_DEMO_NAME"] ?? "Aisha" }
    var stopChip: XCUIElement { app.buttons["stopChip"] }

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
        let start = lobbyActionButton
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
        // Start Trip turns into Back to Map once the trip is on the road: tap until the map shows.
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
            app.buttons["Join Trip"].tap()
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

    /// Waits for the lead car's pin to show on this phone's card. The requester's card starts folded: open it if needed.
    func watchPin() {
        var opened = false
        let seen = soft("the lead car's pin shows on this phone", timeout: 120, core: true) {
            if labelled("label CONTAINS %@", "pinned by the lead car").exists || button(beginningWith: "Agreed · Pinned").exists { return true }
            if !opened, stopChip.exists, stopChip.isHittable { opened = true; stopChip.tap() }
            return false
        }
        shot("stop-pinned")
        if seen { mark("b.sawPin") } else { mark("b.sawPin", "missing") }
    }

    func watchResolved() {
        soft("stop card gone after Everyone has arrived", timeout: 60) {
            !app.buttons["Agree to Stop"].exists && !stopChip.exists && !button(beginningWith: "Agreed").exists
        }
        shot("stop-resolved")
    }
}

/// Phone 1 of both demos: Aisha, organizer, lead car.
final class DemoOrganizerUITests: DemoBase {
    func testOrganizer() throws {
        try startDemo(as: "A")

        try step("1. creates the trip (name, New Trip, Where to? Ipoh, lobby)") {
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
                let error = labelled("label BEGINSWITH %@", "Error: ")
                XCTFail("Didn't reach the lobby (\(error.exists ? error.label : "no error shown"))")
                throw WaitFailure()
            }
            let code = readJoinCode()
            shot("lobby-created")
            mark("a.code", code)
        }

        try step("2. lobby with the other cars; Start Trip opens the map") {
            try waitMark("cars.joined", timeout: 420)
            soft("lobby shows Faiz and the scripted cars", timeout: 60) {
                labelled("label CONTAINS %@", "Hafiz").exists && labelled("label CONTAINS %@", "Faiz").exists
            }
            shot("lobby-full")
            openDemoMap()
            mark("a.map")
        }

        follow([("report.a", reportDebris), ("agree", agreeAndPin), ("arrive", arrived)])
        if env["IKUT_END_TRIP"] == "1" { endTrip() }
        finish()
    }

    /// --end-trip, and always against production: the organizer ends the trip from the Trip menu.
    func endTrip() {
        guard app.buttons["Trip menu"].exists else { note("Trip menu to end the trip", false, core: true); return }
        openTripMenuItem("Trip menu", "End trip")
        confirm("End trip")
        soft("the trip ended and phone 1 shows the recap", timeout: 30, core: true) { app.buttons["Share Recap"].exists }
    }

    /// The organizer sees the stop card: Agree to Stop, then pin the place ("Pin R&R Demo", else "Pin this stop").
    func agreeAndPin() {
        let agree = app.buttons["Agree to Stop"]
        guard soft("the stop card shows on phone 1", timeout: 90, core: true, { agree.exists }) else { return }
        shot("stop-card")
        agree.tap()
        // Agreeing folds the card into its chip; a tap opens it again.
        if soft("the card folds into its chip after agreeing", timeout: 15, { stopChip.exists && !agree.exists }) { stopChip.tap() }
        let pin = pinButton()
        guard soft("a pin button shows", timeout: 30, core: true, { pin().exists }) else { return }
        shot("stop-pin-buttons")
        pin().tap()
        let pinned = soft("the stop is pinned for everyone", timeout: 30, core: true) {
            button(beginningWith: "Agreed · Pinned").exists || labelled("label CONTAINS %@", "pinned by the lead car").exists
        }
        shot("stop-pinned")
        if pinned { mark("a.pinned") }
    }

    func pinButton() -> () -> XCUIElement {
        {
            for prefix in ["Pin R&R Demo", "Pin this stop", "Pin "] {
                let b = self.button(beginningWith: prefix)
                if b.exists { return b }
            }
            return self.button(beginningWith: "Pin ")
        }
    }

    func arrived() {
        let done = app.buttons["Everyone has arrived"]
        if !done.exists, stopChip.exists { stopChip.tap() }
        guard soft("Everyone has arrived is there", timeout: 20, core: true, { done.exists }) else { return }
        done.tap()
        soft("the stop card is gone on phone 1", timeout: 60, core: true) {
            !button(beginningWith: "Agreed").exists && !app.buttons["Agree to Stop"].exists && !stopChip.exists
        }
        shot("stop-resolved")
        mark("a.resolved")
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

        follow([("report.b", reportDebris), ("a.pinned", watchPin), ("a.resolved", watchResolved)])
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

        follow([("report.a", watchDebris), ("stop.b", requestFuelStop), ("a.pinned", watchPin), ("a.resolved", watchResolved)])
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

    /// Pit stop > Fuel; the request sheet finds a place ahead (or none) and sends by itself after a short countdown.
    func requestFuelStop() {
        let pitStop = app.buttons["Pit stop"]
        guard soft("Pit stop button", timeout: 20, core: true, {
            // The "Get road alerts?" question can still be up over the map.
            if app.buttons["Not now"].exists { app.buttons["Not now"].tap(); Thread.sleep(forTimeInterval: 1) }
            // The approach folds the convoy list (and Pit stop with it) until the hazard is passed: open it again.
            if !(pitStop.exists && pitStop.isHittable), app.buttons["Expand convoy list"].exists { app.buttons["Expand convoy list"].tap(); Thread.sleep(forTimeInterval: 1) }
            return pitStop.exists && pitStop.isHittable
        }) else { return }
        pitStop.tap()
        let fuel = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Fuel'")).firstMatch
        guard fuel.waitForExistence(timeout: 10) else { note("Pit stop sheet opened", false, core: true); return }
        fuel.tap()
        Thread.sleep(forTimeInterval: 1)
        shot("pit-stop-sheet")
        soft("the request is sent and the sheet closes", timeout: 90, core: true) { !app.staticTexts["Need gas"].exists }
        soft("Faiz's own request chip", timeout: 30) { stopChip.exists }
        shot("stop-requested")
        mark("b.stopRequested")
    }
}
