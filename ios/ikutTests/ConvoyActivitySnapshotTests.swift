import Foundation
import Testing
@testable import ikut

@Suite("Live Activity snapshot rules")
struct ConvoyActivitySnapshotTests {
    typealias Snapshot = ConvoyActivityInput
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func request(_ id: String, mine: Bool = false, said: Bool = false, asker: Bool = false, asked: TimeInterval? = nil) -> StopRequestState {
        StopRequestState(
            eventId: id, type: .stopFuel, requesterCarId: asker ? "me" : "other", requesterNumber: nil,
            requesterName: id, askedAt: asked.map { now.addingTimeInterval(-$0) }, message: nil,
            rows: [.init(carId: "me", number: 1, colorHex: "#000000", name: "Me", isMine: true, status: (said || asker) ? .ok : .waiting),
                   .init(carId: "other", number: 2, colorHex: "#000000", name: "Other", isMine: false, status: .ok)],
            canMarkStopped: false)
    }

    @Test func choosesTheOldestRequestIOweAnOKOnInsideItsTwoMinutes() {
        let requests = [request("old", asked: 600), request("fresh", asked: 30), request("newer", asked: 10)]
        // "old" was asked 10 minutes ago and never seen: past its window, so the next one I owe is chosen.
        let chosen = Snapshot.chooseRequest(requests, seen: [:], now: now)
        #expect(chosen?.request.eventId == "fresh" && chosen?.owes == true)
        // What the phone saw first wins over when it was asked.
        let seen = Snapshot.chooseRequest(requests, seen: ["old": now.addingTimeInterval(-20)], now: now)
        #expect(seen?.request.eventId == "old")
    }

    @Test func aRequestWithNoTimeIsTreatedAsExpired() {
        let chosen = Snapshot.chooseRequest([request("x")], seen: [:], now: now)
        #expect(chosen == nil)
    }

    @Test func theWindowDoesNotRestartEveryTick() {
        let requests = [request("a", asked: 100)]
        let later = now.addingTimeInterval(30)
        #expect(Snapshot.chooseRequest(requests, seen: [:], now: now)?.owes == true)
        #expect(Snapshot.chooseRequest(requests, seen: [:], now: later) == nil)
    }

    @Test func otherwiseMineThenOneISaidOKTo() {
        let expired = request("old", asked: 600)
        let mine = request("mine", asker: true, asked: 900)
        let said = request("said", said: true, asked: 700)
        #expect(Snapshot.chooseRequest([expired, said, mine], seen: [:], now: now)?.request.eventId == "mine")
        #expect(Snapshot.chooseRequest([expired, said], seen: [:], now: now)?.request.eventId == "said")
        #expect(Snapshot.chooseRequest([expired], seen: [:], now: now) == nil)
    }

    @Test func driveTimeIsMeasuredToTheArrivalNotToNow() {
        let departed = now.addingTimeInterval(-3 * 3600)
        let arrived = departed.addingTimeInterval(2 * 3600 + 41 * 60)
        #expect(Snapshot.driveSeconds(departedAt: departed, arrivedAt: arrived) == 9_660)
        #expect(Snapshot.driveSeconds(departedAt: nil, arrivedAt: arrived) == nil)
    }

    @Test func metresNeedThePhonesOwnFixWithinTenSeconds() {
        #expect(Snapshot.hazardMetersAreFresh(fixAt: now.addingTimeInterval(-9), now: now))
        #expect(!Snapshot.hazardMetersAreFresh(fixAt: now.addingTimeInterval(-11), now: now))
        #expect(!Snapshot.hazardMetersAreFresh(fixAt: nil, now: now))
    }
}
