import Testing
@testable import ikut

@MainActor
struct LocationPermissionWaitTests {
    /// Q31: no prompt and no answer must not hold the join sheet's Continue on "Asking" for good.
    @Test
    func undecidedRequestEndsAfterTheLimit() async {
        let permission = LocationPermission(demo: .notDetermined)
        permission.noAnswerLimit = .milliseconds(50)
        await permission.awaitAnswer(until: { $0 != .notDetermined }) {}
        #expect(permission.status == .notDetermined)
    }
}
