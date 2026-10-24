import Foundation
import Observation
import UIKit

/// State behind the "Reported debris · Undo" toast. The host screen owns one, passes it to the
/// report sheet and shows `ReportToastView` bound to it, so the toast outlives the sheet.
@Observable @MainActor
final class ReportToastModel {
    enum State: Equatable {
        case hidden
        case sending(label: String)
        case reported(label: String, eventId: String)
        case failed(message: String)
    }

    /// How long Undo stays: long enough to read, find and tap it (D34 N3).
    static let undoTime: Duration = .seconds(8)

    private(set) var state: State = .hidden
    /// Bumped on every success / failure, for haptics.
    private(set) var reportedCount = 0
    private(set) var failureCount = 0

    @ObservationIgnored private let service: any ReportService
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored let undoWindow: Duration
    @ObservationIgnored private let voiceOverRunning: @MainActor () -> Bool
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var tripId: String?

    init(
        service: any ReportService = LiveReportService(),
        undoWindow: Duration = ReportToastModel.undoTime,
        voiceOverRunning: @escaping @MainActor () -> Bool = { UIAccessibility.isVoiceOverRunning },
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.service = service
        self.undoWindow = undoWindow
        self.voiceOverRunning = voiceOverRunning
        self.clock = clock
    }

    /// Whether a timer is set to hide the toast; none while a failure is showing.
    var hideIsScheduled: Bool { hideTask.map { !$0.isCancelled } ?? false }

    var isUndoAvailable: Bool {
        if case .reported = state { true } else { false }
    }

    /// Sends the report and drives the toast. Returns at once; the returned task finishes when
    /// the write has been accepted or has failed. A newer report replaces this one's toast, and
    /// the older report stays sent but can no longer be undone from here.
    @discardableResult
    func submit(_ option: ReportOption, context: ReportContext, snapshot: ReportSnapshot) -> Task<Void, Never> {
        generation += 1
        let mine = generation
        hideTask?.cancel()
        tripId = context.tripId
        state = .sending(label: option.toastName)
        let request = ReportRequest(
            type: option.type, tripId: context.tripId, carId: context.carId,
            authorId: context.authorId, snapshot: snapshot)
        return Task { [service] in
            do {
                let id = try await service.report(request)
                guard mine == generation else { return }
                state = .reported(label: option.toastName, eventId: id)
                reportedCount += 1
                // With VoiceOver running the toast stays (Close or Undo ends it): it can't be read in time.
                if !voiceOverRunning() { scheduleHide(generation: mine, after: undoWindow) }
            } catch {
                guard mine == generation else { return }
                fail("Couldn't report \(option.toastName). \(Self.reason(error))", generation: mine)
            }
        }
    }

    /// Retracts the report on screen. Only works while the undo window is open.
    func undo() async {
        guard case .reported(let label, let eventId) = state, let tripId else { return }
        generation += 1
        let mine = generation
        hideTask?.cancel()
        state = .sending(label: "undoing \(label)")
        do {
            try await service.undo(tripId: tripId, eventId: eventId)
            guard mine == generation else { return }
            state = .hidden
        } catch {
            guard mine == generation else { return }
            fail("Couldn't undo. \(Self.reason(error))", generation: mine)
        }
    }

    func dismiss() {
        generation += 1
        hideTask?.cancel()
        state = .hidden
    }

    #if DEBUG
    /// Puts `state` on the toast with no report behind it and no timeout, for the map demo.
    func showForDemo(_ state: State) { self.state = state }
    #endif

    private func fail(_ message: String, generation _: Int) {
        state = .failed(message: message)
        failureCount += 1
        // A failure stays until it is closed or the next report replaces it.
    }

    private func scheduleHide(generation mine: Int, after delay: Duration) {
        hideTask?.cancel()
        hideTask = Task { [clock] in
            try? await clock.sleep(for: delay)
            guard !Task.isCancelled, mine == generation else { return }
            state = .hidden
        }
    }

    private static func reason(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == "FIRFirestoreErrorDomain", ns.code == 7 { return "You can't report right now." }
        if ns.domain == NSURLErrorDomain { return "Check your connection." }
        return "Try again."
    }
}
