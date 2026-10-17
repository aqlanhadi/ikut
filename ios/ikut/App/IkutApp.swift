import SwiftUI

@main
struct IkutApp: App {
    @State private var auth: AuthModel
    @State private var location = LocationPermission()

    init() {
        Backend.configure()
        _auth = State(initialValue: AuthModel())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(auth)
                .environment(location)
        }
    }
}
