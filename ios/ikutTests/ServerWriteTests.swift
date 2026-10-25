import Foundation
import Testing
@testable import ikut

@Suite(.serialized)
struct ServerWriteTests {
    private struct Rejected: Error {}

    /// Like a Firestore write offline: never finishes early, even when cancelled.
    private static func stuckWrite() async throws {
        let until = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < until { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func acceptedWriteReturnsTrue() async throws {
        let accepted = try await ServerWrite.commit(within: .seconds(2)) {}
        #expect(accepted)
    }

    @Test func stuckWriteReleasesTheCallerAtTheDeadline() async throws {
        let saved = ServerWrite.onTimeout
        ServerWrite.onTimeout = {}
        defer { ServerWrite.onTimeout = saved }
        let start = ContinuousClock.now
        let accepted = try await ServerWrite.commit(within: .milliseconds(200)) { try await Self.stuckWrite() }
        #expect(!accepted)
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func rejectedWriteThrows() async {
        await #expect(throws: Rejected.self) {
            try await ServerWrite.commit(within: .seconds(2)) { throw Rejected() }
        }
    }

    @Test func timeoutRunsTheUserCheckButAcceptedAndRejectedDoNot() async throws {
        nonisolated(unsafe) var checks = 0
        let saved = ServerWrite.onTimeout
        ServerWrite.onTimeout = { checks += 1 }
        defer { ServerWrite.onTimeout = saved }

        try await ServerWrite.commit(within: .seconds(2)) {}
        _ = try? await ServerWrite.commit(within: .seconds(2)) { throw Rejected() }
        #expect(checks == 0)

        let accepted = try await ServerWrite.commit(within: .milliseconds(100)) { try await Self.stuckWrite() }
        #expect(!accepted)
        #expect(checks == 1)
    }

    /// A user check that never answers (reload hanging offline) can't hold the caller past the cap.
    @Test func aUserCheckThatNeverFinishesStillReleasesTheCaller() async throws {
        let saved = ServerWrite.onTimeout
        ServerWrite.onTimeout = { try? await Task.sleep(for: .seconds(30)) }
        defer { ServerWrite.onTimeout = saved }

        let start = ContinuousClock.now
        let accepted = try await ServerWrite.commit(within: .milliseconds(100)) { try await Self.stuckWrite() }
        #expect(!accepted)
        #expect(ContinuousClock.now - start < ServerWrite.checkTimeout + .milliseconds(500))
    }
}
