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
            Button("End trip", systemImage: Symbol.finish, role: .destructive) { confirmEnd = true }
        }
        if canLeave {
            Button("Leave trip", systemImage: Symbol.leaveTrip, role: .destructive) {
                confirmLeave = true
            }
        }
    }
}

extension View {
    /// The one shape of a confirmation: an alert whose title is the question, one sentence of message, a red button
    /// named for the action, and Cancel. Every ask-before-doing dialog goes through here so they cannot drift.
    func confirmAlert(
        _ title: LocalizedStringKey, message: LocalizedStringKey, action: LocalizedStringKey,
        destructive: Bool = true, isPresented: Binding<Bool>, perform: @escaping () -> Void
    ) -> some View {
        alert(title, isPresented: isPresented) {
            Button(action, role: destructive ? .destructive : nil, action: perform)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(message)
        }
    }

    /// The confirmation behind the lobby's New code row (D104), asked inside the sheet like Leave and End.
    func tripNewCodeDialog(isPresented: Binding<Bool>, make: @escaping () -> Void) -> some View {
        confirmAlert(
            "Make a new code?",
            message: "The old code stops working. People already in the trip stay in. Share the new code with anyone still to join.",
            action: "Make a new code", destructive: false, isPresented: isPresented, perform: make)
    }

    /// The organiser's hand-over (D106), asked after they picked who: the person is named in the title and the sentence.
    func tripHandOverDialog(name: String, isPresented: Binding<Bool>, hand: @escaping () -> Void) -> some View {
        confirmAlert(
            "Make \(name) the organiser?",
            message: "You’ll leave the trip, and \(name) can start it, end it and make a new code.",
            action: "Hand over and leave", isPresented: isPresented, perform: hand)
    }

    /// The two confirmations behind `TripExitMenu`; each screen passes what leaving and ending do there.
    func tripExitDialogs(
        confirmLeave: Binding<Bool>, confirmEnd: Binding<Bool>,
        leave: @escaping () -> Void, end: @escaping () -> Void
    ) -> some View {
        confirmAlert(
            "Leave this trip?", message: "Your phone stops sharing its location.", action: "Leave trip",
            isPresented: confirmLeave, perform: leave)
        .confirmAlert(
            "End the trip for everyone?", message: "Everyone stops sharing their location. This can’t be undone.",
            action: "End trip", isPresented: confirmEnd, perform: end)
    }
}
