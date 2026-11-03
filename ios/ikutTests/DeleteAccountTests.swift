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

    private func authError(_ code: AuthErrorCode) -> NSError { NSError(domain: AuthErrorDomain, code: code.rawValue) }

    private struct Boom: Error {}

    private func proof(code: String? = "code-1") -> DeleteAccount.Proof {
        DeleteAccount.Proof(identity: AppleIdentity(idToken: "t", fullName: nil, authorizationCode: code), rawNonce: "n")
    }

    private func steps(_ log: Log, apple: @escaping () async throws -> DeleteAccount.Proof = { DeleteAccountTests.fixed() },
                       reload: @escaping () async throws -> Void = {}, reauth: @escaping () async throws -> Void = {}, revoke: @escaping () async throws -> Void = {},
                       server: @escaping () async throws -> Void = {}) -> DeleteAccount.Steps {
        DeleteAccount.Steps(
            stopWork: { log.events.append("stop") },
            askApple: { log.events.append("apple"); return try await apple() },
            reload: { log.events.append("reload"); try await reload() },
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
        #expect(log.events == ["reload", "apple", "stop", "reauth", "revoke:code-1", "server", "clear", "signOut"])
        #expect(log.sentIds == ["a", "b"])
    }

    @Test func aClosedSheetChangesNothing() async {
        let log = Log()
        let outcome = await DeleteAccount.run(tripIds: ["a"], steps: steps(log, apple: { throw cancelled() }))
        #expect(outcome == .cancelled)
        #expect(log.events == ["reload", "apple"])
    }

    @Test func aSheetThatFailsOtherwiseShowsALineAndChangesNothing() async {
        let log = Log()
        let outcome = await DeleteAccount.run(tripIds: [], steps: steps(log, apple: { throw Boom() }))
        #expect(outcome == .failed(DeleteAccount.tryAgainLine))
        #expect(log.events == ["reload", "apple"])
    }

    @Test func noAuthorizationCodeStopsBeforeAnythingHappens() async {
        let log = Log()
        let p = proof(code: nil)
        let outcome = await DeleteAccount.run(tripIds: [], steps: steps(log, apple: { p }))
        #expect(outcome == .failed(DeleteAccount.noCodeLine))
        #expect(log.events == ["reload", "apple"])
    }

    @Test func eachFailedStepLeavesThePersonSignedInWithNothingCleared() async {
        let cases: [(String, Log, DeleteAccount.Steps)] = {
            let a = Log(), b = Log(), c = Log()
            return [("reauth", a, steps(a, reauth: { throw Boom() })), ("revoke", b, steps(b, revoke: { throw Boom() })),
                    ("server", c, steps(c, server: { throw Boom() }))]
        }()
        for (name, log, s) in cases {
            let outcome = await DeleteAccount.run(tripIds: [], steps: s)
            #expect(outcome == .failed(DeleteAccount.tryAgainLine), "\(name)")
            #expect(!log.events.contains("clear") && !log.events.contains("signOut"), "\(name)")
        }
    }

    @Test func aFailedRevokeNeverReachesTheServerOrClearsThePhone() async {
        let log = Log()
        _ = await DeleteAccount.run(tripIds: [], steps: steps(log, revoke: { throw Boom() }))
        #expect(log.events == ["reload", "apple", "stop", "reauth", "revoke:code-1"])
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
        #expect(log.events == ["reload", "apple", "stop", "reauth", "revoke:code-1", "server", "clear", "signOut"])
    }

    @Test func anAccountAlreadyGoneFinishesTheCleanUp() async {
        let gone = authError(.userNotFound)
        let log = Log()
        let outcome = await DeleteAccount.run(tripIds: [], steps: steps(log, reauth: { throw gone }))
        #expect(outcome == .deleted)
        #expect(log.events == ["reload", "apple", "stop", "reauth", "clear", "signOut"])
    }

    @Test func aDeletedUserTheSDKCallsAMismatchStillFinishes() async {
        let log = Log()
        var reloads = 0
        let s = steps(log, reload: { reloads += 1; if reloads > 1 { throw authError(.userNotFound) } },
                      reauth: { throw authError(.userMismatch) })
        #expect(await DeleteAccount.run(tripIds: [], steps: s) == .deleted)
        #expect(log.events == ["reload", "apple", "stop", "reauth", "reload", "clear", "signOut"])
    }

    @Test func aRealMismatchStaysAFailureWithTheSignedInUserKept() async {
        let log = Log()
        let s = steps(log, reauth: { throw authError(.userMismatch) })
        #expect(await DeleteAccount.run(tripIds: [], steps: s) == .failed(DeleteAccount.otherAppleIDLine))
        #expect(!log.events.contains("clear"))
    }

    @Test func aGoneUserBeforeTheSheetNeverShowsAppleOrCallsTheServer() async {
        let log = Log()
        let s = steps(log, reload: { throw authError(.userNotFound) })
        #expect(await DeleteAccount.run(tripIds: [], steps: s) == .deleted)
        #expect(log.events == ["reload", "clear", "signOut"])
    }

    @Test func aReloadThatFailsOnTheNetworkDoesNotStopTheDeletion() async {
        let log = Log()
        let s = steps(log, reload: { throw NSError(domain: NSURLErrorDomain, code: -1009) })
        #expect(await DeleteAccount.run(tripIds: [], steps: s) == .deleted)
        #expect(log.events.contains("server"))
    }

    @Test func revokeThrowsWithoutAUserAndSkipsOnTheEmulator() async throws {
        var sent: [String] = []
        await #expect(throws: Error.self) {
            try await DeleteAccount.revokeToken("c", hasUser: false, emulator: false) { sent.append($0) }
        }
        try await DeleteAccount.revokeToken("c", hasUser: true, emulator: true) { sent.append($0) }
        #expect(sent.isEmpty)
        try await DeleteAccount.revokeToken("c", hasUser: true, emulator: false) { sent.append($0) }
        #expect(sent == ["c"])
    }

    @Test func theCacheIsClearedOnTheNextLaunchOnlyWhenFlagged() {
        let defaults = UserDefaults(suiteName: "persist-\(UUID().uuidString)")!
        var cleared = 0
        #expect(!PersistenceReset.runIfPending(defaults: defaults) { done in cleared += 1; done(nil) })
        #expect(cleared == 0)
        PersistenceReset.markPending(defaults: defaults)
        #expect(PersistenceReset.runIfPending(defaults: defaults) { done in cleared += 1; done(Boom()) })
        #expect(PersistenceReset.isPending(defaults: defaults), "a failed clear keeps the flag")
        #expect(PersistenceReset.runIfPending(defaults: defaults) { done in cleared += 1; done(nil) })
        #expect(!PersistenceReset.isPending(defaults: defaults) && cleared == 2)
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
