import UIKit
import UserNotifications

/// The notification setting, reduced to what the asks care about.
enum NotificationAccess: Equatable {
    case notDetermined, denied, allowed

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .authorized, .provisional, .ephemeral: self = .allowed
        @unknown default: self = .allowed
        }
    }

    static func current() async -> NotificationAccess {
        NotificationAccess(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
    }
}

/// A question the trip map asks at trip start.
enum TripAsk: Equatable {
    /// Notifications not decided yet: leads to the system prompt.
    case roadAlerts
    /// Notifications turned off in Settings: leads to the Settings app.
    case roadAlertsOff
    /// An in-app choice (iOS has no permission for it).
    case keepScreenOn
}

/// Decides which ask comes next, so two never stack and the order is always road alerts, then screen.
enum TripAskPlanner {
    static func next(
        notifications: NotificationAccess, keepAwakeAnswered: Bool, asked: Set<TripAsk>, explainerShowing: Bool
    ) -> TripAsk? {
        // The Always-location sheet is up; ask once it's gone.
        if explainerShowing { return nil }
        switch notifications {
        case .notDetermined where !asked.contains(.roadAlerts): return .roadAlerts
        case .denied where !asked.contains(.roadAlertsOff): return .roadAlertsOff
        default: break
        }
        if !keepAwakeAnswered && !asked.contains(.keepScreenOn) { return .keepScreenOn }
        return nil
    }
}

/// Keeps the screen from sleeping only while the trip map is up for a running trip, with the app in front.
@MainActor
final class ScreenAwake {
    private let setIdleTimerDisabled: @MainActor (Bool) -> Void
    private(set) var isHeld = false

    init(setIdleTimerDisabled: @escaping @MainActor (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 }) {
        self.setIdleTimerDisabled = setIdleTimerDisabled
    }

    static func shouldHold(preference: Bool, onScreen: Bool, tripRunning: Bool, appActive: Bool) -> Bool {
        preference && onScreen && tripRunning && appActive
    }

    func update(preference: Bool, onScreen: Bool, tripRunning: Bool, appActive: Bool) {
        let hold = Self.shouldHold(
            preference: preference, onScreen: onScreen, tripRunning: tripRunning, appActive: appActive)
        guard hold != isHeld else { return }
        isHeld = hold
        setIdleTimerDisabled(hold)
    }
}
