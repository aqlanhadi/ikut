import Testing
@testable import ikut

struct BackendTests {
    @Test func debugBuildsUseEmulatorsByDefault() {
        guard case .emulators(let host) = Backend.current else {
            Issue.record("Expected the emulator backend in a Debug test run")
            return
        }
        #expect(!host.isEmpty)
    }
}
