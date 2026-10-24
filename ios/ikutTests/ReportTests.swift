import CoreLocation
import FirebaseAuth
import FirebaseFirestore
import Foundation
import Testing
import UIKit
@testable import ikut

/// Records calls and can be told to fail.
private final class FakeReportService: ReportService, @unchecked Sendable {
    private let lock = NSLock()
    private var _reports: [ReportRequest] = []
    private var _undone: [String] = []
    private var _next = 0
    var failReport: (any Error)?
    var failUndo: (any Error)?

    var reports: [ReportRequest] { lock.withLock { _reports } }
    var undone: [String] { lock.withLock { _undone } }

    func report(_ request: ReportRequest) async throws -> String {
        if let failReport { throw failReport }
        return lock.withLock {
            _reports.append(request)
            _next += 1
            return "event-\(_next)"
        }
    }

    func undo(tripId: String, eventId: String) async throws {
        if let failUndo { throw failUndo }
        lock.withLock { _undone.append(eventId) }
    }
}

private let snapshot = ReportSnapshot(
    coordinate: .init(latitude: 3, longitude: 101), heading: 90, route: nil, previousOffset: 12,
    capturedAt: Fixtures.t0)

private let context = ReportContext(tripId: "trip", carId: "car", authorId: "me") { snapshot }

private func debris() -> ReportOption { ReportOption.events[0] }

struct ReportOptionTests {
    @Test func eightEventsThenThreeStatusesInOrder() {
        #expect(ReportOption.events.map(\.type) == [
            .debris, .accident, .pothole, .animal, .stoppedVehicle, .roadworks, .heavyRain, .trafficJam,
        ])
        #expect(ReportOption.statuses.map(\.type) == [.pullingOver, .carTrouble, .runningLate])
        #expect(ReportOption.all.count == 11)
        #expect(ReportOption.events.map(\.label) == [
            "Debris", "Accident", "Pothole", "Animal", "Stopped car", "Roadworks", "Heavy rain", "Traffic jam",
        ])
        #expect(ReportOption.statuses.map(\.label) == ["Pulling over", "Car trouble", "Running late"])
    }

    @Test func categoriesMatchSections() {
        #expect(ReportOption.events.allSatisfy { [.hazard, .condition].contains($0.type.category) })
        #expect(ReportOption.statuses.allSatisfy { $0.type.category == .status })
        #expect(Set(ReportOption.all.map(\.id)).count == 11)
    }

    @Test func symbolsExist() {
        for option in ReportOption.all {
            #expect(UIImage(systemName: option.symbol) != nil, "missing symbol \(option.symbol)")
        }
    }

    @Test func toastNameReadsAfterReported() {
        #expect(debris().toastName == "debris")
        #expect(ReportOption.events[4].toastName == "stopped car")
    }

    @Test func pinDetailText() {
        let now = snapshot.capturedAt.addingTimeInterval(75)
        let here = CLLocationCoordinate2D(latitude: 3, longitude: 101.0027) // about 300 m east
        let text = ReportSheet.pinDetail(pinned: snapshot, now: now, current: here)
        #expect(text.hasPrefix("1 min 15 s ago · 3"))
        #expect(text.hasSuffix(" m behind you now"))
        #expect(ReportSheet.pinDetail(pinned: snapshot, now: snapshot.capturedAt.addingTimeInterval(4), current: nil) == "4 s ago")
    }
}

@MainActor
struct ReportToastModelTests {
    private func model(
        _ service: FakeReportService, undo: Duration = .seconds(30), voiceOver: Bool = false
    ) -> ReportToastModel {
        ReportToastModel(service: service, undoWindow: undo, voiceOverRunning: { voiceOver })
    }

    @Test func showsAfterReportWithRequestDetails() async {
        let service = FakeReportService()
        let toast = model(service)
        #expect(toast.state == .hidden)
        let task = toast.submit(debris(), context: context, snapshot: snapshot)
        #expect(toast.state == .sending(label: "debris"))
        await task.value
        #expect(toast.state == .reported(label: "debris", eventId: "event-1"))
        #expect(toast.isUndoAvailable)
        let sent = service.reports.first
        #expect(sent?.type == .debris)
        #expect(sent?.tripId == "trip")
        #expect(sent?.carId == "car")
        #expect(sent?.authorId == "me")
        #expect(sent?.snapshot.previousOffset == 12)
    }

    @Test func undoWithinWindowCallsUndo() async {
        let service = FakeReportService()
        let toast = model(service)
        await toast.submit(debris(), context: context, snapshot: snapshot).value
        await toast.undo()
        #expect(service.undone == ["event-1"])
        #expect(toast.state == .hidden)
    }

    @Test func undoWithNothingToUndoDoesNothing() async {
        let service = FakeReportService()
        let toast = model(service)
        await toast.undo()
        #expect(service.undone.isEmpty)
        #expect(toast.state == .hidden)
    }

    @Test func autoHidesAfterWindowAndUndoIsGone() async {
        let service = FakeReportService()
        let toast = model(service, undo: .milliseconds(80))
        await toast.submit(debris(), context: context, snapshot: snapshot).value
        #expect(toast.isUndoAvailable)
        await waitUntil { toast.state == .hidden }
        #expect(toast.state == .hidden)
        await toast.undo()
        #expect(service.undone.isEmpty)
    }

    @Test func secondReportReplacesFirstAndRestartsWindow() async {
        let service = FakeReportService()
        let toast = model(service, undo: .milliseconds(300))
        await toast.submit(debris(), context: context, snapshot: snapshot).value
        try? await Task.sleep(for: .milliseconds(200))
        await toast.submit(ReportOption.statuses[0], context: context, snapshot: snapshot).value
        #expect(toast.state == .reported(label: "pulling over", eventId: "event-2"))
        // The first window would have closed by now; the second keeps the toast up.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(toast.state == .reported(label: "pulling over", eventId: "event-2"))
        await toast.undo()
        #expect(service.undone == ["event-2"])
    }

    @Test func reportFailureIsSurfaced() async {
        let service = FakeReportService()
        service.failReport = URLError(.notConnectedToInternet)
        let toast = model(service)
        await toast.submit(debris(), context: context, snapshot: snapshot).value
        guard case .failed(let message) = toast.state else {
            Issue.record("expected failed, got \(toast.state)")
            return
        }
        #expect(message.contains("Couldn't report debris"))
        #expect(toast.failureCount == 1)
        #expect(!toast.isUndoAvailable)
    }

    @Test func failureStaysUntilClosed() async throws {
        let service = FakeReportService()
        service.failReport = URLError(.timedOut)
        let toast = model(service, undo: .milliseconds(20))
        await toast.submit(debris(), context: context, snapshot: snapshot).value
        #expect(!toast.hideIsScheduled)
        try await Task.sleep(for: .milliseconds(200))
        guard case .failed = toast.state else {
            Issue.record("the failure vanished: \(toast.state)")
            return
        }
        toast.dismiss()
        #expect(toast.state == .hidden)
    }

    @Test func undoHasAtLeastEightSeconds() {
        #expect(ReportToastModel.undoTime >= .seconds(8))
        #expect(ReportToastModel(service: FakeReportService()).undoWindow >= .seconds(8))
    }

    @Test func undoHoldsWhileVoiceOverRuns() async throws {
        let toast = model(FakeReportService(), undo: .milliseconds(20), voiceOver: true)
        await toast.submit(debris(), context: context, snapshot: snapshot).value
        try await Task.sleep(for: .milliseconds(200))
        #expect(toast.isUndoAvailable)
    }

    @Test func undoFailureIsSurfaced() async {
        let service = FakeReportService()
        let toast = model(service)
        await toast.submit(debris(), context: context, snapshot: snapshot).value
        service.failUndo = URLError(.notConnectedToInternet)
        await toast.undo()
        guard case .failed(let message) = toast.state else {
            Issue.record("expected failed, got \(toast.state)")
            return
        }
        #expect(message.contains("Couldn't undo"))
    }

    @Test func dismissHides() async {
        let toast = model(FakeReportService())
        await toast.submit(debris(), context: context, snapshot: snapshot).value
        toast.dismiss()
        #expect(toast.state == .hidden)
    }
}

/// Runs against the local Auth and Firestore emulators. Start them first, then:
/// `TEST_RUNNER_IKUT_EMULATOR_TESTS=1 xcodebuild test ...`
@Suite(.emulator, .serialized)
@MainActor
struct ReportEmulatorTests {
    init() throws {
        Backend.configure()
        try Auth.auth().signOut()
    }

    @Test func reportThroughRealServiceThenUndo() async throws {
        let ids = try await EmulatorTrip.make(name: "Report")
        let uid = ids.uid
        let live = ReportContext(tripId: ids.tripId, carId: ids.carId, authorId: uid) {
            ReportSnapshot(
                coordinate: .init(latitude: 3, longitude: 101), heading: 10, route: nil,
                previousOffset: nil, capturedAt: Date())
        }
        let toast = ReportToastModel()
        await toast.submit(debris(), context: live, snapshot: try #require(live.snapshot())).value
        guard case .reported(_, let eventId) = toast.state else {
            Issue.record("expected reported, got \(toast.state)")
            return
        }
        let path = FirestorePaths.event(tripId: ids.tripId, eventId: eventId)
        #expect(try await Firestore.firestore().document(path).getDocument().exists)

        await toast.undo()
        #expect(toast.state == .hidden)
        #expect(try await !Firestore.firestore().document(path).getDocument().exists)
    }
}
