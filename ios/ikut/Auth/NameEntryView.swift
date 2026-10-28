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

    #if DEBUG
    /// Launch states `name-entry-error` (the sign-in problem line) and `name-entry-signing-in` (the spinner on Continue).
    init(demo: String) {
        onDone = {}
        _name = State(initialValue: "Nurul")
        _isWorking = State(initialValue: demo == "signing-in")
        _errorMessage = State(initialValue: demo == "error" ? "Couldn’t sign you in. Check your signal and try again." : nil)
    }
    #endif

    private var isValid: Bool {
        if case .success = DisplayName.validate(name) { true } else { false }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("What should the convoy call you?")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, Spacing.l)

                NameFieldCard(name: $name, focused: $focused, disabled: isWorking, onSubmit: submit)
                    .onChange(of: name) { errorMessage = nil }

                if let errorMessage {
                    InlineNote(errorMessage, tone: .alert)
                        .padding(.top, Spacing.s)
                        .accessibilityIdentifier("nameError")
                }

                Spacer(minLength: 16)

                Button(action: submit) {
                    if isWorking {
                        ProgressView().accessibilityLabel("Signing in").frame(maxWidth: .infinity)
                    } else {
                        Text("Continue").frame(maxWidth: .infinity)
                    }
                }
                .actionButton(.primary)
                .disabled(!isValid || isWorking)
            }
            .padding(Spacing.l)
            .background(Color.ikutScreen)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isWorking)
                }
            }
        }
        // Like Cancel: a swipe or a tap outside mid sign-in would drop the Create or Join that follows.
        .interactiveDismissDisabled(isWorking)
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

/// "Your name" and its field, as on the name sheet and the join sheet's first step (H1).
struct NameFieldCard: View {
    @Binding var name: String
    var focused: FocusState<Bool>.Binding
    var disabled = false
    var onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader("Your name", top: Spacing.sectionLarge)
                .accessibilityHidden(true)
            TextField("Your name", text: $name)
                .textContentType(.givenName)
                .textInputAutocapitalization(.words)
                .submitLabel(.continue)
                .focused(focused)
                .disabled(disabled)
                .padding(.horizontal, Spacing.l)
                .frame(minHeight: 50)
                .ikutCard()
                .accessibilityLabel("Your name")
                .accessibilityIdentifier("nameField")
                .onSubmit(onSubmit)
        }
    }
}

#Preview {
    NameEntryView()
        .environment(AuthModel())
}
