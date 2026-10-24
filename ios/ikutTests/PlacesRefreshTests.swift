import CryptoKit
import Foundation
import Testing
@testable import ikut

/// Serves the manifest and the places file from memory and records every request.
final class StubHosting: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var manifest: Data?
    nonisolated(unsafe) static var file: Data?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.requests.append(request) }
        let path = request.url?.lastPathComponent
        let body = path == "manifest.json" ? Self.manifest : path == "places.json" ? Self.file : nil
        let response = HTTPURLResponse(url: request.url!, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func reset() { lock.withLock { requests = [] }; manifest = nil; file = nil }
}

@Suite("Places refresh", .serialized)
struct PlacesRefreshTests {
    static let bundledData = try! Data(contentsOf: Bundle.main.url(forResource: "places", withExtension: "json")!)
    static let bundled = try! PlacesLoader.decode(bundledData)
    static let oldStamp = "2026-10-22T20:21:33.000Z"

    /// The bundled file with a different `generatedAt` (same size).
    static func file(stamp: String = "2026-11-22T20:21:33.000Z", version: Int = 1) -> Data {
        var text = String(decoding: bundledData, as: UTF8.self)
        text = text.replacingOccurrences(of: oldStamp, with: stamp)
        if version != 1 { text = text.replacingOccurrences(of: "\"version\":1", with: "\"version\":\(version)") }
        return Data(text.utf8)
    }

    static func manifest(for data: Data, stamp: String = "2026-11-22T20:21:33.000Z", version: Int = 1, bytes: Int? = nil, sha: String? = nil) -> Data {
        let hash = sha ?? SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Data(#"{"version":\#(version),"generatedAt":"\#(stamp)","bytes":\#(bytes ?? data.count),"sha256":"\#(hash)"}"#.utf8)
    }

    /// A refresher on stub hosting, a scratch store and defaults, and a clock.
    struct Rig {
        var refresher: PlacesRefresher
        var store: PlacesStore
        var defaults: UserDefaults
    }

    static func rig(now: Date = Date(timeIntervalSince1970: 1_800_000_000), lastCheck: Date? = nil, bundled: PlacesFile = bundled, tripRunning: Bool = false) -> Rig {
        StubHosting.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubHosting.self]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("places-test-\(UUID().uuidString)")
        let store = PlacesStore(directory: dir)
        let defaults = UserDefaults(suiteName: "places-test-\(UUID().uuidString)")!
        if let lastCheck { defaults.set(lastCheck, forKey: PlacesRefresher.lastCheckKey) }
        let refresher = PlacesRefresher(
            session: URLSession(configuration: config), store: store, defaults: defaults, inApp: { bundled }, now: { now }, tripRunning: { tripRunning })
        return Rig(refresher: refresher, store: store, defaults: defaults)
    }

    @Test func newerFileIsDownloadedAndUsedNextLaunch() async throws {
        let rig = Self.rig()
        let data = Self.file()
        StubHosting.manifest = Self.manifest(for: data)
        StubHosting.file = data
        #expect(await rig.refresher.refreshIfDue())
        let used = try #require(PlacesSource.current(bundled: { Self.bundled }, store: rig.store))
        #expect(used.generatedAt > Self.bundled.generatedAt)
        // It stays for the next check: the same stamp is not downloaded again.
        #expect(rig.defaults.object(forKey: PlacesRefresher.lastCheckKey) != nil)
    }

    @Test func sameGeneratedAtIsNotDownloaded() async {
        let rig = Self.rig()
        let data = Self.file(stamp: Self.oldStamp)
        StubHosting.manifest = Self.manifest(for: data, stamp: Self.oldStamp)
        StubHosting.file = data
        #expect(await rig.refresher.refreshIfDue() == false)
        #expect(StubHosting.requests.map { $0.url?.lastPathComponent } == ["manifest.json"])
        #expect(rig.store.load() == nil)
        // A check that found nothing newer still counts: the week runs from it.
        #expect(rig.defaults.object(forKey: PlacesRefresher.lastCheckKey) != nil)
    }

    @Test func unsupportedVersionIsSkipped() async {
        let rig = Self.rig()
        let data = Self.file(version: 2)
        StubHosting.manifest = Self.manifest(for: data, version: 2)
        StubHosting.file = data
        #expect(await rig.refresher.refreshIfDue() == false)
        #expect(StubHosting.requests.map { $0.url?.lastPathComponent } == ["manifest.json"])
        #expect(rig.store.load() == nil)
        #expect(rig.defaults.object(forKey: PlacesRefresher.lastCheckKey) != nil)
    }

    @Test func sizeMismatchIsRejected() async {
        let rig = Self.rig()
        let data = Self.file()
        StubHosting.manifest = Self.manifest(for: data, bytes: data.count - 1)
        StubHosting.file = data
        #expect(await rig.refresher.refreshIfDue() == false)
        #expect(rig.store.load() == nil)
        #expect(rig.defaults.object(forKey: PlacesRefresher.lastCheckKey) == nil)
    }

    @Test func hashMismatchIsRejected() async {
        let rig = Self.rig()
        let data = Self.file()
        StubHosting.manifest = Self.manifest(for: data, sha: String(repeating: "0", count: 64))
        StubHosting.file = data
        #expect(await rig.refresher.refreshIfDue() == false)
        #expect(rig.store.load() == nil)
    }

    @Test func fileThatDoesNotReadIsRejected() async {
        let rig = Self.rig()
        let data = Data(#"{"version":1,"generatedAt":"2026-11-22T20:21:33.000Z","sites":"nope"}"#.utf8)
        StubHosting.manifest = Self.manifest(for: data)
        StubHosting.file = data
        #expect(await rig.refresher.refreshIfDue() == false)
        #expect(rig.store.load() == nil)
    }

    @Test func tooSmallFileIsRejected() async {
        let rig = Self.rig()
        let data = Data(#"{"version":1,"generatedAt":"2026-11-22T20:21:33.000Z","source":"x","license":"ODbL","sites":[],"fuel":[]}"#.utf8)
        StubHosting.manifest = Self.manifest(for: data)
        StubHosting.file = data
        #expect(await rig.refresher.refreshIfDue() == false)
        #expect(rig.store.load() == nil)
    }

    @Test func oldFileIsKeptWhenALaterDownloadIsBad() async throws {
        let rig = Self.rig()
        let good = Self.file()
        StubHosting.manifest = Self.manifest(for: good)
        StubHosting.file = good
        #expect(await rig.refresher.refreshIfDue())
        let before = try Data(contentsOf: rig.store.fileURL)
        // A week later a newer manifest points at a truncated file.
        let later = PlacesRefresher(
            session: {
                let c = URLSessionConfiguration.ephemeral
                c.protocolClasses = [StubHosting.self]
                return URLSession(configuration: c)
            }(), store: rig.store, defaults: rig.defaults, inApp: { Self.bundled }, now: { Date(timeIntervalSince1970: 1_800_000_000 + 8 * 86_400) })
        let cut = good.prefix(good.count / 2)
        StubHosting.manifest = Self.manifest(for: Data(cut), stamp: "2026-12-22T20:21:33.000Z", bytes: good.count, sha: "abc")
        StubHosting.file = Data(cut)
        #expect(await later.refreshIfDue() == false)
        #expect(try Data(contentsOf: rig.store.fileURL) == before)
    }

    @Test func offlineChangesNothing() async {
        let rig = Self.rig()
        // No manifest served: a 404 stands for any failure.
        #expect(await rig.refresher.refreshIfDue() == false)
        #expect(rig.store.load() == nil)
        #expect(rig.defaults.object(forKey: PlacesRefresher.lastCheckKey) == nil)
    }

    @Test func checkedADayAgoMeansNoRequest() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rig = Self.rig(now: now, lastCheck: now.addingTimeInterval(-86_400))
        let data = Self.file()
        StubHosting.manifest = Self.manifest(for: data)
        StubHosting.file = data
        #expect(await rig.refresher.refreshIfDue() == false)
        #expect(StubHosting.requests.isEmpty)
    }

    @Test func checkedEightDaysAgoAsksAgain() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rig = Self.rig(now: now, lastCheck: now.addingTimeInterval(-8 * 86_400))
        let data = Self.file()
        StubHosting.manifest = Self.manifest(for: data)
        StubHosting.file = data
        #expect(await rig.refresher.refreshIfDue())
    }

    @Test func aClockSetBackMeansAskAgain() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rig = Self.rig(now: now, lastCheck: now.addingTimeInterval(30 * 86_400))
        let data = Self.file()
        StubHosting.manifest = Self.manifest(for: data)
        StubHosting.file = data
        #expect(await rig.refresher.refreshIfDue())
    }

    @Test func noRequestWhileATripIsRunning() async {
        let rig = Self.rig(tripRunning: true)
        let data = Self.file()
        StubHosting.manifest = Self.manifest(for: data)
        StubHosting.file = data
        #expect(await rig.refresher.refreshIfDue() == false)
        #expect(StubHosting.requests.isEmpty)
    }

    @Test func requestsCarryNothingAboutThePerson() async {
        let rig = Self.rig()
        let data = Self.file()
        StubHosting.manifest = Self.manifest(for: data)
        StubHosting.file = data
        _ = await rig.refresher.refreshIfDue()
        #expect(StubHosting.requests.count == 2)
        for request in StubHosting.requests {
            #expect(request.url?.query == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.url?.host == PlacesHosting.baseURL.host)
        }
    }

    @Test func aNewerBundledFileWinsAndRemovesTheDownload() throws {
        let rig = Self.rig()
        try rig.store.write(Self.file(stamp: "2026-11-01T00:00:00.000Z"))
        // The app update's file is from December: the November download is stale.
        let december = try PlacesLoader.decode(Self.file(stamp: "2026-12-01T00:00:00.000Z"))
        let used = PlacesSource.current(bundled: { december }, store: rig.store)
        #expect(used?.generatedAt == december.generatedAt)
        #expect(rig.store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: rig.store.fileURL.path))
    }

    @Test func aNewerDownloadWinsOverTheBundledFile() throws {
        let rig = Self.rig()
        try rig.store.write(Self.file(stamp: "2026-11-01T00:00:00.000Z"))
        let used = PlacesSource.current(bundled: { Self.bundled }, store: rig.store)
        #expect(used?.generatedAt != Self.bundled.generatedAt)
        #expect(FileManager.default.fileExists(atPath: rig.store.fileURL.path))
    }

    @Test func aDownloadThatDoesNotReadFallsBackToTheBundledFile() throws {
        let rig = Self.rig()
        try rig.store.write(Data("not json".utf8))
        let used = PlacesSource.current(bundled: { Self.bundled }, store: rig.store)
        #expect(used?.generatedAt == Self.bundled.generatedAt)
    }

    @Test func downloadIsKeptOutOfBackups() async throws {
        let rig = Self.rig()
        try rig.store.write(Self.file())
        let values = try rig.store.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }
}
