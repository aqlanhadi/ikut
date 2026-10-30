import Observation
import SwiftUI

/// The name step's state and rows, shared by joining (`JoinSheet`, D58) and by Where to? for someone signed out
/// (`TripsHomeView.nameStepSheet`, D112), so the typing, the sign-in spinner and the error line behave the same in both.
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
