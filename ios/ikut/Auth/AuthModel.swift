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
