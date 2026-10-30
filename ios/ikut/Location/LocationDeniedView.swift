import SwiftUI

/// Shown when location access is denied or restricted and the trip can't show the user's car.
struct LocationDeniedView: View {
    let onOpenSettings: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Location is off", systemImage: Symbol.locationOff)
        } description: {
            Text("ikut needs your location during a trip so the others can see your car. Turn it on in Settings.")
        } actions: {
            Button(action: onOpenSettings) { Text("Open Settings").frame(maxWidth: .infinity) }
                .ikutButton(.primary)
        }
    }
}

#Preview {
    LocationDeniedView(onOpenSettings: {})
}
