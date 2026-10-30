import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
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

    /// Region the Cloud Functions are deployed to (see firebase/functions/src/index.ts).
    static let functionsRegion = "asia-southeast1"

    /// Use this instead of `Functions.functions()` so calls reach the right region.
    static var functions: Functions { Functions.functions(region: functionsRegion) }

    /// Call at launch, before any other Firebase use. Safe to call again (e.g. from previews).
    static func configure() {
        guard FirebaseApp.app() == nil else { return }
        AppCheckProviderChoice.current.install()
        FirebaseApp.configure()
        defer { dropUserFromOtherBackend() }

        guard case .emulators(let host) = current else { return }
        Auth.auth().useEmulator(withHost: host, port: 9099)
        functions.useEmulator(withHost: host, port: 5001)

        let settings = Firestore.firestore().settings
        settings.host = "\(host):8080"
        settings.isSSLEnabled = false
        // Keep emulator data out of the on-device cache so restarts start clean.
        settings.cacheSettings = MemoryCacheSettings()
        Firestore.firestore().settings = settings
    }

    private static let userBackendKey = "ikut.userBackend"

    /// Signs out a saved user that belongs to a different backend.
    ///
    /// Auth keeps its user in the Keychain, which outlives reinstalls, so a phone that ran a
    /// Debug build against the emulators still holds an emulator user in a Release build.
    /// Production can't refresh that user's token, and every Firestore write then retries
    /// forever. UserDefaults is wiped on reinstall, so a missing value also counts as a mismatch.
    private static func dropUserFromOtherBackend() {
        let kind = if case .production = current { "production" } else { "emulators" }
        let defaults = UserDefaults.standard
        if defaults.string(forKey: userBackendKey) != kind, Auth.auth().currentUser != nil {
            try? Auth.auth().signOut()
            Task { @MainActor in JoinTowns.forgetAll() }
        }
        defaults.set(kind, forKey: userBackendKey)
    }

    var label: String {
        switch self {
        case .emulators(let host): "Emulators · \(host)"
        case .production: "Production"
        }
    }
}
