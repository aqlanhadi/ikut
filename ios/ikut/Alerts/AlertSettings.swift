import SwiftUI

/// User settings for alerts. The keys work with `@AppStorage`.
enum AlertSettings {
    static let readAloudKey = "ikut.alerts.readAloud"
    static let readAloudDefault = true

    /// Current value, honouring the default when the user never touched the setting.
    static func readAloud(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: readAloudKey) as? Bool ?? readAloudDefault
    }
}

/// "Read alerts aloud" switch for a settings list or form.
struct ReadAlertsAloudToggle: View {
    @AppStorage(AlertSettings.readAloudKey) private var readAloud = AlertSettings.readAloudDefault

    var body: some View {
        Toggle("Read alerts aloud", isOn: $readAloud)
    }
}
