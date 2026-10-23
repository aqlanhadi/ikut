import XCTest

/// The lobby's stop list on sample data (launch with `IKUT_SCREEN`): swipe to remove, drag to reorder. Needs no emulator.
@MainActor
final class LobbyStopsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    /// Opens the organizer's lobby on sample data; each test starts its own app, as the other UI tests do.
    private func launchLobby() {
        app = XCUIApplication()
        app.launchEnvironment["IKUT_SCREEN"] = "lobby-organizer"
        app.launch()
    }

    private func row(_ name: String) -> XCUIElement {
        app.cells.containing(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    }

    func testSwipeRemovesAStop() {
        launchLobby()
        let bidor = row("R&R Bidor")
        XCTAssertTrue(bidor.waitForExistence(timeout: 10))
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
        let bidor = row("R&R Bidor")
        XCTAssertTrue(bidor.waitForExistence(timeout: 10))
        let before = bidor.frame.minY
        let tapah = row("R&R Tapah")
        let from = bidor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = tapah.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.4))
        from.press(forDuration: 1.0, thenDragTo: to)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertGreaterThan(row("R&R Bidor").frame.minY, before, "R&R Bidor did not move down")
    }
}
