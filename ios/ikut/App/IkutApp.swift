import SwiftUI

@main
struct IkutApp: App {
    init() {
        Backend.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
