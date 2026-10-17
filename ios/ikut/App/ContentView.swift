import SwiftUI

/// Placeholder root view until the welcome and trip flows land (T1, T3).
struct ContentView: View {
    @Environment(AuthModel.self) private var auth
    /// Code from an opened join link; kept while signed out and handed to Home.
    @Binding var pendingJoinCode: String?

    init(pendingJoinCode: Binding<String?> = .constant(nil)) {
        _pendingJoinCode = pendingJoinCode
    }

    var body: some View {
        switch auth.state {
        case .loading:
            ProgressView()
        case .signedOut:
            NameEntryView()
        case .signedIn:
            HomeView(pendingJoinCode: $pendingJoinCode)
        }
    }
}

#Preview {
    Backend.configure()
    return ContentView()
        .environment(AuthModel())
        .environment(LocationPermission())
}
