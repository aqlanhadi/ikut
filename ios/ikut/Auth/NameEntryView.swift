import SwiftUI

/// Sheet that asks for the name other cars will see, then signs the person in as a guest.
/// `onDone` runs after sign-in succeeds so the caller can carry on to Create or Join.
struct NameEntryView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool
    var onDone: () -> Void

    init(onDone: @escaping () -> Void = {}) {
        self.onDone = onDone
    }

    private var isValid: Bool {
        if case .success = DisplayName.validate(name) { true } else { false }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("What should the convoy call you?")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 16)

                Text("Your name")
                    .font(.footnote).foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 16).padding(.top, 22).padding(.bottom, 6)
                    .accessibilityHidden(true)
                TextField("Your name", text: $name)
                    .textContentType(.givenName)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.continue)
                    .focused($focused)
                    .disabled(isWorking)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 50)
                    .ikutCard()
                    .accessibilityLabel("Your name")
                    .onSubmit(submit)
                    .onChange(of: name) { errorMessage = nil }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16).padding(.top, 8)
                        .accessibilityLabel("Error: \(errorMessage)")
                }

                Spacer(minLength: 16)

                Button(action: submit) {
                    if isWorking {
                        ProgressView().accessibilityLabel("Signing in")
                    } else {
                        Text("Continue")
                    }
                }
                .buttonStyle(PillButtonStyle())
                .disabled(!isValid || isWorking)
            }
            .padding(16)
            .background(Color.ikutScreen)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isWorking)
                }
            }
        }
        .onAppear { focused = true }
    }

    private func submit() {
        guard isValid, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await auth.signInAsGuest(name: name)
                isWorking = false
                onDone()
            } catch {
                errorMessage = error.localizedDescription
                isWorking = false
            }
        }
    }
}

#Preview {
    NameEntryView()
        .environment(AuthModel())
}
