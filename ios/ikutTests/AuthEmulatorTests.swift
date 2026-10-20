import FirebaseAuth
import Foundation
import Testing
@testable import ikut

/// Runs against the local Auth emulator. Start it first, then:
/// `TEST_RUNNER_IKUT_EMULATOR_TESTS=1 xcodebuild test ...`
@Suite(.emulator, .serialized)
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

    /// A saved user the emulator no longer has (it was restarted) is signed out at launch,
    /// instead of leaving every Firestore write to fail.
    @Test func launchSignsOutAUserTheBackendLost() async throws {
        try await AuthModel().signInAsGuest(name: "Ghost")
        let uid = try #require(Auth.auth().currentUser?.uid)

        guard case .emulators(let host) = Backend.current else { return }
        let url = URL(string: "http://\(host):9099/identitytoolkit.googleapis.com/v1/projects/ikut-b1083/accounts:delete")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["localId": uid])
        _ = try await URLSession.shared.data(for: request)

        let model = AuthModel()
        await waitUntil(.seconds(5)) { Auth.auth().currentUser == nil }
        #expect(Auth.auth().currentUser == nil)
        #expect(model.state == .signedOut)
    }

    @Test func invalidNameDoesNotSignIn() async throws {
        let model = AuthModel()
        await #expect(throws: DisplayName.ValidationError.empty) {
            try await model.signInAsGuest(name: "   ")
        }
        #expect(Auth.auth().currentUser == nil)
    }
}
