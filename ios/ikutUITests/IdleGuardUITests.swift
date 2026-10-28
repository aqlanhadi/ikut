import XCTest

/// Q21: after XCTest's animation count leaks (one animation start without its stop), the Debug app's idle guard
/// (`AnimationDump`) gives it back within a few seconds. The app leaks one on purpose 8 s after launch
/// (`IKUT_LEAK_ANIMATION`); a tap then has to come back in well under the 60 s XCTest waits for "animations complete".
@MainActor
final class IdleGuardUITests: ConvoyUITestCase {
    func testALeakedAnimationCountIsGivenBack() throws {
        app = XCUIApplication()
        allowPermissionPrompts()
        app.launchEnvironment["IKUT_LEAK_ANIMATION"] = "1"
        app.launch()
        Thread.sleep(forTimeInterval: 10) // the leak lands at 8 s
        let started = Date()
        app.tap() // waits for the app to idle first
        app.tap()
        let took = Date().timeIntervalSince(started)
        XCTAssertLessThan(took, 20, "Two taps took \(Int(took)) s: the leaked animation count wasn't given back")
    }
}
