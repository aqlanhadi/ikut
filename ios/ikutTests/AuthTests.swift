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
