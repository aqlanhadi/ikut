import Foundation
import Testing
@testable import ikut

@MainActor
struct SingleFlightTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// Q29: `add` and the `entries()` task both asked for the monitor while the first creation was
    /// still awaiting, so two `CLMonitor`s with one name were made.
    @Test func concurrentCallersShareOneCreation() async {
        let flight = SingleFlight<Int>()
        let counter = Counter()
        let make: @Sendable () async -> Int = {
            let id = counter.next()
            try? await Task.sleep(for: .milliseconds(50))
            return id
        }
        let tasks = (0..<8).map { _ in Task { await flight.get(make) } }
        var results: [Int] = []
        for task in tasks { results.append(await task.value) }
        #expect(counter.count == 1)
        #expect(results == Array(repeating: 1, count: 8))
        #expect(await flight.get(make) == 1)
        #expect(counter.count == 1)
    }
}
