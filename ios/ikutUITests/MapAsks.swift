import XCTest

extension XCUIApplication {
    /// The driving mode's Report button, by identifier: it is there once Start or Show map has switched the trip screen
    /// to driving (the same screen, no push, D53).
    var drivingReport: XCUIElement { buttons["convoy.report"] }
    /// What continues below the convoy when the driving sheet is pulled up to its tallest (the journey, code, trip,
    /// options, Leave or End), by identifier. There is no Back to the lobby (D53, #424).
    var pulledUpSheet: XCUIElement { otherElements["trip.pulledUp"] }
    /// The convoy panel's header button when the list is folded, and when it is unfolded.
    var expandConvoy: XCUIElement { buttons["Expand convoy list"] }
    var collapseConvoy: XCUIElement { buttons["Collapse convoy list"] }
    /// The driving sheet's own scroll view (its middle is on screen, unlike a row far down it).
    var drivingSheetScroll: XCUIElement { scrollViews.containing(.staticText, identifier: "convoy.header").firstMatch }
    var sheetGrabber: XCUIElement { descendants(matching: .any)["Sheet Grabber"].firstMatch }

    /// Drags the convoy sheet up by its grabber until the lobby continues below the convoy; true once it does.
    @discardableResult
    func pullUpTripSheet() -> Bool {
        for _ in 0..<4 {
            if pulledUpSheet.exists { return true }
            guard sheetGrabber.waitForExistence(timeout: 5) else { return false }
            sheetGrabber.swipeUp()
            _ = pulledUpSheet.waitForExistence(timeout: 2)
        }
        return pulledUpSheet.exists
    }

    /// Drags the convoy sheet down by its grabber, slowly and by about a third of the screen, so it settles one
    /// height lower (pulled up to tall, or tall to short); a quick swipe from tall to short would spring back.
    func pullDownTripSheet() {
        guard sheetGrabber.waitForExistence(timeout: 5) else { return }
        let start = sheetGrabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 300)))
    }

    /// Scrolls the driving sheet's content down by about `points`: a slow drag held at its end (no fling), on the
    /// rows between the sheet's top and its bottom bar, which the scroll view runs under.
    func scrollDrivingSheet(by points: CGFloat) {
        // From just above the bottom bar, and never past the sheet's top, so the drag stays on the rows.
        let sheet = drivingSheetScroll.frame
        let barTop = drivingReport.exists ? drivingReport.frame.minY : sheet.maxY - 70
        let startY = barTop - 12
        let distance = min(points, startY - sheet.minY - 24)
        guard distance > 10 else { return }
        let origin = coordinate(withNormalizedOffset: .zero)
        let from = origin.withOffset(CGVector(dx: sheet.midX, dy: startY))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -distance)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    /// Pulls the convoy sheet up, scrolls it down to the row with identifier `id` (lobby.endTrip, lobby.leaveTrip,
    /// lobby.pause) when it doesn't fit, and taps it; false when it never became hittable.
    @discardableResult
    func tapPulledUpRow(_ id: String) -> Bool {
        guard pullUpTripSheet() else { return false }
        let row = buttons[id]
        var scrolls = 0
        while !(row.exists && row.isHittable), scrolls < 20, drivingSheetScroll.exists {
            // A hazard approach or a stop request folds the sheet down while driving: pull it up again.
            if !pulledUpSheet.exists, !pullUpTripSheet() { return false }
            scrollDrivingSheet(by: 150)
            scrolls += 1
        }
        guard row.exists, row.isHittable else { return false }
        row.tap()
        return true
    }

    /// Answers "Not now" to whatever the map asks on arrival (road alerts, keep the screen on), one
    /// alert after another, plus the Always-location sheet. Waits `first` for the first, a shorter beat for the rest.
    func dismissMapAsks(first: TimeInterval = 5) {
        var wait = first
        for _ in 0..<4 {
            let notNow = buttons["Not now"]
            guard notNow.waitForExistence(timeout: wait) else { return }
            notNow.tap()
            wait = 2.5
        }
    }
}
