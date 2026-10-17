import FirebaseAuth
import Foundation
import Testing
@testable import ikut

/// Runs against the local Auth emulator. Start it first, then:
/// `TEST_RUNNER_IKUT_EMULATOR_TESTS=1 xcodebuild test ...`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["IKUT_EMULATOR_TESTS"] == "1"), .serialized)
@MainActor
struct AuthEmulatorTests {
    init() throws {
        Backend.configure()
        try Auth.auth().signOut()
    }

    @Test func guestSignInSetsDisplayName() async throws {
        let model = AuthModel()
        try await model.signInAsGuest(name: "  Siti   Nur ")

        let user = try #require(Auth.auth().currentUser)
        #expect(user.isAnonymous)
        #expect(user.displayName == "Siti Nur")
        #expect(model.state == .signedIn)
        #expect(model.userID == user.uid)
    }

    @Test func renameKeepsTheSameUser() async throws {
        let model = AuthModel()
        try await model.signInAsGuest(name: "Hafiz")
        let uid = try #require(Auth.auth().currentUser?.uid)

        try await model.updateDisplayName("Hafiz (Hilux)")

        #expect(Auth.auth().currentUser?.uid == uid)
        #expect(model.displayName == "Hafiz (Hilux)")
    }

    @Test func invalidNameDoesNotSignIn() async throws {
        let model = AuthModel()
        await #expect(throws: DisplayName.ValidationError.empty) {
            try await model.signInAsGuest(name: "   ")
        }
        #expect(Auth.auth().currentUser == nil)
    }
}
