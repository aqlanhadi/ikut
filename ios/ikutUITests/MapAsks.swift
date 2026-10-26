import XCTest

extension XCUIApplication {
    /// The driving mode's Report button, by identifier: it is there once Start or Show map has switched the trip screen
    /// to driving (the same screen, no push, D53).
    var drivingReport: XCUIElement { buttons["convoy.report"] }
    /// The lobby's rows below the convoy when the driving sheet is at tall (the journey, code, trip, options, Leave or
    /// End), by identifier; they are in the sheet's one scroll view, reached by scrolling down (D53, #409).
    var lobbyRows: XCUIElement { otherElements["trip.lobbyRows"] }
    /// The convoy panel's header button when the list is folded, and when it is unfolded.
    var expandConvoy: XCUIElement { buttons["Expand convoy list"] }
    var collapseConvoy: XCUIElement { buttons["Collapse convoy list"] }
    /// The driving sheet's own scroll view (its middle is on screen, unlike a row far down it).
    var drivingSheetScroll: XCUIElement { scrollViews.containing(.staticText, identifier: "convoy.header").firstMatch }
    var sheetGrabber: XCUIElement { descendants(matching: .any)["Sheet Grabber"].firstMatch }

    /// Brings the convoy sheet to tall, its highest, by its grabber; true once the lobby's rows are below the convoy.
    @discardableResult
    func raiseTripSheet() -> Bool {
        for _ in 0..<3 {
            if lobbyRows.exists { return true }
            guard sheetGrabber.waitForExistence(timeout: 5) else { return false }
            sheetGrabber.swipeUp()
            _ = lobbyRows.waitForExistence(timeout: 2)
        }
        return lobbyRows.exists
    }

    /// Drags the convoy sheet down by its grabber, slowly and by about a third of the screen, from tall to short; a
    /// quick swipe would spring back.
    func lowerTripSheet() {
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

    /// Brings the convoy sheet to tall, scrolls it down to the row with identifier `id` (lobby.endTrip,
    /// lobby.leaveTrip, lobby.pause) and taps it; false when it never became hittable.
    @discardableResult
    func tapPulledUpRow(_ id: String) -> Bool {
        guard raiseTripSheet() else { return false }
        let row = buttons[id]
        var scrolls = 0
        while !(row.exists && row.isHittable), scrolls < 20, drivingSheetScroll.exists {
            // A hazard approach folds the sheet to short (and back to the top) while driving: raise it again.
            if !lobbyRows.exists, !raiseTripSheet() { return false }
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
