import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

/// The pieces of the stop flow (D121 to D124) no other suite pins down, as tables: who sees We’ve stopped and who sees
/// Continue, what a close writes, the banner's minutes, planned stops held while stopped, and the pill's small words.
@Suite("Stops: the gaps between the suites")
struct StopGapTests {
    let t0 = Fixtures.t0

    // MARK: Who sees what

    /// asker, lead car's tracker, organizer -> We’ve stopped on the card, a phase started by it, Continue on the banner.
    @Test(arguments: [
        (false, false, false, false, false, false),
        (true, false, false, true, false, false),
        (false, true, false, true, true, true),
        (false, false, true, true, true, true),
        (true, true, false, true, true, true),
        (true, false, true, true, true, true),
        (false, true, true, true, true, true),
        (true, true, true, true, true, true),
    ])
    func whoSeesWeveStoppedAndWhoSeesContinue(
        asker: Bool, lead: Bool, organizer: Bool, card: Bool, startsPhase: Bool, continueButton: Bool
    ) {
        #expect(StopPermissions.canMarkStopped(isAuthor: asker, isLeadTracker: lead, isOrganizer: organizer) == card)
        #expect(
            ConvoyStop.startsWith(reason: .stopped, isLeadTracker: lead, isOrganizer: organizer, active: false)
                == startsPhase)
        #expect(ConvoyStop.mayStartOrEnd(isLeadTracker: lead, isOrganizer: organizer) == continueButton)
    }

    @Test func aCancelNeverStartsAPhaseWhoeverTapsIt() {
        for lead in [false, true] {
            for organizer in [false, true] {
                #expect(!ConvoyStop.startsWith(
                    reason: .cancelled, isLeadTracker: lead, isOrganizer: organizer, active: false))
            }
        }
    }

    // MARK: What a close writes

    @Test(arguments: [(StopClosedReason.stopped, "stopped"), (StopClosedReason.cancelled, "cancelled")])
    func aCloseWritesTheReasonWhoAndWhenAndNothingElse(reason: StopClosedReason, raw: String) {
        let data = StopService.closeData(reason: reason, userId: "u1", now: t0)
        #expect(Set(data.keys) == ["status", "closedReason", "closedBy", "expiresAt"])
        #expect(data["status"] as? String == "closed")
        #expect(data["closedReason"] as? String == raw)
        #expect(data["closedBy"] as? String == "u1")
        #expect((data["expiresAt"] as? Timestamp)?.dateValue() == t0)
    }

    // MARK: The banner

    @Test(arguments: [
        (nil as TimeInterval?, 1), (0, 1), (59, 1), (119, 1), (120, 2), (3_599, 59), (3_600, 60), (-30, 1),
    ])
    func theBannerNeverSaysZeroMinutes(age: TimeInterval?, minutes: Int) {
        #expect(ConvoyStop.minutes(since: age.map { t0.addingTimeInterval(-$0) }, now: t0) == minutes)
    }

    // MARK: Planned stops held while stopped

    /// A planned stop is held only when it is more than 500 m past the stop point.
    @Test(arguments: [
        (20_000.0, nil as Double?, false), (20_000, 20_000, false), (20_500, 20_000, false),
        (20_501, 20_000, true), (30_000, 20_000, true), (19_000, 20_000, false),
    ])
    func aPlannedStopJustPastTheStopPointIsWhereTheConvoyIsPullingIn(
        offset: Double, stopOffset: Double?, held: Bool
    ) {
        #expect(ConvoyStop.holdsPlannedStop(offset: offset, stopOffset: stopOffset) == held)
    }

    // MARK: The pill's small words

    @Test(arguments: [(0.0, "asked just now"), (59, "asked just now"), (-5, "asked just now"), (60, "asked 1 min ago")])
    func askedAgoRoundsDownToJustNow(age: TimeInterval, words: String) {
        #expect(StopLogic.askedAgo(since: t0.addingTimeInterval(-age), now: t0) == words)
    }

    @Test(arguments: [
        ("Low on fuel", "Low on fuel"), ("Low on fuel\nnext R&R", "Low on fuel next R&R"),
        ("  a \n\n b  ", "a b"), ("\n\n", ""),
    ])
    func aMessageIsOneLineOnThePill(message: String, line: String) {
        #expect(StopLogic.oneLine(message) == line)
    }

    @Test func everyReasonHasItsOwnIconAndAnythingElseIsARest() {
        let icons = [EventType.stopFuel, .stopFood, .stopToilet].map(StopLogic.reasonSymbol)
        #expect(icons == [Symbol.fuel, Symbol.food, Symbol.toilet])
        #expect(Set(icons).count == 3)
        #expect(StopLogic.reasonSymbol(.stopRest) == Symbol.rest)
    }
}
