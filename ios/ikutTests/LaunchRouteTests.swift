import Foundation
import Testing
@testable import ikut

/// Where the app opens (#401, D54): straight into a trip this phone is still in, else Join for a link, else Home.
@MainActor
struct LaunchRouteTests {
    private func entry(_ id: String, ended: Bool = false) -> PastTrips.Entry {
        PastTrips.Entry(id: id, name: "Trip \(id)", destination: "Ipoh", endedAt: ended ? Date(timeIntervalSince1970: 1) : nil,
                        seenAt: Date(timeIntervalSince1970: 0))
    }

    private let live = HomeNow.Read(line: "Gathering")
    private let started = HomeNow.Read(line: "On the move", started: true)
    private let ended = HomeNow.Read(line: "Ended", endedAt: Date(timeIntervalSince1970: 5))
    private let gone = HomeNow.Read(line: HomeNow.fallbackStatus, gone: true)

    private func decide(signedIn: Bool = true, _ entries: [PastTrips.Entry], _ read: [String: HomeNow.Read],
                        join: String? = nil) -> LaunchRoute {
        LaunchRoute.decide(signedIn: signedIn, entries: entries, read: read, pendingJoin: join)
    }

    @Test func noTripInNowOpensHome() {
        #expect(decide([], [:]) == .home)
        #expect(decide([entry("p", ended: true)], [:]) == .home)
        #expect(!LaunchRoute.needsReads(signedIn: true, entries: [entry("p", ended: true)]))
    }

    @Test func aTripBeforeStartOpensItsLobby() {
        #expect(decide([entry("a")], ["a": live]) == .trip(id: "a", started: false))
        #expect(LaunchRoute.needsReads(signedIn: true, entries: [entry("a")]))
    }

    @Test func aStartedTripOpensTheDrivingMap() {
        #expect(decide([entry("a")], ["a": started]) == .trip(id: "a", started: true))
    }

    @Test func aTripThatEndedOrThatThisPhoneLeftOrWasRemovedFromOpensHome() {
        #expect(decide([entry("a")], ["a": ended]) == .home)
        #expect(decide([entry("a")], ["a": gone]) == .home)
    }

    @Test func severalTripsOpenTheNewestStillGoing() {
        #expect(decide([entry("new"), entry("old")], ["new": started, "old": live]) == .trip(id: "new", started: true))
        // The newest ended while the app was closed: the next one still going.
        #expect(decide([entry("new"), entry("old")], ["new": ended, "old": live]) == .trip(id: "old", started: false))
        #expect(decide([entry("new"), entry("mid"), entry("old")], ["new": gone, "mid": ended, "old": started])
                == .trip(id: "old", started: true))
        // Past trips never open, even when listed first.
        #expect(decide([entry("past", ended: true), entry("now")], ["now": live]) == .trip(id: "now", started: false))
    }

    @Test func aTripThatCouldNotBeReadCountsAsStillGoing() {
        // No signal or too slow: the trip screen opens and says what it finds.
        #expect(decide([entry("a")], [:]) == .trip(id: "a", started: false))
        #expect(decide([entry("a")], ["a": live]) == .trip(id: "a", started: false))
    }

    @Test func signedOutNeverOpensATrip() {
        #expect(decide(signedIn: false, [entry("a")], ["a": live]) == .home)
        #expect(!LaunchRoute.needsReads(signedIn: false, entries: [entry("a")]))
        #expect(decide(signedIn: false, [entry("a")], [:], join: "K7M2QX") == .join(code: "K7M2QX"))
    }

    @Test func aJoinLinkOpensJoinButNeverPullsYouOutOfATrip() {
        #expect(decide([], [:], join: "K7M2QX") == .join(code: "K7M2QX"))
        #expect(decide([entry("a")], ["a": ended], join: "K7M2QX") == .join(code: "K7M2QX"))
        #expect(decide([entry("a")], ["a": live], join: "K7M2QX") == .trip(id: "a", started: false))
    }

    @Test func loadingReadsNewestFirstMovesEndedOnesToPastAndStopsAtOneStillGoing() async {
        var asked: [String] = []
        var moved: [String] = []
        let reads: [String: HomeNow.Read] = ["new": ended, "mid": gone, "old": started, "older": live]
        let route = await LaunchRoute.load(
            signedIn: true, pendingJoin: nil,
            entries: [entry("new"), entry("mid"), entry("old"), entry("older")],
            read: { id in asked.append(id); return reads[id]! },
            record: { entry, _, _ in moved.append(entry.id) })
        #expect(route == .trip(id: "old", started: true))
        #expect(asked == ["new", "mid", "old"])
        #expect(moved == ["new", "mid"])
    }

    @Test func loadingSignedOutReadsNothing() async {
        var asked = 0
        let route = await LaunchRoute.load(
            signedIn: false, pendingJoin: nil, entries: [entry("a")],
            read: { _ in asked += 1; return HomeNow.Read(line: "") }, record: { _, _, _ in })
        #expect(route == .home)
        #expect(asked == 0)
    }

    @Test func aReadThatNeverAnswersOpensTheTripAfterFourSeconds() async {
        let clock = ContinuousClock()
        let start = clock.now
        let route = await LaunchRoute.load(
            signedIn: true, pendingJoin: nil, entries: [entry("a")],
            read: { _ in
                try? await Task.sleep(for: .seconds(60))
                return HomeNow.Read(line: "")
            },
            cached: { _ in nil }, record: { _, _, _ in })
        let waited = clock.now - start
        #expect(route == .trip(id: "a", started: false))
        #expect(waited >= LaunchRoute.readTimeout)
        #expect(waited < .seconds(10))
    }

    @Test func inATunnelThePhonesOwnCopySaysItStarted() async {
        let route = await LaunchRoute.load(
            signedIn: true, pendingJoin: nil, entries: [entry("a")], timeout: .milliseconds(100),
            read: { _ in
                try? await Task.sleep(for: .seconds(60))
                return HomeNow.Read(line: "")
            },
            cached: { _ in HomeNow.Read(line: "", started: true) }, record: { _, _, _ in })
        #expect(route == .trip(id: "a", started: true))
    }
}
