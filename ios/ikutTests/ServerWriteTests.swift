import Foundation
import Testing
@testable import ikut

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
}
