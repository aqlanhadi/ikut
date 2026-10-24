import Foundation
import Testing
@testable import ikut

struct YouTagTests {
    @Test func offlineWhenThePathIsDown() {
        #expect(!YouOnline.isOnline(pathUp: false, isTracker: true, carStale: false))
        #expect(!YouOnline.isOnline(pathUp: false, isTracker: false, carStale: false))
    }

    @Test func aStaleTrackerIsOfflineButAStalePassengerCarIsNot() {
        #expect(!YouOnline.isOnline(pathUp: true, isTracker: true, carStale: true))
        #expect(YouOnline.isOnline(pathUp: true, isTracker: false, carStale: true))
    }

    @Test func aFreshTrackerWithAPathIsOnline() {
        #expect(YouOnline.isOnline(pathUp: true, isTracker: true, carStale: false))
    }

    @Test func wordsNeverRelyOnColourAlone() {
        #expect(YouOnline.spoken(online: true) == "You")
        #expect(YouOnline.spoken(online: false) == "You, offline")
        #expect(YouOnline.text(online: false, differentiateWithoutColor: true) == "You · Offline")
        #expect(YouOnline.text(online: false, differentiateWithoutColor: false) == "You")
        #expect(YouOnline.text(online: true, differentiateWithoutColor: true) == "You")
    }

    @MainActor @Test func aChangeShowsOnlyAfterTheHold() async throws {
        let status = NetworkStatus(source: Feed(), hold: .milliseconds(150))
        status.observe(false)
        #expect(status.isUp)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!status.isUp)
    }

    @MainActor @Test func aBlipShorterThanTheHoldNeverShows() async throws {
        let status = NetworkStatus(source: Feed(), hold: .milliseconds(200))
        status.observe(false)
        try await Task.sleep(for: .milliseconds(60))
        status.observe(true)
        try await Task.sleep(for: .milliseconds(450))
        #expect(status.isUp)
    }

    @MainActor @Test func myMarkerAndRowsFollowThePath() {
        let model = MapDemo.model()
        #expect(model.youOnline)
        #expect(model.markers.first { $0.isMine }?.youOnline == true)
        model.networkUp = false
        #expect(!model.youOnline)
        #expect(model.markers.first { $0.isMine }?.youOnline == false)
        #expect(!model.markers.contains { !$0.isMine && !$0.youOnline })
        #expect(model.convoy.convoyRows(myCarId: model.myCarId).first { $0.isMine }?.name == model.myCar?.name)
    }

    private struct Feed: NetworkPathSource {
        func paths() -> AsyncStream<Bool> { AsyncStream { $0.finish() } }
    }
}
