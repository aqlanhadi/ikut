import SwiftUI

/// Asks a joiner for the name other cars will see, then signs them in as a guest.
struct NameEntryView: View {
    @Environment(AuthModel.self) private var auth
    @State private var name = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var isValid: Bool {
        if case .success = DisplayName.validate(name) { true } else { false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What should the convoy call you?")
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)

            TextField("Your name", text: $name)
                .textContentType(.givenName)
                .textInputAutocapitalization(.words)
                .submitLabel(.continue)
                .textFieldStyle(.roundedBorder)
                .disabled(isWorking)
                .accessibilityLabel("Your name")
                .onSubmit(submit)
                .onChange(of: name) { errorMessage = nil }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Error: \(errorMessage)")
            }

            Button(action: submit) {
                Group {
                    if isWorking {
                        ProgressView().accessibilityLabel("Signing in")
                    } else {
                        Text("Continue")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!isValid || isWorking)
        }
        .padding()
    }

    private func submit() {
        guard isValid, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await auth.signInAsGuest(name: name)
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

#Preview {
    NameEntryView()
        .environment(AuthModel())
}
