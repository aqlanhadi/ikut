import Network
import Observation
import SwiftUI

/// Whether my own phone counts as online, the way the others see it (D37): it has a network path and, when
/// it is my car's tracker, my car is not stale by the rule that greys out other cars. Either failing is offline.
/// A passenger phone goes by its own path only.
enum YouOnline {
    static func isOnline(pathUp: Bool, isTracker: Bool, carStale: Bool) -> Bool {
        pathUp && !(isTracker && carStale)
    }

    /// What VoiceOver reads for the tag.
    static func spoken(online: Bool) -> String { online ? "You" : "You, offline" }

    /// What the tag says; with Differentiate Without Colour on, the offline tag says so in words.
    static func text(online: Bool, differentiateWithoutColor: Bool) -> String {
        online || !differentiateWithoutColor ? "You" : "You · Offline"
    }
}

/// The network path as a stream of up/down values, behind a protocol so tests can feed it.
protocol NetworkPathSource: Sendable {
    func paths() -> AsyncStream<Bool>
}

struct SystemNetworkPath: NetworkPathSource {
    func paths() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { continuation.yield($0.status == .satisfied) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "ikut.network-path"))
        }
    }
}

/// One observable for the app: whether the phone has a network path. A change shows only after the new
/// value has held for `hold` (about 3 s), so a brief blip does not flicker the tag.
@MainActor @Observable
final class NetworkStatus {
    private(set) var isUp = true
    @ObservationIgnored private let source: any NetworkPathSource
    @ObservationIgnored private let hold: Duration
    @ObservationIgnored private var pending: Task<Void, Never>?

    init(source: any NetworkPathSource = SystemNetworkPath(), hold: Duration = .seconds(3)) {
        self.source = source
        self.hold = hold
    }

    func run() async {
        for await up in source.paths() { observe(up) }
        pending?.cancel()
    }

    func observe(_ up: Bool) {
        pending?.cancel()
        guard up != isUp else { return }
        pending = Task { [hold] in
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled else { return }
            isUp = up
        }
    }
}

/// "• You" after my car's name, in the name's own font: "You" green while I am online, orange while offline.
struct YouTag: View {
    var online: Bool
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        (Text("• ") + Text(YouOnline.text(online: online, differentiateWithoutColor: differentiate))
            .foregroundStyle(online ? Color.ikutPositive : Color.ikutWarning))
            .lineLimit(1)
            .fixedSize()
            .animation(Motion.gentle(reduceMotion: reduceMotion), value: online)
            .accessibilityLabel(YouOnline.spoken(online: online))
    }
}
