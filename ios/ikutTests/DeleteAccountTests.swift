import AuthenticationServices
import FirebaseAuth
import FirebaseFunctions
import Foundation
import Testing

@testable import ikut

/// Account deletion (A4): the order of the steps, what a cancelled sheet or a failed step leaves, the trip ids sent.
@MainActor
struct DeleteAccountTests {
    private final class Log { var events: [String] = []; var sentIds: [String] = [] }

    private struct Boom: Error {}

    private func proof(code: String? = "code-1") -> DeleteAccount.Proof {
        DeleteAccount.Proof(identity: AppleIdentity(idToken: "t", fullName: nil, authorizationCode: code), rawNonce: "n")
    }

    private func steps(_ log: Log, apple: @escaping () async throws -> DeleteAccount.Proof = { DeleteAccountTests.fixed() },
                       reauth: @escaping () async throws -> Void = {}, revoke: @escaping () async throws -> Void = {},
                       server: @escaping () async throws -> Void = {}) -> DeleteAccount.Steps {
        DeleteAccount.Steps(
            stopWork: { log.events.append("stop") },
            askApple: { log.events.append("apple"); return try await apple() },
            reauthenticate: { _ in log.events.append("reauth"); try await reauth() },
            revoke: { code in log.events.append("revoke:\(code)"); try await revoke() },
            callServer: { ids in log.events.append("server"); log.sentIds = ids; try await server() },
            clearLocal: { log.events.append("clear") },
            signOut: { log.events.append("signOut") })
    }

    private static func fixed() -> DeleteAccount.Proof {
        DeleteAccount.Proof(identity: AppleIdentity(idToken: "t", fullName: nil, authorizationCode: "code-1"), rawNonce: "n")
    }

    private func cancelled() -> Error {
        NSError(domain: ASAuthorizationError.errorDomain, code: ASAuthorizationError.canceled.rawValue)
    }

    @Test func stepsRunInOrderAndTheServerComesAfterTheRevoke() async {
        let log = Log()
        let outcome = await DeleteAccount.run(tripIds: ["a", "b"], steps: steps(log))
        #expect(outcome == .deleted)
        #expect(log.events == ["apple", "stop", "reauth", "revoke:code-1", "server", "clear", "signOut"])
        #expect(log.sentIds == ["a", "b"])
    }

    @Test func aClosedSheetChangesNothing() async {
        let log = Log()
        let outcome = await DeleteAccount.run(tripIds: ["a"], steps: steps(log, apple: { throw cancelled() }))
        #expect(outcome == .cancelled)
        #expect(log.events == ["apple"])
    }

    @Test func aSheetThatFailsOtherwiseShowsALineAndChangesNothing() async {
        let log = Log()
        let outcome = await DeleteAccount.run(tripIds: [], steps: steps(log, apple: { throw Boom() }))
        #expect(outcome == .failed(DeleteAccount.tryAgainLine))
        #expect(log.events == ["apple"])
    }

    @Test func noAuthorizationCodeStopsBeforeAnythingHappens() async {
        let log = Log()
        let p = proof(code: nil)
        let outcome = await DeleteAccount.run(tripIds: [], steps: steps(log, apple: { p }))
        #expect(outcome == .failed(DeleteAccount.noCodeLine))
        #expect(log.events == ["apple"])
    }

    @Test func eachFailedStepLeavesThePersonSignedInWithNothingCleared() async {
        let cases: [(String, DeleteAccount.Steps)] = {
            let a = Log(), b = Log(), c = Log()
            return [("reauth", steps(a, reauth: { throw Boom() })), ("revoke", steps(b, revoke: { throw Boom() })),
                    ("server", steps(c, server: { throw Boom() }))]
        }()
        for (name, s) in cases {
            let outcome = await DeleteAccount.run(tripIds: [], steps: s)
            #expect(outcome == .failed(DeleteAccount.tryAgainLine), "\(name)")
        }
    }

    @Test func aFailedRevokeNeverReachesTheServerOrClearsThePhone() async {
        let log = Log()
        _ = await DeleteAccount.run(tripIds: [], steps: steps(log, revoke: { throw Boom() }))
        #expect(log.events == ["apple", "stop", "reauth", "revoke:code-1"])
    }

    @Test func aFailedServerCallKeepsThePhoneAndARetryRunsEveryStepAgain() async {
        let log = Log()
        var failing = true
        let s = steps(log, server: { if failing { throw Boom() } })
        #expect(await DeleteAccount.run(tripIds: ["a"], steps: s) == .failed(DeleteAccount.tryAgainLine))
        #expect(!log.events.contains("clear") && !log.events.contains("signOut"))
        failing = false
        log.events = []
        #expect(await DeleteAccount.run(tripIds: ["a"], steps: s) == .deleted)
        #expect(log.events == ["apple", "stop", "reauth", "revoke:code-1", "server", "clear", "signOut"])
    }

    @Test func anAccountAlreadyGoneFinishesTheCleanUp() async {
        let gone = NSError(domain: AuthErrorDomain, code: AuthErrorCode.userNotFound.rawValue)
        let log = Log()
        let outcome = await DeleteAccount.run(tripIds: [], steps: steps(log, reauth: { throw gone }))
        #expect(outcome == .deleted)
        #expect(log.events == ["apple", "stop", "reauth", "clear", "signOut"])
    }

    @Test func trackingIsStoppedBeforeAnyNetworkStep() async {
        let log = Log()
        _ = await DeleteAccount.run(tripIds: [], steps: steps(log))
        let stop = log.events.firstIndex(of: "stop")!
        #expect(stop < log.events.firstIndex(of: "reauth")! && stop < log.events.firstIndex(of: "server")!)
    }

    @Test func tripIdsAreDedupedCappedAndWithoutBlanks() {
        #expect(DeleteAccount.tripIds(["a", "", "b", "a", "c", "b"]) == ["a", "b", "c"])
        let many = (0..<500).map { "t\($0)" } + ["t0"]
        let capped = DeleteAccount.tripIds(many)
        #expect(capped.count == 200 && capped.first == "t0" && capped.last == "t199")
    }

    @Test func failuresGetPlainWords() {
        #expect(DeleteAccount.line(for: NSError(domain: NSURLErrorDomain, code: -1009)) == DeleteAccount.offlineLine)
        #expect(DeleteAccount.line(for: NSError(domain: FunctionsErrorDomain, code: FunctionsErrorCode.unavailable.rawValue)) == DeleteAccount.offlineLine)
        #expect(DeleteAccount.line(for: NSError(domain: FunctionsErrorDomain, code: FunctionsErrorCode.internal.rawValue)) == DeleteAccount.tryAgainLine)
        #expect(DeleteAccount.line(for: NSError(domain: AuthErrorDomain, code: AuthErrorCode.userMismatch.rawValue)) == DeleteAccount.otherAppleIDLine)
    }

    // MARK: The organiser id guard

    @Test func anEmptyOrDeletedOrganiserHasNoPathAndNoName() async {
        #expect(!FirestorePaths.isRealUserId(""))
        #expect(!FirestorePaths.isRealUserId("deleted"))
        #expect(!FirestorePaths.isRealUserId(nil))
        #expect(FirestorePaths.isRealUserId("u1"))
        #expect(await StopLeaveService.organizerName(tripId: "t1", organizerId: "") == nil)
        #expect(await StopLeaveService.organizerName(tripId: "t1", organizerId: "deleted") == nil)
        #expect(await LiveAlertNameSource().displayName(tripId: "t1", userId: "") == nil)
        #expect(await LiveAlertNameSource().displayName(tripId: "", userId: "u1") == nil)
    }
}
