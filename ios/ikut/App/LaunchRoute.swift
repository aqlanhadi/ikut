import Foundation

/// Where the app opens, once it knows whether this phone is signed in (#401, D54): straight into a trip it is still in
/// (the lobby before Start, the driving map after), else Join for a link it was opened with, else Home.
enum LaunchRoute: Equatable {
    case home
    case join(code: String)
    case trip(id: String, started: Bool)

    /// The trips worth reading at launch: the ones this phone lists in Now (not ended here), newest first.
    static func candidates(_ entries: [PastTrips.Entry]) -> [PastTrips.Entry] { HomeNow.split(entries).now }

    /// Signed in, the newest trip in Now that is still going and still has this phone opens: one that ended or that
    /// this phone left or was removed from (`HomeNow.Read.gone`) is passed over (Home moves it to Past trips). A trip
    /// whose read gave nothing back (no signal, too slow) counts as still going: the trip screen says what it finds.
    /// A join link waits behind a trip this phone is in, and is dropped (as it is mid-trip); otherwise it opens Join.
    /// Signed out, no trip is opened.
    static func decide(signedIn: Bool, entries: [PastTrips.Entry], read: [String: HomeNow.Read],
                       pendingJoin: String?) -> LaunchRoute {
        if signedIn {
            for entry in candidates(entries) {
                guard let found = read[entry.id] else { return .trip(id: entry.id, started: false) }
                if found.endedAt != nil || found.gone { continue }
                return .trip(id: entry.id, started: found.started)
            }
        }
        if let pendingJoin { return .join(code: pendingJoin) }
        return .home
    }

    /// Whether launch has to read anything first: only when signed in with a trip in Now. Otherwise it decides at once,
    /// so Home (or Join) shows on the first frame.
    static func needsReads(signedIn: Bool, entries: [PastTrips.Entry]) -> Bool {
        signedIn && !candidates(entries).isEmpty
    }

    /// How long launch waits for one trip's read before taking it as still going.
    static let readTimeout: Duration = .seconds(4)

    /// Reads the trips in Now, newest first, until one is still going (each ended or gone one moves to Past trips on
    /// the way), and decides.
    @MainActor
    static func load(signedIn: Bool, pendingJoin: String?, entries: [PastTrips.Entry] = PastTrips.all(),
                     read: @escaping @MainActor (String) async -> HomeNow.Read = { await HomeNow.load(tripId: $0, line: false) },
                     record: (PastTrips.Entry, HomeNow.Read, Date) -> Void = { entry, found, endedAt in
                         PastTrips.record(tripId: entry.id, name: found.name ?? entry.name,
                                          destination: found.destination ?? entry.destination, endedAt: endedAt)
                     }) async -> LaunchRoute {
        var reads: [String: HomeNow.Read] = [:]
        if signedIn {
            for entry in candidates(entries) {
                guard let found = await withTimeout(readTimeout, { await read(entry.id) }) else { break }
                reads[entry.id] = found
                guard let movedAt = HomeNow.movesToPast(found, signedIn: true) else { break }
                record(entry, found, movedAt)
            }
        }
        return decide(signedIn: signedIn, entries: entries, read: reads, pendingJoin: pendingJoin)
    }

    /// `work`'s result, or nil if it takes longer than `limit` (a Firestore read doesn't stop when cancelled, so the
    /// wait ends without it; it finishes on its own).
    @MainActor
    private static func withTimeout<T>(_ limit: Duration, _ work: @escaping @MainActor () async -> T) async -> T? {
        let once = LaunchOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            Task { @MainActor in
                let value = await work()
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: value)
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: nil)
            }
        }
    }
}

/// Who answered first in `LaunchRoute.withTimeout`: the read or the clock.
@MainActor private final class LaunchOnce {
    var done = false
}
