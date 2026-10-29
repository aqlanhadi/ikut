import XCTest

/// Drives the organizer's path in a simulator: name, New trip, pick a destination, Create trip, lobby, Start trip,
/// map. Needs the emulators and a simulated location (`xcrun simctl location <udid> set 3.139,101.687`).
/// `TEST_RUNNER_IKUT_DESTINATION` picks the search text (default Ipoh); `TEST_RUNNER_IKUT_HOLD_SECONDS`
/// stays on the map that long at the end.
@MainActor
final class CreateTripUITests: ConvoyUITestCase {
    func testCreateAndStartTrip() throws {
        let env = ProcessInfo.processInfo.environment
        let destination = env["IKUT_DESTINATION"] ?? "Ipoh"

        app = XCUIApplication()
        allowPermissionPrompts()
        app.launch()

        // Welcome on a first run, Home once a previous run got past it; the name sheet comes first when signed out.
        startNewTrip(as: "Organizer", homeTimeout: 15)

        try createTrip(to: destination)
        add(XCTAttachment(screenshot: app.screenshot()))

        // The Always explainer ("Not now") may come before the lobby or over it, and the map asks its own.
        startFromLobby()
        add(XCTAttachment(screenshot: app.screenshot()))

        // TEST_RUNNER_IKUT_HOLD_SECONDS keeps the map open, e.g. to watch `qa/drive-trip.mjs` play the route.
        if let hold = env["IKUT_HOLD_SECONDS"].flatMap(Double.init) {
            _ = app.buttons["Never shown"].waitForExistence(timeout: hold)
        }
    }

    /// The sheets hand over to each other: lobby Back to Home (Home's sheet is back and its controls are hittable),
    /// Home's row to the lobby (the lobby's sheet and bar), Start to driving, a Pit stop card opened and closed, the
    /// convoy sheet's three heights (#424): a tap on the header unfolds the list, a swipe up on the list pulls the sheet
    /// up to the lobby below the convoy, and down by the grabber steps back one height at a time, twice (there is no
    /// Back to the lobby, D53); then End trip from the pulled-up sheet: Cancel leaves it pulled up, confirming opens
    /// the recap, and Back on it returns to Home's list on the same map (D92).
    func testLobbyAndHomeSheetsHandOver() throws {
        app = XCUIApplication()
        allowPermissionPrompts()
        app.launch()
        startNewTrip(as: "Organizer", homeTimeout: 15)
        try createTrip(to: "Ipoh")

        // Lobby, Back: Home's sheet comes back.
        app.buttons["Back to trips"].tap()
        let newTrip = app.buttons["homeWhereTo"]
        XCTAssertTrue(newTrip.waitForExistence(timeout: 15), "Back from the lobby: Home's sheet didn't come back")
        XCTAssertTrue(newTrip.isHittable, "Back from the lobby: Home's Where to? row isn't hittable")

        // Home's row for the trip under way opens the lobby, sheet and all.
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Ipoh")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Home lists no row for the trip")
        row.tap()
        XCTAssertTrue(waitForLobby(timeout: 30), "Home row to the lobby: no lobby sheet")

        // Start trip: the same screen in driving mode, the lobby's sheet now the convoy's.
        startFromLobby()

        // Pit stop's card over the convoy sheet, closed, then the sheet pulled up: one sheet, no card left behind.
        let pitStop = app.buttons["stop.button"]
        XCTAssertTrue(pitStop.waitForExistence(timeout: 10), "No Pit stop button")
        pitStop.tap()
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), "Pit stop didn't open its card")
        close.tap()
        XCTAssertTrue(waitForGone(close, timeout: 5), "Pit stop's card stayed up after Close")

        // Normal (the car list) by a tap on the header; a swipe up on the list pulls the sheet up to tall (#424), with
        // the lobby below the convoy; down by the grabber it is the car list again, and the header still folds it.
        app.expandConvoy.tap()
        XCTAssertTrue(app.collapseConvoy.waitForExistence(timeout: 5), "A tap on the header didn't unfold the list")
        XCTAssertFalse(app.pulledUpSheet.exists, "Unfolding the list pulled the sheet up")
        app.drivingSheetScroll.swipeUp()
        XCTAssertTrue(app.pulledUpSheet.waitForExistence(timeout: 5), "A swipe up on the list didn't pull the sheet up")
        app.pullDownTripSheet()
        XCTAssertTrue(waitForGone(app.pulledUpSheet, timeout: 5), "Pulling down left the lobby below the convoy")
        XCTAssertTrue(app.collapseConvoy.waitForExistence(timeout: 5), "Pulling down from tall folded the list")
        app.collapseConvoy.tap()
        XCTAssertTrue(app.expandConvoy.waitForExistence(timeout: 5), "A tap on the header didn't fold the sheet")

        // Two round trips: pulled up, the lobby continues below the convoy; down twice, the list is folded again.
        for round in 1...2 {
            XCTAssertTrue(app.pullUpTripSheet(), "Round \(round): pulling the sheet up didn't show the lobby below the convoy")
            XCTAssertTrue(app.buttons["lobby.copyCode"].exists, "Round \(round): no trip code card when pulled up")
            XCTAssertFalse(app.buttons["Close"].exists, "Round \(round): a card is stuck over the pulled-up sheet")
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "trip.pulledUp").count, 1,
                           "Round \(round): the pulled-up lobby shows more than once")
            app.pullDownTripSheet()
            XCTAssertTrue(waitForGone(app.pulledUpSheet, timeout: 5), "Round \(round): pulling down left the lobby below the convoy")
            app.pullDownTripSheet()
            XCTAssertTrue(app.expandConvoy.waitForExistence(timeout: 5), "Round \(round): the convoy list didn't fold")
            XCTAssertTrue(app.drivingReport.isHittable, "Round \(round): Report isn't hittable on the folded sheet")
        }

        // End trip from the pulled-up sheet, Cancel: the sheet is still pulled up.
        XCTAssertTrue(app.tapPulledUpRow("lobby.endTrip"), "No End trip row with the convoy sheet pulled up")
        let endTitle = app.staticTexts["End the trip for everyone?"]
        XCTAssertTrue(endTitle.waitForExistence(timeout: 10), "End trip didn't ask to confirm")
        let cancel = app.buttons["Cancel"]
        // On iOS 26 the dialog is a popover with no Cancel: a tap outside it closes it.
        let outside = app.descendants(matching: .any)["PopoverDismissRegion"].firstMatch
        if cancel.exists { cancel.tap() } else if outside.exists { outside.tap() } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        }
        XCTAssertTrue(waitForGone(endTitle, timeout: 5), "The End trip confirmation stayed up after Cancel")
        XCTAssertTrue(app.pulledUpSheet.waitForExistence(timeout: 10), "After Cancel the sheet isn't pulled up")

        // End trip again and confirm: the recap opens.
        XCTAssertTrue(app.tapPulledUpRow("lobby.endTrip"), "No End trip row the second time")
        XCTAssertTrue(endTitle.waitForExistence(timeout: 10), "End trip didn't ask to confirm the second time")
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "End trip"))
        confirm.element(boundBy: confirm.count - 1).tap()
        XCTAssertTrue(app.buttons["Share recap"].waitForExistence(timeout: 30), "Ending the trip didn't open the recap")

        // The navigation bar's Back on the recap (D92; Done is what `returnHomeFromAnOpenTrip` taps in the relaunch
        // tests): Home's list on the one map, its sheet back and hittable (D54), and the ended trip's screen gone.
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "The recap shows no Back button")
        back.tap()
        let home = app.buttons["homeWhereTo"]
        XCTAssertTrue(home.waitForExistence(timeout: 15), "Back on the recap didn't return to Home")
        XCTAssertFalse(app.drivingReport.exists, "Back on the recap left the ended trip's map showing")
        XCTAssertFalse(app.buttons["lobby.back"].exists, "Back on the recap left the ended trip's lobby showing")
        XCTAssertTrue(home.isHittable, "After the recap, Home's Where to? isn't hittable")
    }

    /// Relaunch mid-trip (#401, D54): a trip created and started, the app terminated and launched again, opens straight
    /// on the driving map (Home never shows first), and the trip is still there to end.
    func testRelaunchOpensTheDrivingMapOfTheTripInProgress() throws {
        app = XCUIApplication()
        allowPermissionPrompts()
        app.launch()
        startNewTrip(as: "Organizer", homeTimeout: 15)
        try createTrip(to: "Ipoh")
        startFromLobby()

        app.terminate()
        app.launch()
        // Straight into the trip: Home's Where to? never shows on the way.
        let home = app.buttons["homeWhereTo"]
        let deadline = Date().addingTimeInterval(30)
        var sawHome = false
        while Date() < deadline, !app.drivingReport.exists {
            if home.exists { sawHome = true }
            app.buttons["Not now"].firstMatch.tapIfHittable()
            Thread.sleep(forTimeInterval: 0.2)
        }
        add(XCTAttachment(screenshot: app.screenshot()))
        XCTAssertTrue(app.drivingReport.exists, "Relaunch didn't open the driving map")
        XCTAssertFalse(sawHome, "Home showed before the trip on relaunch")
        XCTAssertFalse(app.buttons["lobby.back"].exists, "Relaunch opened the lobby, not the driving map")

        // The trip is the one in progress: End trip from its rows, the recap, then Home.
        returnHomeFromAnOpenTrip()
        XCTAssertTrue(home.waitForExistence(timeout: 30), "After ending the trip, Home didn't come back")
    }

    /// Relaunch before Start (#401, D54): a trip created and left in its lobby, the app terminated and launched again,
    /// opens straight in that lobby (Home never shows first); Back to trips then returns to Home.
    func testRelaunchOpensTheLobbyOfATripNotStarted() throws {
        app = XCUIApplication()
        allowPermissionPrompts()
        app.launch()
        startNewTrip(as: "Organizer", homeTimeout: 15)
        try createTrip(to: "Ipoh")

        app.terminate()
        app.launch()
        let home = app.buttons["homeWhereTo"]
        let startTrip = app.buttons["Start trip"]
        let deadline = Date().addingTimeInterval(30)
        var sawHome = false
        // Existence only while waiting: mid-transition a button can exist with no frame, and asking if it is
        // hittable then fails the test.
        while Date() < deadline, !startTrip.exists {
            if home.exists { sawHome = true }
            dismissNotNow()
            Thread.sleep(forTimeInterval: 0.2)
        }
        add(XCTAttachment(screenshot: app.screenshot()))
        XCTAssertTrue(waitForLobby(timeout: 15), "Relaunch didn't open the lobby")
        XCTAssertFalse(sawHome, "Home showed before the lobby on relaunch")
        XCTAssertFalse(app.drivingReport.exists, "Relaunch before Start opened the driving map")

        // The Always sheet can come up over the lobby just now and take the tap.
        dismissNotNow()
        app.buttons["lobby.back"].tap()
        XCTAssertTrue(home.waitForExistence(timeout: 15), "Back to trips didn't return to Home")
    }

    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

}

private extension XCUIElement {
    /// Taps it when it is there and can be tapped; nothing otherwise.
    func tapIfHittable() {
        if exists, isHittable { tap() }
    }
}
