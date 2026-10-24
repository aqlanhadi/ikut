import SwiftUI

@main
struct IkutApp: App {
    @State private var auth: AuthModel
    @State private var location = LocationPermission()
    @State private var pendingJoinCode: String?

    init() {
        Backend.configure()
        _auth = State(initialValue: AuthModel())
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let name = ProcessInfo.processInfo.environment["IKUT_SCREEN"], let demo = DemoScreens.view(name) {
                demo
            } else {
                root
            }
            #else
            root
            #endif
        }
    }

    private var root: some View {
        Group {
            ContentView(pendingJoinCode: $pendingJoinCode)
                .environment(auth)
                .environment(location)
                .task { await PlacesRefresher.shared.refreshIfDue() }
                .onOpenURL { url in
                    if case .join(let code)? = DeepLink.parse(url) { pendingJoinCode = code }
                }
        }
    }
}
