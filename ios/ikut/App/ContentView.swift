import SwiftUI

/// Placeholder root view until the welcome and trip flows land (T1, T3).
struct ContentView: View {
    @Environment(AuthModel.self) private var auth

    var body: some View {
        switch auth.state {
        case .loading:
            ProgressView()
        case .signedOut:
            NameEntryView()
        case .signedIn:
            VStack(spacing: 12) {
                Text("ikut")
                    .font(.largeTitle.bold())
                Text("Drive together. Arrive together.")
                    .foregroundStyle(.secondary)
                if let name = auth.displayName {
                    Text("Signed in as \(name)")
                }
                Text(Backend.current.label)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.top, 24)
            }
            .padding()
        }
    }
}

#Preview {
    Backend.configure()
    return ContentView()
        .environment(AuthModel())
}
