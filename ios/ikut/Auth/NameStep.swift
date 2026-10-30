import Observation
import SwiftUI

/// The name step's state and rows, shared by joining (`JoinSheet`, D58) and by Where to? for someone signed out
/// (`NameStepSheet`, D112), so the typing, the sign-in spinner and the error line behave the same in both.
@MainActor @Observable
final class NameStepState {
    var name: String
    /// The name is being signed in.
    var isWorking = false
    /// The line under the field when sign-in didn't work; cleared by the next edit.
    var error: String?

    init(name: String = "") { self.name = name }

    var isValid: Bool { Self.isValid(name) }

    nonisolated static func isValid(_ name: String) -> Bool {
        if case .success = DisplayName.validate(name) { true } else { false }
    }

    /// Signs in with `name`: nil when it worked, else the line to show.
    static func attempt(name: String, signIn: (String) async throws -> Void) async -> String? {
        do {
            try await signIn(name)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Continue: true once signed in. The spinner stays up then, for whatever comes next to replace the step (iOS's
    /// location prompt may come first); a failure puts the error up and the Continue button back.
    func submit(signIn: (String) async throws -> Void) async -> Bool {
        guard isValid, !isWorking else { return false }
        isWorking = true
        error = nil
        if let line = await Self.attempt(name: name, signIn: signIn) {
            error = line
            isWorking = false
            return false
        }
        return true
    }
}

/// The name field with its lines and the sign-in error, as the rows of a list.
struct NameStepSections: View {
    @Binding var name: String
    var isWorking: Bool
    var error: String?
    var footer: LocalizedStringKey
    var focused: FocusState<Bool>.Binding
    var onSubmit: () -> Void

    var body: some View {
        Section {
            TextField("Your name", text: $name)
                .textContentType(.givenName)
                .textInputAutocapitalization(.words)
                .submitLabel(.continue)
                .focused(focused)
                .disabled(isWorking)
                .accessibilityLabel("Your name")
                .accessibilityIdentifier(AXID.Name.field)
                .onSubmit(onSubmit)
        } header: {
            // The line and the caption share the header, so the field stays as high as it was above the keyboard.
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("Drive together. Arrive together.")
                    .font(.title3).foregroundStyle(.secondary).textCase(nil)
                Text("Your name").accessibilityHidden(true)
            }
        } footer: {
            Text(footer)
        }
        if let error {
            Section {
                InlineNote(.verbatim(error), tone: .alert, inset: 0)
                    .lobbyRow()
                    .accessibilityIdentifier(AXID.Name.error)
            }
        }
    }
}

/// The name step's one button: the sign-in spinner while it works.
struct NameStepButton: View {
    var isWorking: Bool
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isWorking { ProgressView().accessibilityLabel("Signing in") } else { Text("Get started") }
            }
            .font(.headline).frame(maxWidth: .infinity)
        }
        .ikutButton(.primary, tint: .ikutAccentFill)
        .disabled(!enabled || isWorking)
        .accessibilityIdentifier(AXID.Join.nameContinue)
        .sheetActionBar(sides: false)
        .padding(.bottom, PanelSheet.sideGap)
    }
}

/// The name as the first step of Where to? in Home's one sheet (D112): the same step joining opens with, with Close
/// back to the list. `onSignedIn` runs once the name is signed in; the caller carries on to Where to?.
struct NameStepSheet: View {
    @Environment(AuthModel.self) private var auth
    @Bindable var step: NameStepState
    var onClose: () -> Void
    var onSignedIn: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetTopRow(title: "Welcome to ikut") {
                EmptyView()
            } trailing: {
                RoundGlassIconButton(systemImage: Symbol.close, label: "Close", action: onClose)
                    .accessibilityIdentifier(AXID.Sheet.close).disabled(step.isWorking)
            }
            .padding(.top, Spacing.xs)
            .padding(.horizontal, Spacing.l)

            List {
                NameStepSections(name: $step.name, isWorking: step.isWorking, error: step.error,
                                 footer: "What the convoy sees in new trips. Starting a trip needs only a name, no account.",
                                 focused: $focused, onSubmit: submit)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .contentMargins(.bottom, Spacing.l, for: .scrollContent)
            .onChange(of: step.name) { step.error = nil }

            NameStepButton(isWorking: step.isWorking, enabled: step.isValid, action: submit)
                .padding(.horizontal, Spacing.l)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .environment(\.inPanelSheet, true)
        .buttonSurface(.glass)
        .task {
            if step.name.isEmpty { step.name = auth.displayName ?? "" }
            focused = true
        }
    }

    private func submit() {
        Task {
            if await step.submit(signIn: { try await auth.signInAsGuest(name: $0) }) { onSignedIn() }
        }
    }
}
