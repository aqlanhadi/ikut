import SwiftUI

/// Placeholder root view until the welcome and trip flows land (T1, T3).
struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("ikut")
                .font(.largeTitle.bold())
            Text("Drive together. Arrive together.")
                .foregroundStyle(.secondary)
            Text(Backend.current.label)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .padding(.top, 24)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
