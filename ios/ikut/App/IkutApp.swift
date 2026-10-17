import SwiftUI

@main
struct IkutApp: App {
    @State private var auth: AuthModel

    init() {
        Backend.configure()
        _auth = State(initialValue: AuthModel())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(auth)
        }
    }
}
