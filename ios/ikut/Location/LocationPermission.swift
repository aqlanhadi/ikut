import CoreLocation
import Observation
import UIKit

/// Wraps `CLLocationManager` authorization as async calls that resolve once the user has answered.
///
/// The delegate callbacks are nonisolated, so the delegate only forwards Sendable values
/// through a `@Sendable` closure that hops to the main actor.
@Observable @MainActor
final class LocationPermission {
    typealias Status = LocationAccess.Status
    typealias Accuracy = LocationAccess.Accuracy

    /// Purpose key from NSLocationTemporaryUsageDescriptionDictionary.
    static let fullAccuracyPurposeKey = "ConvoyTracking"

    private(set) var status: Status
    private(set) var accuracy: Accuracy
    /// What the app should do before tracking runs in the background (`LocationContext.goingToBackground`): the Always
    /// explainer while only When In Use is given.
    var backgroundAction: LocationAction {
        LocationAccess.nextAction(status: status, accuracy: accuracy, context: .goingToBackground)
    }

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let delegate = Delegate()
    @ObservationIgnored private var waiter: Waiter?
    @ObservationIgnored private var sawPrompt = false
    @ObservationIgnored nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init() {
        status = LocationAccess.status(from: manager.authorizationStatus)
        accuracy = LocationAccess.accuracy(from: manager.accuracyAuthorization)
        delegate.onChange = { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        manager.delegate = delegate

        // A system prompt takes over the screen, so the app resigns active while it is up.
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sawPrompt = true }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.promptDismissed() }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func requestWhenInUse() async -> Status {
        guard status == .notDetermined else { return status }
        await awaitAnswer(until: { $0 != .notDetermined }) { manager.requestWhenInUseAuthorization() }
        return status
    }

    /// Asks for Always. iOS shows this prompt once; later calls return without UI.
    func requestAlways() async -> Status {
        if status == .notDetermined, await requestWhenInUse() == .denied { return status }
        guard status == .whenInUse else { return status }
        await awaitAnswer(until: { $0 == .always }) { manager.requestAlwaysAuthorization() }
        return status
    }

    /// Shows the temporary full-accuracy prompt when the user chose approximate location.
    func requestFullAccuracy() async -> Accuracy {
        guard status == .whenInUse || status == .always, accuracy == .reduced else { return accuracy }
        try? await manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: Self.fullAccuracyPurposeKey)
        refresh()
        return accuracy
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func refresh() {
        status = LocationAccess.status(from: manager.authorizationStatus)
        accuracy = LocationAccess.accuracy(from: manager.accuracyAuthorization)
        if let waiter, waiter.until(status) { finishWait() }
    }

    /// "Keep Only While Using" on the Always prompt changes nothing, so the app becoming
    /// active again is what ends the wait.
    private func promptDismissed() {
        guard waiter != nil, sawPrompt else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            refresh()
            finishWait()
        }
    }

    /// Suspends until the status satisfies `until`, the prompt is dismissed, or iOS shows no prompt.
    private func awaitAnswer(until: @escaping (Status) -> Bool, request: () -> Void) async {
        finishWait()
        sawPrompt = false
        await withCheckedContinuation { continuation in
            let waiter = Waiter(continuation: continuation, until: until)
            self.waiter = waiter
            request()
            // No prompt means no resign-active; don't hang on it. While the status is still
            // notDetermined a prompt is up even if no resign-active arrived (the location prompt
            // on iOS 27 doesn't always send one), so keep waiting for the delegate's answer:
            // giving up here dropped the person back on Home after they tapped Allow.
            Task {
                try? await Task.sleep(for: .seconds(1))
                guard self.waiter === waiter, !sawPrompt else { return }
                refresh()
                if self.waiter === waiter, status != .notDetermined { finishWait() }
            }
        }
    }

    private func finishWait() {
        guard let waiter else { return }
        self.waiter = nil
        waiter.continuation.resume()
    }

    private final class Waiter {
        let continuation: CheckedContinuation<Void, Never>
        let until: (Status) -> Bool
        init(continuation: CheckedContinuation<Void, Never>, until: @escaping (Status) -> Bool) {
            self.continuation = continuation
            self.until = until
        }
    }

    private final class Delegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
        // Set once before the delegate is installed.
        nonisolated(unsafe) var onChange: (@Sendable () -> Void)?

        nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            onChange?()
        }
    }
}
