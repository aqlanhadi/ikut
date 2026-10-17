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
            ContentView(pendingJoinCode: $pendingJoinCode)
                .environment(auth)
                .environment(location)
                .onOpenURL { url in
                    if case .join(let code)? = DeepLink.parse(url) { pendingJoinCode = code }
                }
        }
    }
}
