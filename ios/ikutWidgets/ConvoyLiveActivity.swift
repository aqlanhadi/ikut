import ActivityKit
import SwiftUI
import WidgetKit

struct ConvoyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ConvoyActivityAttributes.self) { context in
            VStack(alignment: .leading) {
                Text(context.attributes.tripName).font(.headline)
                Text(context.state.line)
                Text("Update \(context.state.tick)").font(.caption)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.line)
                }
            } compactLeading: {
                Image(systemName: "car.fill")
            } compactTrailing: {
                Text("\(context.state.tick)")
            } minimal: {
                Image(systemName: "car.fill")
            }
        }
    }
}
