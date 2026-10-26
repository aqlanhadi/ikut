import FirebaseAuth
import Foundation
import Observation

/// Tracks the Firebase user and signs joiners in anonymously with just a name.
///
/// The anonymous user stays the identity (it is later linked to Sign in with Apple);
/// the name lives on the Auth profile.
@Observable @MainActor
final class AuthModel {
    enum State: Equatable {
        case loading
        case signedOut
        case signedIn
    }

    private(set) var state: State = .loading
    private(set) var userID: String?
    private(set) var displayName: String?

    // Only written in init and read in deinit; the handle isn't Sendable, so it
    // can't be touched from a nonisolated deinit otherwise.
    @ObservationIgnored
    nonisolated(unsafe) private var listener: AuthStateDidChangeListenerHandle?

    init() {
        listener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            let uid = user?.uid
            let name = user?.displayName
            Task { @MainActor in self?.apply(uid: uid, name: name) }
        }
        Task { await Self.dropMissingUser() }
        // A write that hits its deadline may be waiting on a token the server won't give a deleted user.
        ServerWrite.onTimeout = { await Self.dropMissingUser() }
    }

    /// Signs out a saved user the backend no longer has (the emulators were restarted, or the
    /// account was deleted). Auth keeps the user in the Keychain, and Firestore then waits on an ID
    /// token that can never refresh, so no request leaves the phone and every write just times out.
    /// Run at launch and when a write times out. Returns true when it signed the user out.
    @discardableResult
    static func dropMissingUser() async -> Bool {
        guard let current = Auth.auth().currentUser else { return false }
        nonisolated(unsafe) let user = current
        return await dropIfMissing(reload: { try await user.reload() }, signOut: {
            try? Auth.auth().signOut()
            JoinTowns.forgetAll()
        })
    }

    /// The decision on its own, so a test can feed it errors: only "user gone" errors sign out;
    /// a network error or timeout keeps the user.
    static func dropIfMissing(reload: () async throws -> Void, signOut: () -> Void) async -> Bool {
        do {
            try await reload()
            return false
        } catch let error as NSError where isMissingUser(error) {
            signOut()
            return true
        } catch {
            return false
        }
    }

    /// The server's message the SDK keeps in userInfo when it has no code of its own for it.
    private nonisolated static let deserializedResponseKey = "FIRAuthErrorUserInfoDeserializedResponseKey"

    nonisolated static func isMissingUser(_ error: NSError) -> Bool {
        guard error.domain == AuthErrorDomain, let code = AuthErrorCode(rawValue: error.code) else { return false }
        if code == .internalError {
            // A token refresh for a deleted user: `.internalError` carrying INVALID_REFRESH_TOKEN (the other
            // gone cases arrive as their own codes, below). The message sits in the error or its underlying one.
            return serverMessage(error) == "INVALID_REFRESH_TOKEN"
        }
        return [AuthErrorCode.userNotFound, .userDisabled, .userTokenExpired, .invalidUserToken].contains(code)
    }

    private nonisolated static func serverMessage(_ error: NSError) -> String? {
        if let response = error.userInfo[deserializedResponseKey] as? [String: Any],
           let message = response["message"] as? String { return message }
        if let inner = error.userInfo[NSUnderlyingErrorKey] as? NSError { return serverMessage(inner) }
        return nil
    }

    deinit {
        if let listener { Auth.auth().removeStateDidChangeListener(listener) }
    }

    func signInAsGuest(name: String) async throws {
        let cleaned = try DisplayName.validate(name).get()
        if Auth.auth().currentUser == nil {
            try await Auth.auth().signInAnonymously()
        }
        try await setName(cleaned)
    }

    func updateDisplayName(_ name: String) async throws {
        let cleaned = try DisplayName.validate(name).get()
        try await setName(cleaned)
    }

    private func setName(_ name: String) async throws {
        guard let user = Auth.auth().currentUser else { return }
        let change = user.createProfileChangeRequest()
        change.displayName = name
        try await change.commitChanges()
        try await user.reload()
        apply(uid: user.uid, name: user.displayName)
    }

    private func apply(uid: String?, name: String?) {
        userID = uid
        displayName = name
        // An anonymous user without a name yet (interrupted sign-in) still needs the name screen.
        state = (uid != nil && name?.isEmpty == false) ? .signedIn : .signedOut
    }
}
