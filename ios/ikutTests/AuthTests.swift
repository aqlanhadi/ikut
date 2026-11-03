import AuthenticationServices
import FirebaseAuth
import Foundation
import Testing
@testable import ikut

struct DisplayNameTests {
    private func name(_ raw: String) -> String? {
        if case .success(let value) = DisplayName.validate(raw) { value } else { nil }
    }

    @Test func trimsSurroundingWhitespace() {
        #expect(name("  Aqlan \n") == "Aqlan")
    }

    @Test func collapsesInternalWhitespace() {
        #expect(name("Siti   Nur\t\nAisyah") == "Siti Nur Aisyah")
    }

    @Test(arguments: ["", "   ", "\n\t "])
    func rejectsEmpty(raw: String) {
        #expect(DisplayName.validate(raw) == .failure(.empty))
    }

    @Test func acceptsExactlyThirty() {
        let thirty = String(repeating: "a", count: 30)
        #expect(name(thirty) == thirty)
    }

    @Test func rejectsThirtyOne() {
        let long = String(repeating: "a", count: 31)
        #expect(DisplayName.validate(long) == .failure(.tooLong(max: 30)))
    }

    @Test func lengthIsCountedAfterCollapsing() {
        let padded = "  " + String(repeating: "a", count: 30) + "   "
        #expect(name(padded) != nil)
    }

    @Test func keepsUnicodeAndApostrophes() {
        #expect(name("Siti Nur 'Aisyah") == "Siti Nur 'Aisyah")
        #expect(name("Zoë Müller") == "Zoë Müller")
    }

    @Test func emojiCountAsOneCharacter() {
        let thirtyEmoji = String(repeating: "🚗", count: 30)
        #expect(name(thirtyEmoji) == thirtyEmoji)
        #expect(name("👨‍👩‍👧 family") == "👨‍👩‍👧 family")
        #expect(DisplayName.validate(String(repeating: "🚗", count: 31)) == .failure(.tooLong(max: 30)))
    }

    @Test func errorsHaveUserFacingMessages() {
        #expect(DisplayName.ValidationError.empty.errorDescription?.isEmpty == false)
        #expect(DisplayName.ValidationError.tooLong(max: 30).errorDescription?.contains("30") == true)
    }
}

struct MissingUserCheckTests {
    private func run(throwing error: NSError?) async -> (dropped: Bool, signedOut: Bool) {
        nonisolated(unsafe) var signedOut = false
        let dropped = await AuthModel.dropIfMissing(
            reload: { if let error { throw error } },
            signOut: { signedOut = true })
        return (dropped, signedOut)
    }

    @Test func aKnownUserStays() async {
        let result = await run(throwing: nil)
        #expect(!result.dropped && !result.signedOut)
    }

    @Test func aNetworkErrorKeepsTheUser() async {
        let offline = NSError(domain: AuthErrorDomain, code: AuthErrorCode.networkError.rawValue)
        let timedOut = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        for error in [offline, timedOut] {
            let result = await run(throwing: error)
            #expect(!result.dropped && !result.signedOut)
        }
    }

    @Test func anInternalErrorNeedsTheServersWordForUserGone() async {
        let gone = NSError(domain: AuthErrorDomain, code: AuthErrorCode.internalError.rawValue,
                           userInfo: [NSUnderlyingErrorKey: NSError(domain: "x", code: 1, userInfo: [
                               "FIRAuthErrorUserInfoDeserializedResponseKey": ["message": "INVALID_REFRESH_TOKEN"]])])
        let other = NSError(domain: AuthErrorDomain, code: AuthErrorCode.internalError.rawValue, userInfo: [
            "FIRAuthErrorUserInfoDeserializedResponseKey": ["message": "USER_NOT_FOUND"]])
        #expect(await run(throwing: gone).signedOut)
        #expect(!(await run(throwing: other).signedOut))
    }

    @Test(arguments: [AuthErrorCode.userNotFound, .userTokenExpired, .invalidUserToken, .userDisabled])
    func aUserTheServerLostIsSignedOut(code: AuthErrorCode) async {
        let result = await run(throwing: NSError(domain: AuthErrorDomain, code: code.rawValue))
        #expect(result.dropped && result.signedOut)
    }
}

@MainActor
struct AppleSignInTests {
    private struct Down: Error {}
    private let cancelled = NSError(domain: ASAuthorizationError.errorDomain, code: ASAuthorizationError.canceled.rawValue)

    private func name(_ given: String?, _ family: String?) -> String? {
        var parts = PersonNameComponents()
        parts.givenName = given
        parts.familyName = family
        return AppleSignIn.displayName(from: parts)
    }

    @Test func sha256OfAKnownInput() {
        #expect(AppleSignIn.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(AppleSignIn.sha256("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func nonceIsRandomUrlSafeAndTheRequestedLength() {
        let first = AppleSignIn.randomNonce()
        let second = AppleSignIn.randomNonce()
        #expect(first.count == 32 && first != second)
        #expect(AppleSignIn.randomNonce(length: 64).count == 64)
        let allowed = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        #expect(first.allSatisfy(allowed.contains))
    }

    @Test func fullNameBecomesGivenThenFamily() {
        #expect(name("Aqlan", "Azman") == "Aqlan Azman")
        #expect(name("Aqlan", nil) == "Aqlan")
        #expect(name(nil, "Azman") == "Azman")
        #expect(name("  Siti ", " Nur ") == "Siti Nur")
    }

    @Test func missingOrEmptyNameGivesNil() {
        #expect(AppleSignIn.displayName(from: nil) == nil)
        #expect(name(nil, nil) == nil)
        #expect(name("", "  ") == nil)
    }

    @Test func aTooLongNameIsCutToTheLimit() {
        let cut = name(String(repeating: "a", count: 40), nil)
        #expect(cut?.count == DisplayName.maxLength)
    }

    @Test func aCancelledSheetIsNotAnError() async throws {
        nonisolated(unsafe) var signedIn = false
        let outcome = try await AppleSignIn.complete(.failure(cancelled), rawNonce: "n",
                                                     signIn: { _, _ in signedIn = true; return nil }, saveName: { _ in })
        #expect(outcome == .cancelled && !signedIn)
        #expect(AppleSignIn.isCancelled(cancelled))
        #expect(!AppleSignIn.isCancelled(NSError(domain: ASAuthorizationError.errorDomain,
                                                 code: ASAuthorizationError.failed.rawValue)))
    }

    @Test func anotherSheetErrorIsThrown() async {
        await #expect(throws: Down.self) {
            _ = try await AppleSignIn.complete(.failure(Down()), rawNonce: "n", signIn: { _, _ in nil }, saveName: { _ in })
        }
    }

    @Test func theFirstSignInSavesApplesNameAndPassesTheRawNonce() async throws {
        var parts = PersonNameComponents()
        parts.givenName = "Nurul"
        parts.familyName = "Aina"
        nonisolated(unsafe) var saved: String?
        nonisolated(unsafe) var nonce: String?
        let outcome = try await AppleSignIn.complete(.success(AppleIdentity(idToken: "t", fullName: parts)), rawNonce: "raw",
                                                     signIn: { _, n in nonce = n; return nil }, saveName: { saved = $0 })
        #expect(outcome == .signedIn(name: "Nurul Aina") && saved == "Nurul Aina" && nonce == "raw")
    }

    @Test func aReturningUserWithANameKeepsIt() async throws {
        nonisolated(unsafe) var saved: String?
        let outcome = try await AppleSignIn.complete(.success(AppleIdentity(idToken: "t", fullName: nil)), rawNonce: "n",
                                                     signIn: { _, _ in "Nurul" }, saveName: { saved = $0 })
        #expect(outcome == .signedIn(name: "Nurul") && saved == nil)
    }

    @Test func aReturningUserWithoutANameLandsOnTheNameStep() async throws {
        let outcome = try await AppleSignIn.complete(.success(AppleIdentity(idToken: "t", fullName: nil)), rawNonce: "n",
                                                     signIn: { _, _ in "" }, saveName: { _ in })
        #expect(outcome == .needsName)
        // A signed-in user with no name is `.signedOut` for the app, which shows the name step.
        #expect(AuthModel.state(uid: "apple-user", name: "") == .signedOut)
        #expect(AuthModel.state(uid: "apple-user", name: nil) == .signedOut)
        #expect(AuthModel.state(uid: "apple-user", name: "Nurul") == .signedIn)
    }

    @Test func anOverLongAppleNameIsCutAndSavedCut() async throws {
        var parts = PersonNameComponents()
        parts.givenName = String(repeating: "a", count: 25)
        parts.familyName = String(repeating: "b", count: 25)
        nonisolated(unsafe) var saved: String?
        let outcome = try await AppleSignIn.complete(.success(AppleIdentity(idToken: "t", fullName: parts)), rawNonce: "n",
                                                     signIn: { _, _ in nil }, saveName: { saved = $0 })
        #expect(saved?.count == DisplayName.maxLength)
        #expect(outcome == .signedIn(name: saved ?? "?"))
    }

    @Test func aProfileNameThatNeedsCleaningIsSavedCleaned() async throws {
        nonisolated(unsafe) var saved: String?
        let outcome = try await AppleSignIn.complete(.success(AppleIdentity(idToken: "t", fullName: nil)), rawNonce: "n",
                                                     signIn: { _, _ in "  Nurul   Aina " }, saveName: { saved = $0 })
        #expect(saved == "Nurul Aina" && outcome == .signedIn(name: "Nurul Aina"))
    }

    @Test func providerDecidesTheSignInMethod() {
        #expect(SignInMethod.of(providerIDs: ["apple.com"]) == .apple)
        #expect(SignInMethod.of(providerIDs: []) == .guest)
    }

    @Test func signOutForgetsTheTownsAndASignOutThatThrowsKeepsThem() {
        nonisolated(unsafe) var events: [String] = []
        AuthModel.performSignOut(signOut: { events.append("out") }, forget: { events.append("forget") })
        #expect(events == ["out", "forget"])
        events = []
        AuthModel.performSignOut(signOut: { throw Down() }, forget: { events.append("forget") })
        #expect(events.isEmpty)
        #expect(AuthModel.state(uid: nil, name: "Nurul") == .signedOut)
    }
}
