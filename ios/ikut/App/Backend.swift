import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation

/// Which Firebase backend the app talks to.
///
/// Debug builds use the local emulators (`firebase emulators:start` in firebase/)
/// unless launched with `IKUT_USE_PRODUCTION=1`. Release builds always use production.
/// On a real device, set `IKUT_EMULATOR_HOST` to the Mac's LAN address in the scheme.
enum Backend {
    case emulators(host: String)
    case production

    static var current: Backend {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["IKUT_USE_PRODUCTION"] == "1" { return .production }
        return .emulators(host: env["IKUT_EMULATOR_HOST"] ?? "127.0.0.1")
        #else
        return .production
        #endif
    }

    /// Call once at launch, before any other Firebase use.
    static func configure() {
        FirebaseApp.configure()

        guard case .emulators(let host) = current else { return }
        Auth.auth().useEmulator(withHost: host, port: 9099)

        let settings = Firestore.firestore().settings
        settings.host = "\(host):8080"
        settings.isSSLEnabled = false
        // Keep emulator data out of the on-device cache so restarts start clean.
        settings.cacheSettings = MemoryCacheSettings()
        Firestore.firestore().settings = settings
    }

    var label: String {
        switch self {
        case .emulators(let host): "Emulators · \(host)"
        case .production: "Production"
        }
    }
}
