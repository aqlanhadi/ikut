import Foundation

/// User settings for alerts. The keys work with `@AppStorage`.
enum AlertSettings {
    static let readAloudKey = "ikut.alerts.readAloud"
    static let readAloudDefault = true

    /// Current value, honouring the default when the user never touched the setting.
    static func readAloud(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: readAloudKey) as? Bool ?? readAloudDefault
    }
}
