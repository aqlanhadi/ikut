import Foundation
import Testing
@testable import ikut

@MainActor
@Suite("Live Activity controller")
struct ConvoyActivityControllerTests {
    typealias State = ConvoyActivityAttributes.ContentState

    final class FakeClient: ConvoyActivityClient {
        var isRunning = false
        var isEnabled = true
        var log: [String] = []
        var stales: [Date?] = []
        func start(tripId: String, state: State, staleDate: Date?) throws {
            isRunning = true
            log.append("start \(state.kind.rawValue)")
            stales.append(staleDate)
        }
        func update(_ state: State, staleDate: Date?) {
            log.append("update \(state.kind.rawValue)")
            stales.append(staleDate)
        }
        func end(final state: State?, dismissAfter: TimeInterval?) {
            isRunning = false
            log.append(dismissAfter.map { "end \(state?.kind.rawValue ?? "-") after \(Int($0))" } ?? "end now")
        }
    }

    final class Clock { var now = Date(timeIntervalSince1970: 1_800_000_000) }

    func make(_ client: FakeClient, _ clock: Clock, _ input: @escaping () -> ConvoyActivityController.Wanted) -> ConvoyActivityController {
        ConvoyActivityController(tripId: "t", client: client, clock: { clock.now }, wanted: input)
    }

    func input(_ clock: Clock, _ edit: (inout ConvoyActivityInput) -> Void = { _ in }) -> ConvoyActivityInput {
        var i = ConvoyActivityInput(now: clock.now, tripName: "Trip", destination: "Ipoh")
        i.myOffset = 1_000
        i.dots = [.init(name: "Me", color: "#2563EB", offset: 1_000, gapAhead: nil, isMine: true)]
        i.newestOtherData = clock.now
        edit(&i)
        return i
    }

    @Test func startsOnceThenPacesUpdates() {
        let client = FakeClient(), clock = Clock()
        var meters = 63_000.0
        let c = make(client, clock) { .yes(input(clock) { $0.destinationMeters = meters }) }
        c.tick()
        #expect(client.log == ["start inConvoy"])
        // Nothing changed for 10 s: nothing sent. A change before 15 s waits; after 15 s it goes.
        clock.now += 10
        c.tick()
        meters = 62_000
        c.tick()
        #expect(client.log.count == 1)
        clock.now += 6
        c.tick()
        #expect(client.log == ["start inConvoy", "update inConvoy"])
        // Unchanged: the 30 s heartbeat still sends, so a car stuck in a jam does not read Not updating.
        clock.now += 29
        c.tick()
        #expect(client.log.count == 2)
        clock.now += 2
        c.tick()
        #expect(client.log.count == 3)
    }

    @Test func aNewStateGoesAtOnce() {
        let client = FakeClient(), clock = Clock()
        var hazard: ConvoyActivityInput.Hazard?
        let c = make(client, clock) { .yes(input(clock) { $0.hazard = hazard }) }
        c.tick()
        clock.now += 1
        hazard = .init(label: "Debris", reporter: nil, meters: 350, offset: 1_350)
        c.tick()
        #expect(client.log == ["start inConvoy", "update hazardAhead"])
    }

    @Test func staysOffWhenLiveActivitiesAreSwitchedOff() {
        let client = FakeClient(), clock = Clock()
        client.isEnabled = false
        let c = make(client, clock) { .yes(input(clock)) }
        c.tick()
        #expect(client.log.isEmpty)
    }

    @Test func endsAtOnceWhenThePhoneIsNoLongerTheTracker() {
        let client = FakeClient(), clock = Clock()
        var wanted = true
        let c = make(client, clock) { wanted ? .yes(input(clock)) : .no }
        c.tick()
        wanted = false
        c.tick()
        #expect(client.log == ["start inConvoy", "end now"])
    }

    @Test func loadingTouchesNothing() {
        let client = FakeClient(), clock = Clock()
        let c = make(client, clock) { .loading }
        c.tick()
        #expect(client.log.isEmpty)
    }

    @Test func leavingEndsAtOnce() {
        let client = FakeClient(), clock = Clock()
        let c = make(client, clock) { .yes(input(clock)) }
        c.tick()
        c.leave()
        #expect(client.log == ["start inConvoy", "end now"])
    }

    @Test func arrivedStaysFifteenMinutesAndLeavingDoesNotCutItShort() {
        let client = FakeClient(), clock = Clock()
        var arrived = false
        let c = make(client, clock) { .yes(input(clock) { if arrived { $0.arrived = .init(count: 1, total: 1, driveSeconds: 3_600) } }) }
        c.tick()
        arrived = true
        clock.now += 1
        c.tick()
        #expect(client.log == ["start inConvoy", "end arrived after 900"])
        #expect(c.isFinished)
        c.leave()
        c.tick()
        #expect(client.log.count == 2)
    }

    @Test func pacingRules() {
        typealias P = ConvoyActivityController.Pacing
        #expect(P.shouldSend(kindChanged: true, changed: true, sinceLast: 0))
        #expect(!P.shouldSend(kindChanged: false, changed: true, sinceLast: 14))
        #expect(P.shouldSend(kindChanged: false, changed: true, sinceLast: 15))
        #expect(!P.shouldSend(kindChanged: false, changed: false, sinceLast: 29))
        #expect(P.shouldSend(kindChanged: false, changed: false, sinceLast: 30))
    }
}
