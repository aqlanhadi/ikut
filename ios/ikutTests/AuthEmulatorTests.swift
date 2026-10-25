import FirebaseAuth
import FirebaseFirestore
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

    /// The phone is running when the server loses its user: the first write that times out signs it out,
    /// instead of leaving it on "no connection" for good.
    @Test func aWriteTimeoutSignsOutAUserTheBackendLost() async throws {
        let model = AuthModel()
        try await model.signInAsGuest(name: "Ghost")
        let uid = try #require(Auth.auth().currentUser?.uid)
        #expect(model.state == .signedIn)

        guard case .emulators(let host) = Backend.current else { return }
        let url = URL(string: "http://\(host):9099/identitytoolkit.googleapis.com/v1/projects/ikut-b1083/accounts:delete")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["localId": uid])
        _ = try await URLSession.shared.data(for: request)

        let ref = Firestore.firestore().collection("trips").document()
        // The emulator turns the write away (the old token is still valid, but the user has no membership);
        // a real hang needs an expired token. Either way the check runs and the user goes.
        _ = try? await ServerWrite.commit(within: .seconds(3)) { try await ref.setData(["name": "x"]) }
        await waitUntil(.seconds(5)) { Auth.auth().currentUser == nil }
        #expect(Auth.auth().currentUser == nil)
        #expect(model.state == .signedOut)
    }

    /// The token refresh Firestore waits on fails with an error AuthModel reads as "user gone".
    @Test func aDeletedUsersTokenRefreshReadsAsGone() async throws {
        try await AuthModel().signInAsGuest(name: "Ghost")
        nonisolated(unsafe) let user = try #require(Auth.auth().currentUser)
        guard case .emulators(let host) = Backend.current else { return }
        let url = URL(string: "http://\(host):9099/identitytoolkit.googleapis.com/v1/projects/ikut-b1083/accounts:delete")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["localId": user.uid])
        _ = try await URLSession.shared.data(for: request)

        do {
            _ = try await user.getIDTokenResult(forcingRefresh: true)
            Issue.record("the refresh should fail for a deleted user")
        } catch {
            print("Q10 refresh error:", error)
            #expect(AuthModel.isMissingUser(error as NSError))
        }
    }

    @Test func invalidNameDoesNotSignIn() async throws {
        let model = AuthModel()
        await #expect(throws: DisplayName.ValidationError.empty) {
            try await model.signInAsGuest(name: "   ")
        }
        #expect(Auth.auth().currentUser == nil)
    }
}
