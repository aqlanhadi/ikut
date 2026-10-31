import ActivityKit

/// The Live Activity's data, shared by the app (which starts and updates it) and the `ikutWidgets` extension
/// (which draws it). Spike: one line of text and a counter; the real states come with the design pass (D3).
struct ConvoyActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var line: String
        var tick: Int
    }

    var tripName: String
}
