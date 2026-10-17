import CoreLocation

/// What the UI should do next to get location access that is good enough for a trip.
enum LocationAction: Equatable {
    case requestWhenInUse
    case showAlwaysExplainer
    case requestFullAccuracy
    case showSettingsPrompt
    case ready
}

/// Why the app needs location right now.
enum LocationContext: Equatable {
    case joiningTrip
    case goingToBackground
}

enum LocationAccess {
    /// Simplified authorization, with restricted folded into denied.
    enum Status: Equatable {
        case notDetermined
        case denied
        case whenInUse
        case always
    }

    enum Accuracy: Equatable {
        case full
        case reduced
    }

    /// The next step for the given state. Approximate location is never enough for a convoy.
    static func nextAction(status: Status, accuracy: Accuracy, context: LocationContext) -> LocationAction {
        switch status {
        case .notDetermined:
            return .requestWhenInUse
        case .denied:
            return .showSettingsPrompt
        case .whenInUse:
            if accuracy == .reduced { return .requestFullAccuracy }
            return context == .goingToBackground ? .showAlwaysExplainer : .ready
        case .always:
            return accuracy == .reduced ? .requestFullAccuracy : .ready
        }
    }

    static func status(from raw: CLAuthorizationStatus) -> Status {
        switch raw {
        case .notDetermined: .notDetermined
        case .restricted, .denied: .denied
        case .authorizedWhenInUse: .whenInUse
        case .authorizedAlways: .always
        @unknown default: .denied
        }
    }

    static func accuracy(from raw: CLAccuracyAuthorization) -> Accuracy {
        raw == .reducedAccuracy ? .reduced : .full
    }
}
