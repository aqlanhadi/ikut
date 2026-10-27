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
        let barTop = drivingBarTop ?? sheet.maxY - 70
        let startY = barTop - 12
        let distance = min(points, startY - sheet.minY - 24)
        guard distance > 10 else { return }
        let origin = coordinate(withNormalizedOffset: .zero)
        let from = origin.withOffset(CGVector(dx: sheet.midX, dy: startY))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -distance)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    /// The top of the driving sheet's bottom bar (Report and Pit stop), which the rows scroll under; nil without one.
    var drivingBarTop: CGFloat? {
        let tops = [drivingReport, buttons["stop.button"]].filter(\.exists).map(\.frame.minY)
        return tops.min()
    }

    /// Whether `row` is wholly in the sheet's rows: below the sheet's top and above its bottom bar, so a tap on it
    /// lands on it and not on Report or Pit stop (`isHittable` is true under the bar too).
    func clearOfDrivingBar(_ row: XCUIElement) -> Bool {
        guard row.exists, row.isHittable else { return false }
        let frame = row.frame
        if let barTop = drivingBarTop, frame.maxY > barTop - 1 { return false }
        return frame.minY >= drivingSheetScroll.frame.minY
    }

    /// Pulls the convoy sheet up, scrolls it down in small steps until the row with identifier `id` (lobby.endTrip,
    /// lobby.leaveTrip, lobby.pause) is wholly above the bottom bar, and taps it; false when it never got there.
    @discardableResult
    func tapPulledUpRow(_ id: String) -> Bool {
        guard pullUpTripSheet() else { return false }
        let row = buttons[id]
        var scrolls = 0
        while !clearOfDrivingBar(row), scrolls < 24, drivingSheetScroll.exists {
            // A hazard approach or a stop request folds the sheet down while driving: pull it up again.
            if !pulledUpSheet.exists, !pullUpTripSheet() { return false }
            // Just far enough to bring a row in sight above the bar, so it stops there rather than past it.
            var step: CGFloat = 120
            if row.exists, let barTop = drivingBarTop, row.frame.maxY > barTop {
                step = min(120, row.frame.maxY - barTop + 24)
            }
            scrollDrivingSheet(by: step)
            scrolls += 1
        }
        guard clearOfDrivingBar(row) else {
            print("QA: \(id) never cleared the bottom bar: row \(row.exists ? "\(row.frame)" : "missing"), bar top \(drivingBarTop.map { "\($0)" } ?? "none")")
            return false
        }
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
