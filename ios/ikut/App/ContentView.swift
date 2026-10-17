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
            HomeView()
        }
    }
}

#Preview {
    Backend.configure()
    return ContentView()
        .environment(AuthModel())
        .environment(LocationPermission())
}
