import SwiftUI

/// The name button on Home opens this instead of going straight to the name alert: the name row (tap to rename), then
/// a Developer section whose Design language row pushes the catalog of the app's visual elements (D72).
struct SettingsSheet: View {
    /// A page pushed from a Settings row.
    enum Page: Hashable { case design }

    var name: String
    var signInMethod: SignInMethod?
    var onRename: () -> Void
    var onSignOut: () -> Void
    var onClose: () -> Void
    @State private var asking = false
    @State private var path = NavigationPath()

    /// `design` opens with Design language pushed, and `drill` one of its lists on top of it (launch states).
    init(name: String, signInMethod: SignInMethod? = nil, design: Bool = false, drill: DesignDrill? = nil,
         onRename: @escaping () -> Void, onSignOut: @escaping () -> Void = {}, onClose: @escaping () -> Void) {
        self.name = name
        self.signInMethod = signInMethod
        self.onRename = onRename
        self.onSignOut = onSignOut
        self.onClose = onClose
        var path = NavigationPath()
        if design || drill != nil { path.append(Page.design) }
        if let drill { path.append(drill) }
        _path = State(initialValue: path)
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                SheetHeader(title: "Settings", onClose: onClose)
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
                            LabeledContent("Signed in with", value: signInMethod == .apple ? "Apple" : "Guest")
                                .accessibilityIdentifier(AXID.Debug.settingsSignIn)
                            Button("Sign out", role: .destructive) { asking = true }
                                .accessibilityIdentifier(AXID.Debug.settingsSignOut)
                        } header: {
                            Text("Account")
                        } footer: {
                            if signInMethod == .apple {
                                Text("Sign in with Apple again to get your trips back.")
                            } else {
                                Text("A guest has no account, so signing out starts you over with no trips.")
                            }
                        }
                    }
                    Section("Developer") {
                        NavigationLink("Design language", value: Page.design)
                            .accessibilityIdentifier(AXID.Debug.settingsDesign)
                    }
                }
                .listStyle(.insetGrouped)
            }
            .confirmationDialog("Sign out?", isPresented: $asking, titleVisibility: .visible) {
                Button("Sign out", role: .destructive, action: onSignOut)
                Button("Stay signed in", role: .cancel) {}
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Page.self) { _ in
                DesignLanguageView()
                    .navigationTitle("Design language")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .navigationDestination(for: DesignDrill.self) { DesignDrillView(drill: $0) }
        }
    }
}
