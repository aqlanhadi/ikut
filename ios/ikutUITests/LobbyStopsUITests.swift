import XCTest

/// The lobby's stop list on sample data (launch with `IKUT_SCREEN`): swipe to remove, drag to reorder. Needs no emulator.
@MainActor
final class LobbyStopsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    /// Opens the organizer's lobby on sample data, pulled up to the tall height where the stops are; each test starts its own app, as the other UI tests do.
    private func launchLobby() {
        app = XCUIApplication()
        app.launchEnvironment["IKUT_SCREEN"] = "lobby-tall"
        app.launch()
    }

    private func row(_ name: String) -> XCUIElement {
        app.cells.containing(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    }

    /// The stops sit below the cars, the code and the trip rows: scroll the list until the stop is on screen.
    @discardableResult private func reveal(_ name: String) -> XCUIElement {
        let target = row(name)
        XCTAssertTrue(target.waitForExistence(timeout: 10), "no row for \(name)")
        var scrolls = 0
        // Clear of the bottom bar too (the bar's Start trip sits over the last 150 pt).
        while !(target.isHittable && target.frame.maxY < app.frame.height - 200), scrolls < 8 {
            app.collectionViews.firstMatch.swipeUp()
            scrolls += 1
        }
        return target
    }

    func testSwipeRemovesAStop() {
        launchLobby()
        let bidor = reveal("R&R Bidor")
        bidor.swipeLeft()
        let remove = app.buttons["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 3), "No Remove after swiping")
        remove.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: row("R&R Bidor"))
        waitForExpectations(timeout: 10)
        XCTAssertTrue(row("R&R Tapah").exists)
    }

    func testDragReordersStops() {
        launchLobby()
        // The list is in driving order: Bidor, Tapah, Gopeng.
        let bidor = reveal("R&R Bidor")
        let before = bidor.frame.minY
        let tapah = row("R&R Tapah")
        let from = bidor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = tapah.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.4))
        from.press(forDuration: 1.0, thenDragTo: to)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertGreaterThan(row("R&R Bidor").frame.minY, before, "R&R Bidor did not move down")
    }

    /// Start trip with a car not sharing yet asks first (#362); Cancel leaves the lobby as it was.
    func testStartWithACarNotSharingAsksFirst() {
        app = XCUIApplication()
        app.launchEnvironment["IKUT_SCREEN"] = "lobby-not-ready"
        app.launch()
        let start = app.buttons["Start trip"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "no alert after Start trip")
        XCTAssertTrue(alert.staticTexts["Siti’s Bezza isn’t sharing yet"].exists, "alert title: \(alert.debugDescription)")
        XCTAssertTrue(alert.staticTexts["Start anyway?"].exists)
        XCTAssertTrue(alert.buttons["Start anyway"].exists)
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertTrue(start.exists, "Start trip is gone after Cancel")
        XCTAssertFalse(app.buttons["Report"].exists, "the map opened after Cancel")
    }

    /// Add a stop is the lobby's own sheet (B6): Back returns to the lobby with the stops as they were.
    func testAddAStopOpensInTheSheetAndBackReturns() {
        launchLobby()
        let add = app.buttons["stops.add"]
        var scrolls = 0
        while !(add.isHittable && add.frame.maxY < app.frame.height - 200), scrolls < 8 {
            app.collectionViews.firstMatch.swipeUp()
            scrolls += 1
        }
        add.tap()
        let back = app.buttons["addStop.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "Add a stop did not open in the sheet")
        XCTAssertTrue(app.textFields["addStop.search"].exists, "no search field")
        back.tap()
        XCTAssertTrue(app.buttons["Start trip"].waitForExistence(timeout: 10), "the lobby did not come back")
        XCTAssertTrue(row("R&R Tapah").exists)
    }

    /// An R&R chosen in the list and added lands in the stop list.
    func testAddingTheChosenRnRPutsItInTheList() {
        app = XCUIApplication()
        app.launchEnvironment["IKUT_SCREEN"] = "lobby-add-stop-picked"
        app.launch()
        let add = app.buttons["addStop.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no Add button with Tapah R&R chosen")
        XCTAssertEqual(add.label, "Add Tapah R&R")
        app.buttons["addStop.longer"].tap()
        XCTAssertEqual(app.staticTexts["addStop.stay"].label, "30 min")
        add.tap()
        XCTAssertTrue(app.buttons["Start trip"].waitForExistence(timeout: 10), "the lobby did not come back")
        app.collectionViews.firstMatch.swipeUp()
        XCTAssertTrue(row("Tapah R&R").waitForExistence(timeout: 10), "Tapah R&R is not in the stop list: \(app.debugDescription)")
    }
}
