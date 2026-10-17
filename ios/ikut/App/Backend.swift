import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation

/// Which Firebase backend the app talks to.
///
/// Debug builds use the local emulators (`firebase emulators:start` in firebase/)
/// unless launched with `IKUT_USE_PRODUCTION=1`. Release builds always use production.
/// On a real device, build with `IKUT_EMULATOR_HOST=<Mac's LAN address>` (baked into
/// Info.plist) or set the same environment variable in the scheme.
enum Backend {
    case emulators(host: String)
    case production

    static var current: Backend {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["IKUT_USE_PRODUCTION"] == "1" { return .production }
        let built = Bundle.main.object(forInfoDictionaryKey: "IKUTEmulatorHost") as? String
        let host = env["IKUT_EMULATOR_HOST"] ?? built.flatMap { $0.isEmpty ? nil : $0 } ?? "127.0.0.1"
        return .emulators(host: host)
        #else
        return .production
        #endif
    }

    /// Call at launch, before any other Firebase use. Safe to call again (e.g. from previews).
    static func configure() {
        guard FirebaseApp.app() == nil else { return }
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
