import SwiftUI

/// Root view: a spinner while Firebase restores the session, then Home.
/// Home shows the welcome screen whether or not the person is signed in; the name step
/// happens there, when they pick Start or Join.
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
        case .signedOut, .signedIn:
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
