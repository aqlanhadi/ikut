import XCTest

/// Q31: a first-time joiner (signed out, location undecided or granted) gets through the join sheet's name and
/// location steps to the Trip code field. Needs the emulators; no second phone.
@MainActor
final class JoinLocationStepUITests: ConvoyUITestCase {
    func testJoinSheetReachesCodeField() throws {
        app = XCUIApplication()
        allowPermissionPrompts(["Allow While Using App", "Allow Once", "Allow", "Don’t Allow"])
        app.launch()
        returnHomeFromAnOpenTrip()
        let join = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["homeJoin", "welcomeJoin"])).firstMatch
        XCTAssertTrue(join.waitForExistence(timeout: 30), "Home didn’t show Join trip")
        join.tap()
        passJoinGates(name: "Wyna")
        XCTAssertTrue(app.textFields["Trip code"].waitForExistence(timeout: 15), "Join sheet didn't show the code field")
    }
}
