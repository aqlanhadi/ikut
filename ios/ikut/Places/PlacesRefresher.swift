import CryptoKit
import Foundation
import os

/// Where the weekly refresh looks (Firebase Hosting, `firebase/hosting/places/`). The one place the address lives.
enum PlacesHosting {
    static let baseURL = URL(string: "https://ikut-b1083.web.app/places/")!
    static var manifestURL: URL { baseURL.appendingPathComponent("manifest.json") }
    static var fileURL: URL { baseURL.appendingPathComponent("places.json") }
}

/// The few hundred bytes that say what the hosted places file is, so the weekly check is cheap.
struct PlacesManifest: Decodable, Sendable {
    var version: Int
    var generatedAt: Date
    var bytes: Int
    var sha256: String

    static func decode(_ data: Data) throws -> PlacesManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        return try decoder.decode(PlacesManifest.self, from: data)
    }
}

/// The downloaded copy of the places file, in Application Support, kept out of backups.
struct PlacesStore: Sendable {
    var directory: URL

    static var standard: PlacesStore {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return PlacesStore(directory: base.appendingPathComponent("places", isDirectory: true))
    }

    var fileURL: URL { directory.appendingPathComponent("places.json") }

    func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    func remove() { try? FileManager.default.removeItem(at: fileURL) }

    /// The downloaded file if it is there and reads.
    func load() -> PlacesFile? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try? PlacesLoader.load(from: fileURL)
    }
}

/// Which places file the app uses: the downloaded one if it is valid and newer than the one inside the app, else
/// the one inside the app. An app update that brings a newer file than the download wins and deletes the download.
enum PlacesSource {
    static func current(bundled: () -> PlacesFile? = { try? PlacesLoader.bundled() }, store: PlacesStore = .standard) -> PlacesFile? {
        let inApp = bundled()
        guard let downloaded = store.load() else { return inApp }
        guard let inApp else { return downloaded }
        if downloaded.generatedAt > inApp.generatedAt { return downloaded }
        store.remove()
        return inApp
    }
}

/// Once a week, when the app opens, asks Firebase Hosting whether there is a newer places file; if so downloads it,
/// checks it and keeps it for the next launch. Offline or anything wrong with the hosted file: nothing changes,
/// silently, and the next open tries again. The requests carry nothing about the person or a trip.
final class PlacesRefresher: @unchecked Sendable {
    static let shared = PlacesRefresher()

    private static let tripFlag = OSAllocatedUnfairLock(initialState: false)
    /// True while a car is sharing its position: no refresh then. Set by `TripSession`. The check runs once per
    /// process, at app open, so this is read once; a trip that starts later is never interrupted by it.
    static var tripRunning: Bool {
        get { tripFlag.withLock { $0 } }
        set { tripFlag.withLock { $0 = newValue } }
    }

    static let interval: TimeInterval = 7 * 24 * 3600
    static let lastCheckKey = "placesLastCheck"
    /// A hosted file with fewer sites than this share of the one in the app is a broken export.
    static let floorShare = 0.5

    private let session: URLSession
    private let store: PlacesStore
    private let defaults: UserDefaults
    private let inApp: @Sendable () -> PlacesFile?
    private let now: @Sendable () -> Date
    private let tripRunning: @Sendable () -> Bool
    private let manifestURL: URL
    private let fileURL: URL

    init(
        session: URLSession? = nil, store: PlacesStore = .standard, defaults: UserDefaults = .standard,
        inApp: @escaping @Sendable () -> PlacesFile? = { try? PlacesLoader.bundled() },
        now: @escaping @Sendable () -> Date = { Date() },
        tripRunning: @escaping @Sendable () -> Bool = { PlacesRefresher.tripRunning },
        manifestURL: URL = PlacesHosting.manifestURL, fileURL: URL = PlacesHosting.fileURL
    ) {
        if let session {
            self.session = session
        } else {
            // No cookies, no cache on disk, no credentials: a plain GET.
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.timeoutIntervalForRequest = 20
            self.session = URLSession(configuration: config)
        }
        self.store = store
        self.defaults = defaults
        self.inApp = inApp
        self.now = now
        self.tripRunning = tripRunning
        self.manifestURL = manifestURL
        self.fileURL = fileURL
    }

    /// Whether the check is due: never done, or the last successful one was a week ago or more.
    func isDue() -> Bool {
        guard let last = defaults.object(forKey: Self.lastCheckKey) as? Date else { return true }
        return now().timeIntervalSince(last) >= Self.interval
    }

    /// Checks, and downloads when there is a newer file. Never throws and never reports: returns whether a new file
    /// was stored (for the tests).
    @discardableResult
    func refreshIfDue() async -> Bool {
        guard !tripRunning(), isDue() else { return false }
        guard let bundled = inApp() else { return false }
        let inUse = PlacesSource.current(bundled: { bundled }, store: store) ?? bundled
        guard let manifest = await fetchManifest() else { return false }
        guard manifest.version <= PlacesFile.supportedVersion else { return false }
        guard manifest.generatedAt > inUse.generatedAt else {
            defaults.set(now(), forKey: Self.lastCheckKey)
            return false
        }
        guard let data = await fetch(fileURL), accept(data, for: manifest, bundledCount: bundled.sites.count) else { return false }
        do { try store.write(data) } catch { return false }
        defaults.set(now(), forKey: Self.lastCheckKey)
        return true
    }

    /// The hosted file matches its manifest, reads, and has not lost most of its sites.
    func accept(_ data: Data, for manifest: PlacesManifest, bundledCount: Int) -> Bool {
        guard data.count == manifest.bytes else { return false }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == manifest.sha256.lowercased() else { return false }
        guard let file = try? PlacesLoader.decode(data) else { return false }
        return Double(file.sites.count) >= Double(bundledCount) * Self.floorShare
    }

    private func fetchManifest() async -> PlacesManifest? {
        guard let data = await fetch(manifestURL) else { return nil }
        return try? PlacesManifest.decode(data)
    }

    private func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}
