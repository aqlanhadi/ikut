import AuthenticationServices
import FirebaseAuth
import FirebaseFunctions
import Foundation
import UIKit

/// Account deletion (A4): Apple's sheet proves it is them, Firebase reauthenticates, Apple's token is revoked, the
/// `deleteAccount` function removes everything on the server (and the sign-in last), then this phone is cleared and
/// signed out. The steps come in as closures so a test can feed them (`DeleteAccount.Steps`).
///
/// Order matters: Apple's token is revoked BEFORE the server call, because revoking needs the signed-in Firebase user
/// (`Auth.revokeToken` reads the current user's ID token) and the server call deletes that user. Every step is safe to
/// repeat: the server finishes a half-done deletion, and a second Apple sheet gives a fresh code to revoke with.
enum DeleteAccount {
    enum Outcome: Equatable {
        /// Everything is gone, this phone is cleared and signed out.
        case deleted
        /// The person closed Apple's sheet. Nothing was changed.
        case cancelled
        /// A step didn't go through; the person is still signed in and can try again. The words are plain.
        case failed(String)
    }

    /// What the sheet handed back, with the nonce it was asked with.
    struct Proof {
        var identity: AppleIdentity
        var rawNonce: String
    }

    struct Steps {
        /// Stops location tracking, convoy listeners and the Live Activity, so no write races the deletion.
        var stopWork: @MainActor () -> Void
        /// Shows Apple's sheet; throws what the sheet throws (a closed sheet is `AppleSignIn.isCancelled`).
        var askApple: @MainActor () async throws -> Proof
        var reauthenticate: @MainActor (Proof) async throws -> Void
        var revoke: @MainActor (String) async throws -> Void
        var callServer: @MainActor ([String]) async throws -> Void
        /// This phone's trips, recaps, routes and towns.
        var clearLocal: @MainActor () -> Void
        var signOut: @MainActor () -> Void
    }

    static let maxTripIds = 200
    static let serverTimeout: TimeInterval = 300

    static let tryAgainLine = "Couldn’t delete your account just now. Check your signal and try again."
    static let offlineLine = "Can’t reach the server. Check your signal and try again."
    static let otherAppleIDLine = "That isn’t the Apple ID you signed in with. Try again with the same one."
    static let noCodeLine = "Apple didn’t confirm it was you. Try again."

    /// The trips this phone knows, for the server's hint: no blanks, no repeats, at most `maxTripIds`.
    static func tripIds(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for id in ids where !id.isEmpty && seen.insert(id).inserted {
            out.append(id)
            if out.count == maxTripIds { break }
        }
        return out
    }

    @MainActor
    static func run(tripIds ids: [String], steps: Steps) async -> Outcome {
        let proof: Proof
        do {
            proof = try await steps.askApple()
        } catch {
            return AppleSignIn.isCancelled(error) ? .cancelled : .failed(line(for: error))
        }
        guard let code = proof.identity.authorizationCode, !code.isEmpty else { return .failed(noCodeLine) }
        steps.stopWork()
        var alreadyGone = false
        do {
            try await steps.reauthenticate(proof)
        } catch let error as NSError where AuthModel.isMissingUser(error) {
            // A deletion that finished but whose answer was lost: nothing is left to delete or revoke.
            alreadyGone = true
        } catch {
            return .failed(line(for: error))
        }
        if !alreadyGone {
            do {
                try await steps.revoke(code)
                try await steps.callServer(tripIds(ids))
            } catch let error as NSError where AuthModel.isMissingUser(error) {
                // Same: the account went away between the steps.
            } catch {
                return .failed(line(for: error))
            }
        }
        steps.clearLocal()
        steps.signOut()
        return .deleted
    }

    static func line(for error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return offlineLine }
        if ns.domain == FunctionsErrorDomain {
            switch FunctionsErrorCode(rawValue: ns.code) {
            case .unavailable, .deadlineExceeded: return offlineLine
            default: return tryAgainLine
            }
        }
        if ns.domain == AuthErrorDomain, let code = AuthErrorCode(rawValue: ns.code) {
            switch code {
            case .userMismatch: return otherAppleIDLine
            case .networkError: return offlineLine
            default: return tryAgainLine
            }
        }
        return tryAgainLine
    }

    /// The real steps. `stopWork` is the caller's (it knows the open trip).
    @MainActor
    static func liveSteps(stopWork: @escaping @MainActor () -> Void) -> Steps {
        Steps(
            stopWork: stopWork,
            askApple: { try await AppleSheet.ask() },
            reauthenticate: { proof in
                guard let user = Auth.auth().currentUser else { throw NSError(domain: AuthErrorDomain, code: AuthErrorCode.userNotFound.rawValue) }
                let credential = OAuthProvider.appleCredential(withIDToken: proof.identity.idToken, rawNonce: proof.rawNonce,
                                                               fullName: nil)
                _ = try await user.reauthenticate(with: credential)
            },
            revoke: { code in try await Auth.auth().revokeToken(withAuthorizationCode: code) },
            callServer: { ids in
                let callable = Backend.functions.httpsCallable("deleteAccount")
                callable.timeoutInterval = serverTimeout
                _ = try await callable.call(["tripIds": ids])
            },
            clearLocal: {
                HistoryDelete.removeAllLocal()
                JoinTowns.forgetAll()
            },
            signOut: { try? Auth.auth().signOut() })
    }
}

/// Apple's sheet shown from code (the button isn't a SwiftUI one here), with a fresh nonce, asking for no name.
@MainActor
final class AppleSheet: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<DeleteAccount.Proof, Error>?
    private var rawNonce = ""
    private var controller: ASAuthorizationController?

    static func ask() async throws -> DeleteAccount.Proof {
        let sheet = AppleSheet()
        return try await sheet.present()
    }

    private func present() async throws -> DeleteAccount.Proof {
        rawNonce = AppleSignIn.randomNonce()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = []
        request.nonce = AppleSignIn.sha256(rawNonce)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        do {
            let identity = try AppleSignIn.identity(from: authorization)
            finish(.success(DeleteAccount.Proof(identity: identity, rawNonce: rawNonce)))
        } catch {
            finish(.failure(error))
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<DeleteAccount.Proof, Error>) {
        continuation?.resume(with: result)
        continuation = nil
        controller = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

extension AuthModel {
    /// Settings' Delete account. `stopWork` ends tracking, listeners and the Live Activity first. On `.deleted` the
    /// state listener moves `state` to `.signedOut`, which shows the signed-out Home.
    func deleteAccount(stopWork: @escaping @MainActor () -> Void) async -> DeleteAccount.Outcome {
        await DeleteAccount.run(tripIds: PastTrips.all().map(\.id), steps: DeleteAccount.liveSteps(stopWork: stopWork))
    }
}
