import FirebaseAppCheck
import FirebaseCore
import Foundation

#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// Which App Check provider the app uses, decided once at launch.
enum AppCheckProviderChoice: Equatable {
    /// The local emulators don't check tokens, so the app sends none.
    case none
    /// Debug token, registered by hand in the Firebase console. Simulator, Debug builds, unsupported devices.
    case debug
    /// Apple App Attest: a Release build on a real device.
    case appAttest

    static func choose(usesEmulators: Bool, isDebugBuild: Bool, appAttestSupported: Bool) -> AppCheckProviderChoice {
        if usesEmulators { return .none }
        if isDebugBuild || !appAttestSupported { return .debug }
        return .appAttest
    }

    /// The choice for this build on this device.
    static var current: AppCheckProviderChoice {
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        let usesEmulators: Bool
        if case .emulators = Backend.current { usesEmulators = true } else { usesEmulators = false }
        #if canImport(DeviceCheck)
        // Also needs the entitlement signed in (project.yml, IKUT_APPATTEST), which the free team can't do.
        let signedIn = (Bundle.main.object(forInfoDictionaryKey: "IKUTAppAttest") as? String) == "YES"
        let supported = signedIn && DCAppAttestService.shared.isSupported
        #else
        let supported = false
        #endif
        return choose(usesEmulators: usesEmulators, isDebugBuild: isDebug, appAttestSupported: supported)
    }

    /// Call before `FirebaseApp.configure()`.
    func install() {
        switch self {
        case .none: break
        case .debug: AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        case .appAttest: AppCheck.setAppCheckProviderFactory(AppAttestProviderFactory())
        }
    }
}

private final class AppAttestProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> (any AppCheckProvider)? {
        AppAttestProvider(app: app)
    }
}
