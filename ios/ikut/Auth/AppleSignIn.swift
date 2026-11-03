import AuthenticationServices
import CryptoKit
import Foundation
import Security

/// How the person is signed in: with Apple, or as a guest (an anonymous user that only has a name).
enum SignInMethod: Equatable {
    case apple
    case guest

    static let appleProviderID = "apple.com"

    static func of(providerIDs: [String]) -> SignInMethod {
        providerIDs.contains(appleProviderID) ? .apple : .guest
    }
}

/// What Apple's sheet handed back, with nothing from AuthenticationServices in it, so a test can feed it.
struct AppleIdentity {
    var idToken: String
    var fullName: PersonNameComponents?
    /// The one-time code Apple's sheet returns, which Firebase needs to revoke the Apple token (account deletion).
    var authorizationCode: String? = nil
}

/// Sign in with Apple through Firebase: the nonce, the name Apple sends once, and how a finished sheet turns into a
/// signed-in user. The Firebase calls come in as closures (`AuthModel.signInWithApple`), so the logic is testable.
enum AppleSignIn {
    enum Outcome: Equatable {
        /// Signed in; the Auth profile has this name (cleaned, at most 30 characters).
        case signedIn(name: String)
        /// Signed in, but Apple sent no name and the profile has none: the name step still asks for one.
        case needsName
        /// The person closed Apple's sheet. Not a problem, nothing to show.
        case cancelled
    }

    enum Problem: Error, LocalizedError {
        case noToken
        var errorDescription: String? { Self.line }
        static let line = "Couldn’t sign in with Apple. Try again, or use a name instead."
    }

    // MARK: Nonce

    /// A random string of URL-safe characters. The raw one goes to Firebase, its SHA256 to Apple.
    static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        if status != errSecSuccess { bytes = (0..<length).map { _ in UInt8.random(in: 0...255) } }
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Name

    /// "Given Family" from what Apple sent, or nil when there is nothing usable (Apple only sends it the first time).
    static func displayName(from name: PersonNameComponents?) -> String? {
        guard let name else { return nil }
        return cleanName([name.givenName, name.familyName].compactMap { $0 }.joined(separator: " "))
    }

    /// A name from the profile or from Apple as the convoy shows it: whitespace tidied, cut to the limit; nil when empty.
    static func cleanName(_ raw: String?) -> String? {
        guard let joined = raw else { return nil }
        switch DisplayName.validate(joined) {
        case .success(let value): return value
        case .failure(.empty): return nil
        case .failure(.tooLong(let max)):
            if case .success(let cut) = DisplayName.validate(String(joined.prefix(max))) { return cut }
            return nil
        }
    }

    // MARK: Result

    static func isCancelled(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == ASAuthorizationError.errorDomain && error.code == ASAuthorizationError.canceled.rawValue
    }

    static func identity(from authorization: ASAuthorization) throws -> AppleIdentity {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.identityToken, let token = String(data: data, encoding: .utf8) else {
            throw Problem.noToken
        }
        let code = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        return AppleIdentity(idToken: token, fullName: credential.fullName, authorizationCode: code)
    }

    /// Finishes a sheet result. `signIn` signs in with Firebase (replacing any guest) and returns the profile's name
    /// afterwards; `saveName` writes a name to the profile. A cancelled sheet returns `.cancelled`; other errors throw.
    @MainActor static func complete(_ result: Result<AppleIdentity, Error>, rawNonce: String,
                         signIn: (AppleIdentity, String) async throws -> String?,
                         saveName: (String) async throws -> Void) async throws -> Outcome {
        let identity: AppleIdentity
        switch result {
        case .success(let value): identity = value
        case .failure(let error):
            if isCancelled(error) { return .cancelled }
            throw error
        }
        let existing = try await signIn(identity, rawNonce)
        // The profile's name wins (Apple sends it once); either is cleaned, and saved when that changed it.
        guard let name = cleanName(existing) ?? displayName(from: identity.fullName) else { return .needsName }
        if name != existing { try await saveName(name) }
        return .signedIn(name: name)
    }
}
