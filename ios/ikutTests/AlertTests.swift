import FirebaseAuth
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

// MARK: Fakes

@MainActor
private final class AlertFakeSource: AlertEventSource {
    private var continuation: AsyncStream<[TripEvent]>.Continuation?
    private(set) var tripIds: [String] = []

    func events(tripId: String) -> AsyncStream<[TripEvent]> {
        tripIds.append(tripId)
        return AsyncStream { continuation in self.continuation = continuation }
    }

    func emit(_ events: [TripEvent]) { continuation?.yield(events) }
}

@MainActor
private final class AlertFakeNotifier: AlertNotifier {
    private(set) var posted: [TripAlert] = []
    private(set) var categories: [String] = []
    func requestAuthorization() async -> Bool { true }
    func registerCategory(tripId: String) { categories.append(tripId) }
    func post(_ alert: TripAlert) async { posted.append(alert) }
}

@MainActor
private final class AlertFakeSpeaker: AlertSpeaker {
    private(set) var spoken: [(text: String, key: String)] = []
    private(set) var stops = 0
    func enqueue(_ text: String, key: String) { spoken.append((text, key)) }
    func stop() { stops += 1 }
}

@MainActor
private final class AlertFakeNames: AlertNameSource {
    func displayName(tripId: String, userId: String) async -> String? { userId == "ana" ? "Aqlan" : nil }
}

@MainActor
private final class AlertFakeEngine: SpeechEngine {
    private(set) var spoken: [String] = []
    private(set) var overlap = false
    private var active = 0
    private(set) var stops = 0

    func speak(_ text: String) async {
        if active > 0 { overlap = true }
        active += 1
        spoken.append(text)
        try? await Task.sleep(for: .milliseconds(10))
        active -= 1
    }

    func stop() { stops += 1 }
}

private let alertT0 = Fixtures.t0

private func alertEvent(
    _ type: EventType, id: String, author: String = "ana", ago: TimeInterval = 0, message: String? = nil
) -> TripEvent {
    var e = TripEvent(
        type: type, location: GeoPoint(latitude: 3, longitude: 101), heading: 0, routeOffset: 0,
        authorId: author, carId: "c", createdAt: alertT0.addingTimeInterval(-ago), message: message)
    e.id = id
    return e
}

// MARK: Policy

struct AlertPolicyTests {
    @Test func skipsOwnEvents() {
        var policy = AlertPolicy(myUserId: "me")
        _ = policy.newEvents(from: [], now: alertT0)
        let out = policy.newEvents(from: [alertEvent(.debris, id: "1", author: "me"), alertEvent(.debris, id: "2")], now: alertT0)
        #expect(out.map(\.id) == ["2"])
    }

    @Test func skipsSeen() {
        var policy = AlertPolicy(myUserId: "me")
        _ = policy.newEvents(from: [], now: alertT0)
        #expect(policy.newEvents(from: [alertEvent(.debris, id: "1")], now: alertT0).count == 1)
        #expect(policy.newEvents(from: [alertEvent(.debris, id: "1"), alertEvent(.pothole, id: "2")], now: alertT0).map(\.id) == ["2"])
        #expect(policy.newEvents(from: [alertEvent(.debris, id: "1")], now: alertT0).isEmpty)
    }

    @Test func backlogOnlyRecentHighSeverity() {
        var policy = AlertPolicy(myUserId: "me")
        let backlog = [
            alertEvent(.debris, id: "fresh-high", ago: 90),
            alertEvent(.debris, id: "old-high", ago: 121),
            alertEvent(.heavyRain, id: "fresh-medium", ago: 10),
            alertEvent(.message, id: "fresh-low", ago: 5),
            alertEvent(.carTrouble, id: "fresh-status", ago: 30),
        ]
        #expect(Set(policy.newEvents(from: backlog, now: alertT0).compactMap(\.id)) == ["fresh-high", "fresh-status"])
        // Skipped backlog events are still marked seen, so they never announce later.
        #expect(policy.newEvents(from: backlog, now: alertT0).isEmpty)
        // After the first snapshot every new event counts, whatever its severity.
        #expect(policy.newEvents(from: [alertEvent(.message, id: "later")], now: alertT0).map(\.id) == ["later"])
    }

    @Test func ranksBySeverityThenNewest() {
        var policy = AlertPolicy(myUserId: "me")
        _ = policy.newEvents(from: [], now: alertT0)
        let out = policy.newEvents(from: [
            alertEvent(.message, id: "low", ago: 1),
            alertEvent(.heavyRain, id: "medium", ago: 5),
            alertEvent(.pothole, id: "high-old", ago: 20),
            alertEvent(.debris, id: "high-new", ago: 2),
        ], now: alertT0)
        #expect(out.map(\.id) == ["high-new", "high-old", "medium", "low"])
    }
}

// MARK: Wording

struct AlertWordingTests {
    private func alert(_ e: TripEvent, distance: Double? = nil, name: String? = "Aqlan") -> TripAlert {
        AlertWording.alert(for: e, tripId: "t", distance: distance, authorName: name, now: alertT0)
    }

    @Test func hazardArrival() {
        let a = alert(alertEvent(.debris, id: "1", ago: 6 * 60 + 5))
        #expect(a.title == "Debris reported")
        #expect(a.body == "Debris reported by Aqlan’s car · 6 min ago")
        #expect(a.spoken == "Debris reported by Aqlan’s car.")
        #expect(a.id == "1")
    }

    @Test func approach() {
        let a = alert(alertEvent(.debris, id: "1", ago: 360), distance: 500)
        #expect(a.id == "1@approach")
        #expect(a.title == "Debris ahead in 500 meters")
        #expect(a.spoken == "Debris ahead in 500 meters, reported by Aqlan’s car.")
    }

    @Test func distanceText() {
        #expect(AlertWording.distanceText(512) == "500 meters")
        #expect(AlertWording.distanceText(10) == "50 meters")
        #expect(AlertWording.distanceText(1_000) == "1 km")
        #expect(AlertWording.distanceText(1_240) == "1.2 km")
    }

    @Test func relativeTime() {
        #expect(AlertWording.relativeTime(since: nil, now: alertT0) == "just now")
        #expect(AlertWording.relativeTime(since: alertT0.addingTimeInterval(30), now: alertT0) == "just now")
        #expect(AlertWording.relativeTime(since: alertT0.addingTimeInterval(-59), now: alertT0) == "just now")
        #expect(AlertWording.relativeTime(since: alertT0.addingTimeInterval(-60), now: alertT0) == "1 min ago")
        #expect(AlertWording.relativeTime(since: alertT0.addingTimeInterval(-59 * 60), now: alertT0) == "59 min ago")
        #expect(AlertWording.relativeTime(since: alertT0.addingTimeInterval(-3 * 3600), now: alertT0) == "3 hr ago")
    }

    @Test func unknownAuthor() {
        #expect(alert(alertEvent(.pothole, id: "1"), name: nil).body == "Pothole reported by another car · just now")
        #expect(alert(alertEvent(.pothole, id: "1"), name: "  ").body == "Pothole reported by another car · just now")
    }

    @Test func stopsStatusesAndMessages() {
        #expect(alert(alertEvent(.stopToilet, id: "1", ago: 120)).body == "Aqlan’s car needs a toilet break · 2 min ago")
        // Spoken once, and it says what to do; voice answers are not built, so it never says "say OK".
        // The same line for every car, the lead car and the organizer too.
        #expect(alert(alertEvent(.stopFuel, id: "1")).spoken == "Aqlan needs fuel. Tap OK.")
        #expect(alert(alertEvent(.stopFood, id: "1"), name: nil).spoken == "Another car needs food. Tap OK.")
        #expect(alert(alertEvent(.stopToilet, id: "1")).spoken == "Aqlan needs a toilet break. Tap OK.")
        #expect(alert(alertEvent(.stopRest, id: "1")).spoken == "Aqlan needs a rest. Tap OK.")
        // The banner and notification keep their own wording.
        #expect(alert(alertEvent(.stopFuel, id: "1")).body == "Aqlan’s car wants to stop for fuel · just now")
        #expect(alert(alertEvent(.carTrouble, id: "1")).spoken == "Aqlan’s car has car trouble.")
        #expect(alert(alertEvent(.runningLate, id: "1"), name: nil).spoken == "Another car is running late.")
        let m = alert(alertEvent(.message, id: "1", message: "Makan dulu?"))
        #expect(m.body == "Aqlan’s car: “Makan dulu?” · just now")
        #expect(m.spoken == "Message from Aqlan’s car: Makan dulu?")
        #expect(alert(alertEvent(.other("x"), id: "1")).spoken == "Message from Aqlan’s car.")
    }
}

// MARK: Speech

@MainActor
struct SpeechQueueTests {
    @Test func speaksInOrderWithoutOverlap() async {
        let engine = AlertFakeEngine()
        let queue = SpeechQueue(engine: engine)
        queue.enqueue("one", key: "1")
        queue.enqueue("two", key: "2")
        queue.enqueue("three", key: "3")
        await queue.waitUntilIdle()
        #expect(engine.spoken == ["one", "two", "three"])
        #expect(!engine.overlap)
        #expect(queue.isIdle)
    }

    @Test func dropsDuplicatesEvenAfterSpoken() async {
        let engine = AlertFakeEngine()
        let queue = SpeechQueue(engine: engine)
        queue.enqueue("one", key: "1")
        queue.enqueue("one again", key: "1")
        await queue.waitUntilIdle()
        queue.enqueue("one later", key: "1")
        queue.enqueue("", key: "empty")
        await queue.waitUntilIdle()
        #expect(engine.spoken == ["one"])
    }

    @Test func capsPendingDroppingOldest() async {
        let engine = AlertFakeEngine()
        let queue = SpeechQueue(engine: engine, maxPending: 2)
        for i in 1...5 { queue.enqueue("m\(i)", key: "\(i)") }
        await queue.waitUntilIdle()
        // The drain task starts after the loop, so only the newest two are left.
        #expect(engine.spoken == ["m4", "m5"])
    }

    @Test func stopClearsQueueAndStopsEngine() async {
        let engine = AlertFakeEngine()
        let queue = SpeechQueue(engine: engine)
        queue.enqueue("one", key: "1")
        queue.enqueue("two", key: "2")
        queue.stop()
        await queue.waitUntilIdle()
        #expect(engine.stops == 1)
        #expect(!engine.spoken.contains("two"))
        queue.enqueue("three", key: "3")
        await queue.waitUntilIdle()
        #expect(engine.spoken.last == "three")
    }

    @Test func voicePickerPrefersMalaysianThenBritishThenAustralian() {
        let gb = VoiceCandidate(identifier: "gb", language: "en-GB", quality: 1)
        let gbBetter = VoiceCandidate(identifier: "gb+", language: "en_GB", quality: 2)
        let au = VoiceCandidate(identifier: "au", language: "en-AU", quality: 3)
        let us = VoiceCandidate(identifier: "us", language: "en-US", quality: 3)
        let my = VoiceCandidate(identifier: "my", language: "en-MY", quality: 1)
        #expect(VoicePicker.pick(from: [us, au, gb, my])?.identifier == "my")
        #expect(VoicePicker.pick(from: [us, au, gb, gbBetter])?.identifier == "gb+")
        #expect(VoicePicker.pick(from: [us, au])?.identifier == "au")
        #expect(VoicePicker.pick(from: [us]) == nil)
        #expect(VoicePicker.pick(from: []) == nil)
    }

    @Test func settingDefaultsOn() {
        let defaults = UserDefaults(suiteName: "ikut.alerts.test.\(UUID().uuidString)")!
        #expect(AlertSettings.readAloud(defaults))
        defaults.set(false, forKey: AlertSettings.readAloudKey)
        #expect(!AlertSettings.readAloud(defaults))
    }
}

// MARK: Center

@MainActor
struct AlertCenterTests {
    @MainActor private struct Rig {
        let source = AlertFakeSource()
        let notifier = AlertFakeNotifier()
        let speaker = AlertFakeSpeaker()
        let center: AlertCenter
        let state: State

        @MainActor final class State {
            var foreground = true
            var readAloud = true
        }

        init(bannerDuration: Duration = .seconds(60)) {
            let state = State()
            self.state = state
            center = AlertCenter(
                source: source, notifier: notifier, speaker: speaker, names: AlertFakeNames(),
                isForeground: { state.foreground }, readAloud: { state.readAloud },
                now: { alertT0 }, bannerDuration: bannerDuration)
        }
    }

    @Test func foregroundShowsBannerAndSpeaksButDoesNotNotify() async {
        let rig = Rig()
        rig.center.start(tripId: "t", myUserId: "me")
        rig.source.emit([])
        rig.source.emit([alertEvent(.debris, id: "1", ago: 360)])
        await waitUntil { rig.center.current != nil }
        #expect(rig.center.current?.body == "Debris reported by Aqlan’s car · 6 min ago")
        #expect(rig.notifier.posted.isEmpty)
        #expect(rig.speaker.spoken.map(\.text) == ["Debris reported by Aqlan’s car."])
        #expect(rig.notifier.categories == ["t"])
    }

    @Test func backgroundPostsNotificationAndKeepsBannerEmpty() async {
        let rig = Rig()
        rig.state.foreground = false
        rig.center.start(tripId: "t", myUserId: "me")
        rig.source.emit([])
        rig.source.emit([alertEvent(.debris, id: "1")])
        await waitUntil { !rig.notifier.posted.isEmpty }
        #expect(rig.notifier.posted.map(\.id) == ["1"])
        #expect(rig.notifier.posted.first?.tripId == "t")
        #expect(rig.center.current == nil)
        #expect(rig.speaker.spoken.count == 1)
    }

    @Test func readAloudOffStaysSilent() async {
        let rig = Rig()
        rig.state.readAloud = false
        rig.center.start(tripId: "t", myUserId: "me")
        rig.source.emit([])
        rig.source.emit([alertEvent(.debris, id: "1")])
        await waitUntil { rig.center.current != nil }
        #expect(rig.speaker.spoken.isEmpty)
    }

    @Test func backlogIsSkippedExceptRecentHigh() async {
        let rig = Rig()
        rig.center.start(tripId: "t", myUserId: "me")
        rig.source.emit([
            alertEvent(.debris, id: "old", ago: 600), alertEvent(.message, id: "msg", ago: 5),
            alertEvent(.accident, id: "recent", ago: 30),
        ])
        await waitUntil { !rig.speaker.spoken.isEmpty }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.speaker.spoken.map(\.key) == ["recent"])
    }

    @Test func selfAndRepeatedEventsAreNotAnnounced() async {
        let rig = Rig()
        rig.center.start(tripId: "t", myUserId: "me")
        rig.source.emit([])
        rig.source.emit([alertEvent(.debris, id: "mine", author: "me")])
        rig.source.emit([alertEvent(.debris, id: "1"), alertEvent(.debris, id: "mine", author: "me")])
        rig.source.emit([alertEvent(.debris, id: "1")])
        await waitUntil { !rig.speaker.spoken.isEmpty }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.speaker.spoken.map(\.key) == ["1"])
    }

    @Test func batchIsAnnouncedMostSevereFirstAndBannerKeepsTheMostSevere() async {
        let rig = Rig()
        rig.center.start(tripId: "t", myUserId: "me")
        rig.source.emit([])
        rig.source.emit([alertEvent(.message, id: "low"), alertEvent(.debris, id: "high", ago: 10), alertEvent(.heavyRain, id: "mid")])
        await waitUntil { rig.speaker.spoken.count == 3 }
        #expect(rig.speaker.spoken.map(\.key) == ["high", "mid", "low"])
        #expect(rig.center.current?.id == "high")
    }

    @Test func approachAlertIsSeparateFromArrivalAndOnlyOnce() async {
        let rig = Rig()
        rig.center.start(tripId: "t", myUserId: "me")
        rig.source.emit([])
        let e = alertEvent(.debris, id: "1", ago: 360)
        rig.source.emit([e])
        await waitUntil { rig.speaker.spoken.count == 1 }
        #expect(await rig.center.announce(event: e, distance: 500))
        #expect(!(await rig.center.announce(event: e, distance: 500)))
        #expect(!(await rig.center.announce(event: e)))
        #expect(rig.speaker.spoken.map(\.key) == ["1", "1@approach"])
        #expect(rig.speaker.spoken.last?.text == "Debris ahead in 500 meters, reported by Aqlan’s car.")
        #expect(rig.center.current?.title == "Debris ahead in 500 meters")
    }

    @Test func announceIgnoresOwnEventsAndRequiresStart() async {
        let rig = Rig()
        #expect(!(await rig.center.announce(event: alertEvent(.debris, id: "1"))))
        rig.center.start(tripId: "t", myUserId: "me")
        #expect(!(await rig.center.announce(event: alertEvent(.debris, id: "2", author: "me"), distance: 500)))
        #expect(rig.speaker.spoken.isEmpty)
    }

    @Test func bannerTimesOutAndDismisses() async {
        let rig = Rig(bannerDuration: .milliseconds(50))
        rig.center.start(tripId: "t", myUserId: "me")
        rig.source.emit([])
        rig.source.emit([alertEvent(.debris, id: "1")])
        await waitUntil { rig.center.current != nil }
        await waitUntil { rig.center.current == nil }
        #expect(rig.center.current == nil)
        rig.source.emit([alertEvent(.debris, id: "2")])
        await waitUntil { rig.center.current != nil }
        rig.center.dismiss()
        #expect(rig.center.current == nil)
    }

    @Test func stopClearsAndSilences() async {
        let rig = Rig()
        rig.center.start(tripId: "t", myUserId: "me")
        rig.source.emit([])
        rig.source.emit([alertEvent(.debris, id: "1")])
        await waitUntil { rig.center.current != nil }
        rig.center.stop()
        #expect(rig.center.current == nil)
        #expect(rig.speaker.stops >= 1)
    }

    @Test func aPassengersMessageIsNeverSpokenOrShownInTheBanner() async {
        var request = alertEvent(.stopFuel, id: "s1")
        request.message = "Low on fuel, next R&R please"
        let built = AlertWording.alert(for: request, tripId: "t", authorName: "Aqlan", now: alertT0)
        #expect(built.spoken == "Aqlan needs fuel. Tap OK.")
        #expect(!built.body.contains("R&R"))
        let rig = Rig()
        rig.center.start(tripId: "t", myUserId: "me")
        rig.source.emit([])
        rig.source.emit([request])
        await waitUntil { rig.speaker.spoken.count == 1 }
        #expect(rig.speaker.spoken.first?.text == "Aqlan needs fuel. Tap OK.")
    }

    @Test func aClosedStopRequestIsNotAnnouncedAgain() async {
        let rig = Rig()
        rig.center.start(tripId: "t", myUserId: "me")
        rig.source.emit([])
        let request = alertEvent(.stopFuel, id: "s1")
        rig.source.emit([request])
        await waitUntil { rig.speaker.spoken.count == 1 }
        var closed = request
        closed.status = .closed
        closed.closedReason = .stopped
        rig.source.emit([closed])
        try? await Task.sleep(for: .milliseconds(80))
        #expect(rig.speaker.spoken.map(\.key) == ["s1"])
    }

    @Test func notificationIdentifiersArePerTrip() {
        #expect(AlertCenter.categoryIdentifier(tripId: "abc") == "ikut.alerts.abc")
        #expect(AlertCenter.threadIdentifier(tripId: "abc") == "ikut.trip.abc")
        #expect(AlertCenter.interruptionLevel == .active)
    }
}

// MARK: Emulator

/// Runs against the local Auth and Firestore emulators. Start them first, then:
/// `TEST_RUNNER_IKUT_EMULATOR_TESTS=1 xcodebuild test ...`
@Suite(.emulator, .serialized)
@MainActor
struct AlertEmulatorTests {
    init() throws {
        Backend.configure()
        try Auth.auth().signOut()
    }

    /// Aqlan reports debris; Daniel joins afterwards and his `AlertCenter`, fed by the real
    /// `EventService.listen`, announces it by Aqlan's name. Aqlan's own client would not.
    @Test func otherUsersEventReachesCenter() async throws {
        let trip = try await EmulatorTrip.make(name: "Alerts", destination: Fixtures.ipoh)
        let code = try await trip.code()
        try await EventService.report(
            type: .debris, tripId: trip.tripId, carId: trip.carId, authorId: trip.uid,
            location: .init(latitude: 3, longitude: 101), heading: 0, route: nil, previousOffset: nil)

        try Auth.auth().signOut()
        try await Auth.auth().signInAnonymously()
        let daniel = try #require(Auth.auth().currentUser?.uid)
        _ = try await LiveJoinAPI().join(
            code: code, displayName: "Daniel", car: .new(name: "Daniel's City", color: TripService.palette[1]),
            tracker: false)

        let speaker = AlertFakeSpeaker()
        let center = AlertCenter(
            notifier: AlertFakeNotifier(), speaker: speaker, isForeground: { true }, readAloud: { true })
        center.start(tripId: trip.tripId, myUserId: daniel)
        await waitUntil { center.current != nil }
        center.stop()
        #expect(center.current == nil)
        #expect(speaker.spoken.map(\.text) == ["Debris reported by Aqlan’s car."])
    }
}
