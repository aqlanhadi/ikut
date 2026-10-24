#if DEBUG
import SwiftUI

/// The convoy panel's header for the viewer's own trip (D26, `IKUT_SCREEN=road-header-moving`, `road-header-parked`,
/// `road-header-never`, `road-header-convoy`): Hafiz joining while driving, parked at home, on a route that never
/// meets the convoy, and a car already in the convoy.
struct PanelHeaderDemo: View {
    var joiner: MapDemo.Joiner?
    @State private var map: TripMapModel
    @State private var expanded = true

    init(_ joiner: MapDemo.Joiner?) {
        self.joiner = joiner
        _map = State(initialValue: MapDemo.model(joiner: joiner))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(.systemGray4).ignoresSafeArea()
            ConvoyPanel(model: map, expanded: $expanded, canReport: true, onReport: {}, onStop: {}).previewCard()
        }
    }
}
#endif
