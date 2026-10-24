import SwiftUI

/// The End trip and Leave trip items of a trip menu (the lobby's and the map's). Each only shows when the screen
/// says it applies; picking one asks `tripExitDialogs` to confirm.
struct TripExitMenu: View {
    var canEnd: Bool
    var canLeave: Bool
    @Binding var confirmEnd: Bool
    @Binding var confirmLeave: Bool

    var body: some View {
        if canEnd {
            Button("End trip", systemImage: "flag.checkered", role: .destructive) { confirmEnd = true }
        }
        if canLeave {
            Button("Leave trip", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                confirmLeave = true
            }
        }
    }
}

extension View {
    /// The two confirmations behind `TripExitMenu`; each screen passes what leaving and ending do there.
    func tripExitDialogs(
        confirmLeave: Binding<Bool>, confirmEnd: Binding<Bool>,
        leave: @escaping () -> Void, end: @escaping () -> Void
    ) -> some View {
        confirmationDialog("Leave this trip?", isPresented: confirmLeave, titleVisibility: .visible) {
            Button("Leave trip", role: .destructive, action: leave)
        } message: {
            Text("Your phone stops sharing its location.")
        }
        .confirmationDialog("End the trip for everyone?", isPresented: confirmEnd, titleVisibility: .visible) {
            Button("End trip", role: .destructive, action: end)
        } message: {
            Text("Everyone stops sharing their location. This can't be undone.")
        }
    }
}
