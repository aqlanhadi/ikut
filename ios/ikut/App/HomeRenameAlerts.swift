import SwiftUI

/// The name alerts of Home's sheet (D63 B1): "Your name" with a field, and the message when it can't be saved. They are
/// presented from the sheet, since a presented sheet blocks a presentation from Home.
struct HomeRenameAlerts: ViewModifier {
    @Environment(AuthModel.self) private var auth
    @Binding var renaming: Bool
    @Binding var newName: String
    @Binding var renameError: String?

    func body(content: Content) -> some View {
        content
            .alert("Your name", isPresented: $renaming) {
                TextField("Your name", text: $newName)
                    .textInputAutocapitalization(.words)
                Button("Cancel", role: .cancel) {}
                Button("Save") { saveName() }
            } message: {
                Text("What the convoy sees in new trips.")
            }
            .alert("Couldn’t change your name", isPresented: .constant(renameError != nil)) {
                Button("OK") { renameError = nil }
            } message: {
                Text(renameError ?? "")
            }
    }

    private func saveName() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .success = DisplayName.validate(trimmed) else {
            renameError = "Use 1 to \(DisplayName.maxLength) characters."
            return
        }
        Task {
            do { try await auth.updateDisplayName(trimmed) } catch { renameError = error.localizedDescription }
        }
    }
}
