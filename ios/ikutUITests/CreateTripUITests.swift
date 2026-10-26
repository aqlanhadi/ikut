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

        let search = app.textFields["Destination"]
        XCTAssertTrue(search.waitForExistence(timeout: 15), "Didn't reach Where to?")
        search.tap()
        search.typeText(destination)

        let firstResult = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", destination)).firstMatch
        XCTAssertTrue(firstResult.waitForExistence(timeout: 20), "No search result for \(destination)")
        firstResult.tap()
        tapCreateTrip()

        let startTrip = app.buttons["Start trip"]
        if !waitForLobby(timeout: 30) {
            let errors = app.staticTexts.matching(identifier: "createTripError")
            let message = errors.firstMatch.exists ? errors.firstMatch.label : "no error shown"
            add(XCTAttachment(screenshot: app.screenshot()))
            XCTFail("Didn't reach the lobby (\(message))")
            return
        }
        add(XCTAttachment(screenshot: app.screenshot()))

        // Tracking starts in the lobby; the "Not now" sheet (screen off) may cover Start trip, and the map asks its own.
        let notNow = app.buttons["Not now"]
        if notNow.waitForExistence(timeout: 6) { notNow.tap() }
        startTrip.tap()
        app.dismissMapAsks(first: 3)
        XCTAssertTrue(app.drivingReport.waitForExistence(timeout: 20), "Didn't reach the map")
        add(XCTAttachment(screenshot: app.screenshot()))

        // TEST_RUNNER_IKUT_HOLD_SECONDS keeps the map open, e.g. to watch `qa/drive-trip.mjs` play the route.
        if let hold = env["IKUT_HOLD_SECONDS"].flatMap(Double.init) {
            _ = app.buttons["Never shown"].waitForExistence(timeout: hold)
        }
    }

    /// The sheets hand over to each other: lobby Back to Home (Home's sheet is back and its controls are hittable),
    /// Home's row to the lobby (the lobby's sheet and bar), Start to driving, a Pit stop card opened and closed, the
    /// convoy sheet raised to tall with the lobby's rows below it and down again, twice (there is no Back to the lobby,
    /// D53), a swipe at tall that scrolls and keeps the height, then End trip from the rows: Cancel leaves the sheet at
    /// tall, confirming opens the recap.
    func testLobbyAndHomeSheetsHandOver() throws {
        app = XCUIApplication()
        allowPermissionPrompts()
        app.launch()
        startNewTrip(as: "Organizer", homeTimeout: 15)
        let search = app.textFields["Destination"]
        XCTAssertTrue(search.waitForExistence(timeout: 15), "Didn't reach Where to?")
        search.tap()
        search.typeText("Ipoh")
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Ipoh")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20), "No search result for Ipoh")
        result.tap()
        tapCreateTrip()
        XCTAssertTrue(waitForLobby(timeout: 30), "New trip to the lobby: no lobby sheet")

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
        lobbyActionButton.tap()
        app.dismissMapAsks(first: 3)
        XCTAssertTrue(app.drivingReport.waitForExistence(timeout: 30), "Didn't reach the map")

        // Pit stop's card over the convoy sheet, closed, then the sheet raised to tall: one sheet, no card left behind.
        let pitStop = app.buttons["stop.button"]
        XCTAssertTrue(pitStop.waitForExistence(timeout: 10), "No Pit stop button")
        pitStop.tap()
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), "Pit stop didn't open its card")
        close.tap()
        XCTAssertTrue(waitForGone(close, timeout: 5), "Pit stop's card stayed up after Close")

        // Two round trips: at tall the lobby's rows are below the convoy; down by the grabber, the list folds.
        for round in 1...2 {
            XCTAssertTrue(app.raiseTripSheet(), "Round \(round): at tall the lobby's rows aren't below the convoy")
            XCTAssertTrue(app.buttons["lobby.copyCode"].exists, "Round \(round): no trip code card at tall")
            XCTAssertFalse(app.buttons["Close"].exists, "Round \(round): a card is stuck over the sheet")
            XCTAssertEqual(app.otherElements.matching(identifier: "trip.lobbyRows").count, 1,
                           "Round \(round): the lobby's rows show more than once")
            app.lowerTripSheet()
            XCTAssertTrue(waitForGone(app.lobbyRows, timeout: 5), "Round \(round): folding left the lobby's rows")
            XCTAssertTrue(app.expandConvoy.waitForExistence(timeout: 5), "Round \(round): the convoy list didn't fold")
            XCTAssertTrue(app.drivingReport.isHittable, "Round \(round): Report isn't hittable on the folded sheet")
        }

        // At tall, a swipe up on the convoy list scrolls: the sheet keeps its height and the Journey comes into view
        // (#402, #409). Then a tap on the header still folds it.
        app.expandConvoy.tap()
        XCTAssertTrue(app.lobbyRows.waitForExistence(timeout: 5), "A tap on the header didn't bring the sheet to tall")
        sleep(1)  // the sheet's move to tall settles
        let tallTop = app.sheetGrabber.frame.minY
        let journey = app.staticTexts["Journey"]
        var swipes = 0
        // A little at a time, so it stops on the Journey rather than flinging past it.
        while !journey.isHittable, swipes < 8 {
            app.scrollDrivingSheet(by: 60)
            swipes += 1
        }
        XCTAssertTrue(journey.isHittable, "A swipe up on the list didn't scroll the Journey into view")
        XCTAssertEqual(app.sheetGrabber.frame.minY, tallTop, accuracy: 2, "A swipe on the list changed the sheet's height")
        swipes = 0
        while !app.collapseConvoy.isHittable, swipes < 6 {
            app.drivingSheetScroll.swipeDown()
            swipes += 1
        }
        app.collapseConvoy.tap()
        XCTAssertTrue(app.expandConvoy.waitForExistence(timeout: 5), "A tap on the header didn't fold the sheet")

        // End trip from the lobby's rows at tall, Cancel: the sheet is still at tall with them.
        XCTAssertTrue(app.tapPulledUpRow("lobby.endTrip"), "No End trip row with the convoy sheet at tall")
        let endTitle = app.staticTexts["End the trip for everyone?"]
        XCTAssertTrue(endTitle.waitForExistence(timeout: 10), "End trip didn't ask to confirm")
        let cancel = app.buttons["Cancel"]
        // On iOS 26 the dialog is a popover with no Cancel: a tap outside it closes it.
        let outside = app.descendants(matching: .any)["PopoverDismissRegion"].firstMatch
        if cancel.exists { cancel.tap() } else if outside.exists { outside.tap() } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        }
        XCTAssertTrue(waitForGone(endTitle, timeout: 5), "The End trip confirmation stayed up after Cancel")
        XCTAssertTrue(app.lobbyRows.waitForExistence(timeout: 10), "After Cancel the sheet isn't at tall")

        // End trip again and confirm: the recap opens.
        XCTAssertTrue(app.tapPulledUpRow("lobby.endTrip"), "No End trip row the second time")
        XCTAssertTrue(endTitle.waitForExistence(timeout: 10), "End trip didn't ask to confirm the second time")
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "End trip"))
        confirm.element(boundBy: confirm.count - 1).tap()
        XCTAssertTrue(app.buttons["Share recap"].waitForExistence(timeout: 30), "Ending the trip didn't open the recap")
    }

    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

}
