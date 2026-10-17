import FirebaseFirestore
import Foundation
import Observation
import UIKit
import UserNotifications

/// Where `AlertCenter` gets a trip's active events.
@MainActor
protocol AlertEventSource: AnyObject {
    func events(tripId: String) -> AsyncStream<[TripEvent]>
}

/// Posts local notifications while the app is in the background.
@MainActor
protocol AlertNotifier: AnyObject {
    /// Asks for permission, returns whether alerts can be shown.
    func requestAuthorization() async -> Bool
    func registerCategory(tripId: String)
    func post(_ alert: TripAlert) async
}

/// Looks up the display name of the member who reported an event.
@MainActor
protocol AlertNameSource: AnyObject {
    func displayName(tripId: String, userId: String) async -> String?
}

/// Decides which events to announce and announces them: an in-app banner in the foreground, a
/// local notification in the background, and speech in both when "Read alerts aloud" is on.
///
/// Notifications and speech work while the app is running, which includes the background while
/// the tracker keeps running on background location. Nothing is delivered once the app is
/// suspended or killed; that needs push (task A2).
@Observable @MainActor
final class AlertCenter {
    /// The alert to show as a banner, nil when none. Cleared by `dismiss()` or after `bannerDuration`.
    private(set) var current: TripAlert?

    /// `.timeSensitive` needs the Time Sensitive Notifications entitlement, which needs the paid
    /// program, so alerts use `.active` until A2.
    nonisolated static let interruptionLevel: UNNotificationInterruptionLevel = .active
    nonisolated static let categoryPrefix = "ikut.alerts."
    nonisolated static let threadPrefix = "ikut.trip."

    static func categoryIdentifier(tripId: String) -> String { categoryPrefix + tripId }
    static func threadIdentifier(tripId: String) -> String { threadPrefix + tripId }

    @ObservationIgnored private let source: any AlertEventSource
    @ObservationIgnored private let notifier: any AlertNotifier
    @ObservationIgnored private let speaker: any AlertSpeaker
    @ObservationIgnored private let names: any AlertNameSource
    @ObservationIgnored private let isForeground: @MainActor () -> Bool
    @ObservationIgnored private let readAloud: @MainActor () -> Bool
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored let bannerDuration: Duration

    @ObservationIgnored private var tripId: String?
    @ObservationIgnored private var policy: AlertPolicy?
    @ObservationIgnored private var announced: Set<String> = []
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    init(
        source: any AlertEventSource = LiveAlertEventSource(),
        notifier: any AlertNotifier = LiveAlertNotifier(),
        speaker: any AlertSpeaker = SpeechQueue(engine: LiveSpeechEngine()),
        names: any AlertNameSource = LiveAlertNameSource(),
        isForeground: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active },
        readAloud: @escaping @MainActor () -> Bool = { AlertSettings.readAloud() },
        now: @escaping @MainActor () -> Date = { Date() },
        bannerDuration: Duration = .seconds(8)
    ) {
        self.source = source
        self.notifier = notifier
        self.speaker = speaker
        self.names = names
        self.isForeground = isForeground
        self.readAloud = readAloud
        self.now = now
        self.bannerDuration = bannerDuration
    }

    /// Asks for notification permission. The host calls this at a moment that explains itself,
    /// such as when the user joins or starts a trip.
    @discardableResult
    func requestPermission() async -> Bool {
        await notifier.requestAuthorization()
    }

    /// Starts listening to `tripId`'s events. Replaces any earlier listener.
    func start(tripId: String, myUserId: String) {
        stop()
        self.tripId = tripId
        policy = AlertPolicy(myUserId: myUserId)
        announced = []
        notifier.registerCategory(tripId: tripId)
        let stream = source.events(tripId: tripId)
        listenTask = Task { [weak self] in
            for await events in stream {
                guard !Task.isCancelled, let self else { return }
                await self.handle(events)
            }
        }
    }

    func stop() {
        listenTask?.cancel()
        listenTask = nil
        dismissTask?.cancel()
        dismissTask = nil
        speaker.stop()
        current = nil
        tripId = nil
        policy = nil
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        current = nil
    }

    /// Announces `event` once per kind. With a `distance` it is an approach alert ("Debris ahead
    /// in 500 meters"), announced once even if the event itself was announced when it arrived.
    /// Events the user wrote are skipped. Returns whether anything was announced.
    @discardableResult
    func announce(event: TripEvent, distance: Double? = nil) async -> Bool {
        guard let tripId, let policy, let eventId = event.id, event.authorId != policy.myUserId else { return false }
        let key = AlertWording.alertId(eventId: eventId, approach: distance != nil)
        guard announced.insert(key).inserted else { return false }
        let name = await names.displayName(tripId: tripId, userId: event.authorId)
        // The trip may have changed or stopped while the name loaded.
        guard self.tripId == tripId else { return false }
        deliver(AlertWording.alert(for: event, tripId: tripId, distance: distance, authorName: name, now: now()))
        return true
    }

    // MARK: Private

    private func handle(_ events: [TripEvent]) async {
        guard policy != nil else { return }
        let fresh = policy!.newEvents(from: events, now: now())
        for event in fresh { await announce(event: event) }
        let pinned = policy!.newlyPinned(from: events, excluding: fresh)
        for event in pinned { await announcePinned(event: event) }
    }

    /// "Stop pinned: {place}", once, for a stop request that was announced before it had a place.
    @discardableResult
    func announcePinned(event: TripEvent) async -> Bool {
        guard let tripId, let eventId = event.id, let place = event.place,
              announced.contains(eventId), announced.insert(AlertWording.pinnedAlertId(eventId: eventId)).inserted
        else { return false }
        deliver(AlertWording.pinnedAlert(for: event, place: place, tripId: tripId, now: now()))
        return true
    }

    private func deliver(_ alert: TripAlert) {
        if isForeground() {
            show(alert)
        } else {
            let notifier = notifier
            Task { await notifier.post(alert) }
        }
        if readAloud() { speaker.enqueue(alert.spoken, key: alert.id) }
    }

    /// Shows the banner unless a more severe alert is still on screen.
    private func show(_ alert: TripAlert) {
        if let current, current.severity.rank > alert.severity.rank { return }
        current = alert
        dismissTask?.cancel()
        let shown = alert.id
        dismissTask = Task { [weak self, bannerDuration] in
            try? await Task.sleep(for: bannerDuration)
            guard !Task.isCancelled, let self, self.current?.id == shown else { return }
            self.current = nil
        }
    }
}

// MARK: Live dependencies

@MainActor
final class LiveAlertEventSource: AlertEventSource {
    init() {}
    func events(tripId: String) -> AsyncStream<[TripEvent]> { EventService.listen(tripId: tripId) }
}

/// Member display names from `trips/{tripId}/members/{userId}`, cached for the session.
@MainActor
final class LiveAlertNameSource: AlertNameSource {
    private var cache: [String: String] = [:]

    init() {}

    func displayName(tripId: String, userId: String) async -> String? {
        let key = "\(tripId)/\(userId)"
        if let cached = cache[key] { return cached }
        let member = try? await Firestore.firestore()
            .document(FirestorePaths.member(tripId: tripId, userId: userId))
            .getDocument(as: Member.self)
        if let name = member?.displayName { cache[key] = name }
        return member?.displayName
    }
}

@MainActor
final class LiveAlertNotifier: AlertNotifier {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func registerCategory(tripId: String) {
        let category = UNNotificationCategory(
            identifier: AlertCenter.categoryIdentifier(tripId: tripId), actions: [], intentIdentifiers: [],
            options: [])
        let center = center
        Task {
            var categories = await center.notificationCategories()
            categories.update(with: category)
            center.setNotificationCategories(categories)
        }
    }

    func post(_ alert: TripAlert) async {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        content.interruptionLevel = AlertCenter.interruptionLevel
        content.categoryIdentifier = AlertCenter.categoryIdentifier(tripId: alert.tripId)
        content.threadIdentifier = AlertCenter.threadIdentifier(tripId: alert.tripId)
        content.userInfo = ["tripId": alert.tripId, "eventId": alert.eventId]
        try? await center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil))
    }
}
