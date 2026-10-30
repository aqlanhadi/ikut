import Testing
@testable import ikut

struct AppCheckProviderChoiceTests {
    @Test func emulatorsSendNoToken() {
        for debug in [true, false] {
            for supported in [true, false] {
                #expect(AppCheckProviderChoice.choose(usesEmulators: true, isDebugBuild: debug, appAttestSupported: supported) == .none)
            }
        }
    }

    @Test func debugBuildsUseDebugProviderEvenWhereAppAttestWorks() {
        #expect(AppCheckProviderChoice.choose(usesEmulators: false, isDebugBuild: true, appAttestSupported: true) == .debug)
        #expect(AppCheckProviderChoice.choose(usesEmulators: false, isDebugBuild: true, appAttestSupported: false) == .debug)
    }

    @Test func releaseOnRealDeviceUsesAppAttest() {
        #expect(AppCheckProviderChoice.choose(usesEmulators: false, isDebugBuild: false, appAttestSupported: true) == .appAttest)
    }

    @Test func releaseWhereAppAttestIsUnsupportedFallsBackToDebug() {
        #expect(AppCheckProviderChoice.choose(usesEmulators: false, isDebugBuild: false, appAttestSupported: false) == .debug)
    }
}
