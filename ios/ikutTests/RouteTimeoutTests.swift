import Foundation
import Testing
@testable import ikut

@MainActor
struct RouteTimeoutTests {
    @Test func returnsWorkThatFinishesInTime() async throws {
        let value = try await RouteBuilder.withTimeout(.seconds(5), error: .timedOut) { 42 }
        #expect(value == 42)
    }

    /// The case that left Where to? spinning: work that never finishes (MapKit waiting for a fix).
    @Test func throwsAndCancelsWhenWorkHangs() async throws {
        var cancelled = false
        await #expect(throws: RouteError.locationUnavailable) {
            _ = try await RouteBuilder.withTimeout(.milliseconds(100), error: .locationUnavailable) {
                try await Task.sleep(for: .seconds(60))
                return 0
            } onTimeout: {
                cancelled = true
            }
        }
        #expect(cancelled)
    }
}
