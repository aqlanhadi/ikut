import AuthenticationServices
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

/// What the Apple button tells the step it sits in.
struct AppleStepActions {
    /// Apple's sheet or the Firebase sign-in is running (true) or done (false): the step shows its spinner.
    var working: (Bool) -> Void
    /// Signed in, with the profile's name: carry on.
    var signedIn: (String) -> Void
    /// The line to show under the field: a problem, or that the name is still needed.
    var line: (String) -> Void
}

/// "Continue with Apple" (Apple's own button, system sizing). Asks for the name, signs in with Firebase with a fresh
/// nonce each time (raw one to Firebase, its SHA256 to Apple), and reports to the step through `actions`.
struct AppleSignInButton: View {
    @Environment(AuthModel.self) private var auth
    @Environment(\.colorScheme) private var scheme
    var actions: AppleStepActions
    var disabled: Bool
    @State private var rawNonce = ""

    /// Whether this build carries the Sign in with Apple entitlement (`IKUT_SIWA`, from project.yml).
    static var isAvailable: Bool {
        #if IKUT_SIWA
        true
        #else
        false
        #endif
    }

    /// The needs-a-name line is a nudge, not a problem, so it isn't drawn in the alert colour.
    static func tone(for line: String) -> InlineNote.Tone { line == needsNameLine ? .hint : .alert }

    static let needsNameLine = "Apple didn’t share your name. Add the name the convoy should see."

    var body: some View {
        SignInWithAppleButton(.continue) { request in
            rawNonce = AppleSignIn.randomNonce()
            request.requestedScopes = [.fullName]
            request.nonce = AppleSignIn.sha256(rawNonce)
        } onCompletion: { result in
            finish(result)
        }
        .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
        .disabled(disabled)
        .accessibilityIdentifier(AXID.Name.apple)
    }

    private func finish(_ result: Result<ASAuthorization, Error>) {
        if case .failure(let error) = result, AppleSignIn.isCancelled(error) { return }
        actions.working(true)
        Task {
            do {
                switch try await auth.signInWithApple(result, rawNonce: rawNonce) {
                case .signedIn(let name):
                    // The spinner stays up, for whatever comes next to replace the step.
                    actions.signedIn(name)
                    return
                case .needsName:
                    actions.line(Self.needsNameLine)
                case .cancelled:
                    break
                }
            } catch {
                actions.line(AppleSignIn.Problem.line)
            }
            actions.working(false)
        }
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
    /// Nil leaves the step as a name only.
    var apple: AppleStepActions?

    private var showsApple: Bool { apple != nil && AppleSignInButton.isAvailable }

    var body: some View {
        if let apple, AppleSignInButton.isAvailable {
            Section {
                AppleSignInButton(actions: apple, disabled: isWorking)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } header: {
                Text("Drive together. Arrive together.")
                    .font(.title3).foregroundStyle(.secondary).textCase(nil)
            }
        }
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
                if !showsApple {
                    Text("Drive together. Arrive together.")
                        .font(.title3).foregroundStyle(.secondary).textCase(nil)
                }
                if !showsApple {
                    Text("Your name").accessibilityHidden(true)
                } else {
                    Text("Just use a name").accessibilityHidden(true)
                }
            }
        } footer: {
            Text(footer)
        }
        if let error {
            Section {
                InlineNote(.verbatim(error), tone: AppleSignInButton.tone(for: error), inset: 0)
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
