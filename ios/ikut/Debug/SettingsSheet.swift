import SwiftUI

/// The name button on Home opens this instead of going straight to the name alert: the name row (tap to rename), then
/// a Developer section whose Design language row pushes the catalog of the app's visual elements (D72).
struct SettingsSheet: View {
    /// A page pushed from a Settings row.
    enum Page: Hashable { case design }

    var name: String
    var signInMethod: SignInMethod?
    /// A trip is in Now: signing out would strand the car in it, so Sign out waits until it is left.
    var tripInNow = false
    var onRename: () -> Void
    var onSignOut: () -> Void
    var onClose: () -> Void
    /// Deletes the account (Apple's sheet, the server, this phone); nil hides Delete account.
    var onDeleteAccount: (() async -> DeleteAccount.Outcome)?
    @State private var asking = false
    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var deleteError: String?
    @State private var path = NavigationPath()

    /// `design` opens with Design language pushed, and `drill` one of its lists on top of it (launch states).
    /// `deleteDemo` opens with the delete confirmation, the working row or the try-again alert showing (launch states).
    enum DeleteDemo { case ask, working, problem }

    init(name: String, signInMethod: SignInMethod? = nil, tripInNow: Bool = false, design: Bool = false, drill: DesignDrill? = nil,
         deleteDemo: DeleteDemo? = nil, onDeleteAccount: (() async -> DeleteAccount.Outcome)? = nil,
         onRename: @escaping () -> Void, onSignOut: @escaping () -> Void = {}, onClose: @escaping () -> Void) {
        self.name = name
        self.signInMethod = signInMethod
        self.tripInNow = tripInNow
        self.onRename = onRename
        self.onSignOut = onSignOut
        self.onClose = onClose
        self.onDeleteAccount = onDeleteAccount
        _confirmingDelete = State(initialValue: deleteDemo == .ask)
        _deleting = State(initialValue: deleteDemo == .working)
        _deleteError = State(initialValue: deleteDemo == .problem ? DeleteAccount.tryAgainLine : nil)
        var path = NavigationPath()
        if design || drill != nil { path.append(Page.design) }
        if let drill { path.append(drill) }
        _path = State(initialValue: path)
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                SheetHeader(title: "Settings", onClose: onClose)
                    .disabled(deleting)
                    .padding(.horizontal, Spacing.l)
                    .padding(.top, Spacing.l)
                List {
                    Section {
                        Button(action: onRename) { LabeledContent("Your name", value: name) }
                            .foregroundStyle(.primary)
                            .accessibilityIdentifier(AXID.Debug.settingsName)
                    } header: {
                        Text("Name")
                    } footer: {
                        Text("The convoy sees this name in new trips.")
                    }
                    if let signInMethod {
                        Section {
                            LabeledContent("Account") {
                                if signInMethod == .apple { Text("Apple") } else { Text("Guest (no account)") }
                            }
                            .accessibilityIdentifier(AXID.Debug.settingsSignIn)
                            Button("Sign out", role: .destructive) { asking = true }
                                .confirmationDialog("Sign out?", isPresented: $asking, titleVisibility: .visible) {
                                    Button("Sign out", role: .destructive, action: onSignOut)
                                    Button("Stay signed in", role: .cancel) {}
                                }
                                .disabled(tripInNow)
                                .accessibilityIdentifier(AXID.Debug.settingsSignOut)
                        } footer: {
                            if tripInNow {
                                Text("Leave your current trip before you sign out.")
                            } else if signInMethod == .apple {
                                Text("Signing out clears the trips kept on this phone. Signing in with Apple again brings your name back.")
                            } else {
                                Text("A guest has no account. Signing out clears the trips kept on this phone and you start over.")
                            }
                        }
                    }
                    if signInMethod == .apple, onDeleteAccount != nil {
                        Section {
                            if deleting {
                                HStack(spacing: Spacing.m) {
                                    ProgressView()
                                    Text("Deleting your account…")
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier(AXID.Debug.settingsDeleting)
                            } else {
                                Button("Delete account", role: .destructive) { confirmingDelete = true }
                                    .confirmationDialog("Delete your account?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                                        Button("Delete account", role: .destructive, action: deleteAfterDialog)
                                        Button("Keep my account", role: .cancel) {}
                                    } message: {
                                        if tripInNow {
                                            Text("This removes your name and your cars from every trip, and what you posted. You’ll leave the trip you’re in now. If you organise it, it’s handed to someone else or ended. It can’t be undone. Apple will ask you to confirm it’s you.")
                                        } else {
                                            Text("This removes your name and your cars from every trip, and what you posted. Trips you organise are handed to someone else, or ended if nobody else is in them. It can’t be undone. Apple will ask you to confirm it’s you.")
                                        }
                                    }
                                    .accessibilityIdentifier(AXID.Debug.settingsDeleteAccount)
                            }
                        } footer: {
                            Text("Removes your name and cars from every trip. This can’t be undone.")
                        }
                    }
                    Section("Developer") {
                        NavigationLink("Design language", value: Page.design)
                            .accessibilityIdentifier(AXID.Debug.settingsDesign)
                    }
                }
                .listStyle(.insetGrouped)
                .disabled(deleting)
            }
            .alert("Your account is still here", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
                Button("Try again", action: deleteAccount)
                Button("Not now", role: .cancel) {}
            } message: {
                Text(deleteError ?? "")
            }
            .interactiveDismissDisabled(deleting)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Page.self) { _ in
                DesignLanguageView()
                    .navigationTitle("Design language")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .navigationDestination(for: DesignDrill.self) { DesignDrillView(drill: $0) }
        }
    }

    /// Apple's sheet first; a closed sheet changes nothing. A step that doesn't go through leaves the person signed in.
    /// Apple's sheet comes after the dialog has finished closing, not while it is still leaving.
    private func deleteAfterDialog() {
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            deleteAccount()
        }
    }

    private func deleteAccount() {
        guard let onDeleteAccount, !deleting else { return }
        deleting = true
        Task {
            let outcome = await onDeleteAccount()
            deleting = false
            switch outcome {
            case .deleted: onClose()
            case .cancelled: break
            case .failed(let line): deleteError = line
            }
        }
    }
}
