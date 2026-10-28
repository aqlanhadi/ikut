import XCTest

/// One place for what every driven-by-a-script UI test needs: finding elements, polling, screenshots,
/// the permission prompt, and the first-run steps (name sheet, New trip, joining with a code).
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
    /// `pullLobbySheetUp` has run in this test.
    var lobbySheetPulled = false

    override func setUp() {
        continueAfterFailure = false
    }

    /// Taps Allow on a system permission prompt (the test has to tap the app once for the monitor to run).
    func allowPermissionPrompts(_ labels: [String] = ["Allow While Using App", "Allow Once", "Allow"]) {
        forwardAnimationDump()
        addUIInterruptionMonitor(withDescription: "Permissions") { alert in
            for label in labels where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    /// Q21 diagnostic: `TEST_RUNNER_IKUT_ANIM_DUMP=<file>` makes the app (Debug) log every running Core Animation
    /// animation every 2 s to that file (`AnimationDump`), to see what keeps XCTest from calling the app idle.
    /// Every test calls `allowPermissionPrompts` before launching, so it is forwarded from there.
    private func forwardAnimationDump() {
        guard let app, let file = ProcessInfo.processInfo.environment["IKUT_ANIM_DUMP"], !file.isEmpty else { return }
        app.launchEnvironment["IKUT_ANIM_DUMP"] = file
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
        dumpScreen(what)
        XCTFail("Timed out after \(Int(timeout)) s waiting for: \(what). Convoy order: \(convoyOrder())")
        throw WaitFailure()
    }

    /// What was on screen when a wait gave up: every element whose identifier starts with one of `prefixes`
    /// (with its label, frame and whether it can be tapped), then the app's element tree trimmed to `limit`
    /// characters. Printed to the log, so a flake says what the phone held even when no screenshot survives.
    func dumpScreen(_ what: String, prefixes: [String] = ["stop.", "hazard.", "sheet.", "lobby.", "convoy."], limit: Int = 20000) {
        guard app != nil, let root = try? app.snapshot() else {
            print("QA DUMP (\(what)): no snapshot of the app")
            return
        }
        var lines: [String] = []
        func collect(_ e: XCUIElementSnapshot) {
            if prefixes.contains(where: { e.identifier.hasPrefix($0) }) {
                let f = e.frame
                lines.append("  \(e.identifier) '\(e.label)' at \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))\(e.isEnabled ? "" : " disabled")")
            }
            e.children.forEach(collect)
        }
        collect(root)
        print("QA DUMP (\(what)): \(lines.count) identified elements\n" + lines.joined(separator: "\n"))
        // The map's own features and annotations fill the tree; leave them out so the sheets and the keyboard fit.
        let tree = app.debugDescription.split(separator: "\n")
            .filter { !$0.contains("VKPointFeature") && !$0.contains("AnnotationContainer") }
            .joined(separator: "\n")
        print("QA DUMP TREE (\(what)):\n" + (tree.count > limit ? String(tree.prefix(limit)) + "\n  …" : tree))
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

    /// The lobby's button: "Start trip" for the organizer before the start, "Show map" for everyone once the trip is on
    /// the road. A passenger before the start has no button, only the "Waiting for ..." line (`lobbyPresence`).
    var lobbyActionButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Start trip", "Show map"])).firstMatch
    }

    /// Anything of the lobby's bottom bar: its button, or the passenger's waiting line.
    var lobbyPresence: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label IN %@ OR identifier == %@", ["Start trip", "Show map"], "lobbyWaiting")).firstMatch
    }

    /// Waits for the lobby's bottom bar (Start trip, Show map or the waiting line), answering "Not now" to the Always
    /// explainer if it comes up meanwhile: the lobby's sheet, and its bar, step aside while the explainer is up.
    func waitForLobby(timeout: TimeInterval) -> Bool {
        let bar = lobbyPresence
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            dismissAlwaysExplainerIfShown()
            if bar.exists, bar.isHittable { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    /// The Always-location explainer comes up once tracking starts, and the lobby's sheet steps aside for it: answer it
    /// "Not now" wherever the lobby is waited on, so a drag or a read never lands on the explainer.
    func dismissAlwaysExplainerIfShown() {
        let notNow = app.buttons["Not now"]
        if notNow.exists { notNow.tap() }
    }

    /// The lobby's sheet is up at medium; the cars list starts below it. One drag brings the sheet to tall (never
    /// repeat it: another drag scrolls the list, and the cars header goes out of the tree). Does nothing the second time.
    func pullLobbySheetUp() {
        guard !lobbySheetPulled else { return }
        dismissAlwaysExplainerIfShown()
        lobbySheetPulled = true
        let grabber = app.otherElements["Sheet Grabber"]
        if grabber.exists {
            grabber.swipeUp()
        } else {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            from.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
        }
    }

    /// Badge numbers of the convoy rows, front of the convoy first (top of the list). Read from one snapshot of
    /// the app: rows bound by index and read one by one failed the test when the panel redrew a row in between.
    func convoyOrder() -> [Int] {
        guard app != nil, let root = try? app.snapshot() else { return [] }
        let prefix = "convoy.row."
        var rows: [(y: CGFloat, n: Int)] = []
        func collect(_ element: XCUIElementSnapshot) {
            if element.identifier.hasPrefix(prefix), let n = Int(element.identifier.dropFirst(prefix.count)) {
                rows.append((element.frame.minY, n))
            }
            element.children.forEach(collect)
        }
        collect(root)
        var seen = Set<Int>()
        return rows.sorted { $0.y < $1.y }.compactMap { seen.insert($0.n).inserted ? $0.n : nil }
    }

    // MARK: Shared flows

    /// Clears the field, types `text` and checks the field now holds exactly that. A tap puts the cursor where
    /// it hit and a delete only removes what is before it, so a prefilled name was left in front of the typed
    /// one ("FaizAisha"): select everything (long press, Select All) and delete it in one go instead; if the
    /// menu does not come up, move the cursor to the end with a second tap and delete every character.
    func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        let current = field.value as? String ?? ""
        if !current.isEmpty, current != field.placeholderValue {
            field.press(forDuration: 1.2)
            let selectAll = app.menuItems["Select All"]
            if selectAll.waitForExistence(timeout: 2) {
                selectAll.tap()
                field.typeText(XCUIKeyboardKey.delete.rawValue)
            } else {
                field.tap()
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
            }
        }
        field.typeText(text)
        if field.exists, let held = field.value as? String {
            XCTAssertEqual(held, text, "the field should hold exactly what was typed")
        }
    }

    /// Fills the "Your name" sheet when it comes up (signed out), then taps the app so the interruption
    /// monitor can answer a permission prompt.
    func enterNameIfAsked(_ name: String) {
        let sheetName = app.textFields["Your name"]
        if sheetName.waitForExistence(timeout: 3), app.buttons["Continue"].exists {
            sheetName.tap()
            sheetName.typeText(name)
            let continueButton = app.buttons["Continue"]
            continueButton.tap()
            // The keyboard going down can move the sheet under that tap: tap again if it's still there.
            if !sheetName.waitForNonExistence(timeout: 5), continueButton.isHittable { continueButton.tap() }
            _ = sheetName.waitForNonExistence(timeout: 15)
        }
        // Wakes the permission monitor; at the top edge, so it can't land on a sheet's dimmed area or a control.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
    }

    /// The join sheet's first steps, when this phone needs them (D58): "Welcome to ikut" with the name (signed out), then
    /// the location step before iOS asks (permission not decided). Returns once the code field shows. The permission
    /// monitor answers iOS's own prompt on a tap at the top edge.
    func passJoinGates(name: String, timeout: TimeInterval = 40) {
        let nameField = app.textFields["Your name"]
        let code = app.textFields["Trip code"]
        let locationContinue = app.buttons["joinLocationContinue"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !code.exists {
            if nameField.exists {
                nameField.tap()
                // Only type into an empty field: a retry after a missed Continue must not type the name twice.
                if (nameField.value as? String ?? "").isEmpty || nameField.value as? String == "Your name" { nameField.typeText(name) }
                let next = app.buttons["joinNameContinue"]
                if next.isHittable { next.tap() }
                _ = nameField.waitForNonExistence(timeout: 15)
            } else if locationContinue.exists, locationContinue.isHittable {
                locationContinue.tap()
            }
            // Wakes the permission monitor; at the top edge, so it can't land on the sheet or a control.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// The app opens straight into a trip this phone is still in (#401, D54), so a run that left one behind starts
    /// there: from the lobby, Back to trips; from the driving map, End trip (the organiser) or Leave trip from the pulled-up
    /// sheet below the convoy, then Done on the recap. Returns once Welcome, Home or neither shows (a fresh install).
    func returnHomeFromAnOpenTrip(timeout: TimeInterval = 15) {
        let back = app.buttons["lobby.back"]
        let home = app.buttons["homeWhereTo"]
        let welcome = app.buttons["Get started"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if home.exists || welcome.exists { return }
            if app.drivingReport.exists || back.exists { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        if app.drivingReport.exists {
            app.dismissMapAsks(first: 2)
            guard app.pullUpTripSheet() else { return }
            let end = app.buttons["lobby.endTrip"]
            let leave = app.buttons["lobby.leaveTrip"]
            // End trip whenever there is one (the organiser has both, and Leave sits above End); Leave only without it.
            var scrolls = 0
            while !app.clearOfDrivingBar(end), scrolls < 20 {
                if end.exists == false, app.clearOfDrivingBar(leave), scrolls >= 3 { break }
                if !app.pulledUpSheet.exists, !app.pullUpTripSheet() { return }
                app.scrollDrivingSheet(by: 100)
                scrolls += 1
            }
            let label = app.clearOfDrivingBar(end) ? "End trip" : "Leave trip"
            (label == "End trip" ? end : leave).tap()
            let confirm = app.buttons.matching(NSPredicate(format: "label == %@", label))
            _ = confirm.element(boundBy: 1).waitForExistence(timeout: 10)
            confirm.element(boundBy: confirm.count - 1).tap()
            if label == "End trip" { closeRecap() }
        } else if back.exists {
            // Tracking starts as the lobby opens, and the Always explainer comes up once a moment later, with the
            // lobby's sheet stepping aside for it: wait for it and answer it first, then tap Back on the sheet.
            let notNow = app.buttons["Not now"]
            if notNow.waitForExistence(timeout: 5) { notNow.tap() }
            if back.waitForExistence(timeout: 10) { back.tap() }
        }
        if !home.waitForExistence(timeout: 15) {
            print("QA: no Home after closing the open trip:\n\(app.debugDescription)")
        }
    }

    /// The recap, which ending a trip opens: its Done is at the bottom of a long page, so scroll to it; the navigation
    /// bar's Back (Trips) does the same if it can't be reached.
    func closeRecap() {
        let done = app.buttons["Done"]
        guard done.waitForExistence(timeout: 30) else { print("QA: no Done on the recap"); return }
        let recap = app.scrollViews["recap"]
        var swipes = 0
        while !done.isHittable, recap.exists, swipes < 6 {
            recap.swipeUp()
            swipes += 1
        }
        if done.isHittable {
            done.tap()
        } else {
            app.navigationBars.buttons["BackButton"].firstMatch.tap()
        }
    }

    /// Welcome (first run) or Home to the name sheet and on: taps the Where to? row. A trip left open by an earlier
    /// run is closed first (`returnHomeFromAnOpenTrip`).
    func startNewTrip(as name: String, homeTimeout: TimeInterval = 20) {
        returnHomeFromAnOpenTrip()
        let getStarted = app.buttons["Get started"]
        if getStarted.waitForExistence(timeout: 5) { getStarted.tap() }
        let newTrip = app.buttons["homeWhereTo"]
        XCTAssertTrue(newTrip.waitForExistence(timeout: homeTimeout), "Home didn’t show Where to?")
        newTrip.tap()
        enterNameIfAsked(name)
    }

    /// New trip (the route drawn over Home's map, after a result is tapped): Create trip makes the trip and opens
    /// its lobby. The route is built first, so the button can take a while to appear.
    func tapCreateTrip(timeout: TimeInterval = 45) {
        let create = app.buttons["Create trip"]
        if create.waitForExistence(timeout: timeout) {
            create.tap()
        } else {
            let errors = app.staticTexts.matching(identifier: "createTripError")
            XCTFail("Didn't reach New trip (\(errors.firstMatch.exists ? errors.firstMatch.label : "no error shown"))")
        }
    }

    /// The organizer's lobby: the six-letter join code from the header's "To Ipoh · code K7M 2QX" line.
    func readJoinCode() -> String {
        let line = labelled("label CONTAINS %@", " · code ")
        XCTAssertTrue(line.waitForExistence(timeout: 15), "Lobby shows no join code")
        let code = (line.label.components(separatedBy: "code ").last ?? "").replacingOccurrences(of: " ", with: "")
        XCTAssertEqual(code.count, 6, "code: \(code)")
        return code
    }

    /// Welcome or Home to the join sheet's car step for `code`: the code typed in, the trip found, Continue (the name
    /// sheet comes first when signed out).
    func openJoinForm(code: String, name: String, homeTimeout: TimeInterval = 30) {
        returnHomeFromAnOpenTrip()
        // Home's row, or Welcome's link on a fresh install.
        let joinButton = app.buttons
            .matching(NSPredicate(format: "identifier IN %@", ["homeJoin", "welcomeJoin"])).firstMatch
        XCTAssertTrue(joinButton.waitForExistence(timeout: homeTimeout), "Home didn’t show Join trip")
        joinButton.tap()
        passJoinGates(name: name)
        let codeField = app.textFields["Trip code"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 15), "Join sheet didn't show the code field")
        codeField.tap()
        codeField.typeText(code)
        let next = app.buttons["joinContinue"]
        XCTAssertTrue(next.waitForExistence(timeout: 30), "Trip preview didn't load for \(code) (is the code right and the emulator up?)")
        next.tap()
    }

    /// On the car step: picks `tile` (a car whose label contains it) as a passenger, or my own car named `carName`, then Join.
    /// `sharing`: the "Share this car’s location" switch for an existing car; nil leaves what the car's own state set.
    func chooseCarAndJoin(ridingIn tile: String? = nil, carName: String, sharing: Bool? = nil, timeout: TimeInterval = 30) {
        let choice = tile.map { app.buttons.matching(NSPredicate(format: "label CONTAINS %@", $0)).firstMatch }
            ?? button(beginningWith: "My own car")
        XCTAssertTrue(choice.waitForExistence(timeout: timeout), "The car step didn't show \(tile ?? "My own car")")
        choice.tap()
        if tile == nil {
            let field = app.textFields["Car name"]
            if field.waitForExistence(timeout: 5) { replaceText(in: field, with: carName) }
        } else if let sharing {
            let share = app.switches["joinShare"]
            XCTAssertTrue(share.waitForExistence(timeout: 5), "The car step showed no share switch for \(tile ?? "")")
            if (share.value as? String == "1") != sharing { share.tap() }
        }
        app.buttons["joinConfirm"].tap()
    }

    /// Home (or Welcome) to the lobby of `code`, as my own car named "<name>'s car".
    func join(code: String, name: String) throws {
        openJoinForm(code: code, name: name)
        chooseCarAndJoin(carName: "\(name)'s car")
        XCTAssertTrue(waitForLobby(timeout: 30), "Didn't reach the lobby")
    }
}
