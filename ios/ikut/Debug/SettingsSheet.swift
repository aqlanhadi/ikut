import SwiftUI

/// The name button on Home opens this instead of going straight to the name alert: the name row (tap to rename), then
/// a Developer section whose Design language row pushes the catalog of the app's visual elements (D72).
struct SettingsSheet: View {
    /// A page pushed from a Settings row.
    enum Page: Hashable { case design }

    var name: String
    var onRename: () -> Void
    var onClose: () -> Void
    @State private var path = NavigationPath()

    /// `design` opens with Design language pushed, and `drill` one of its lists on top of it (launch states).
    init(name: String, design: Bool = false, drill: DesignDrill? = nil, onRename: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        self.name = name
        self.onRename = onRename
        self.onClose = onClose
        var path = NavigationPath()
        if design || drill != nil { path.append(Page.design) }
        if let drill { path.append(drill) }
        _path = State(initialValue: path)
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: "Settings", onClose: onClose)
                CardHeader("Name")
                Button(action: onRename) { row("Your name", value: name) }
                    .buttonStyle(.plain)
                    .ikutCard()
                    .accessibilityIdentifier("settingsName")
                InlineNote("The convoy sees this name in new trips.").padding(.top, Spacing.s)
                CardHeader("Developer", top: Spacing.xl)
                NavigationLink(value: Page.design) { row("Design language") }
                    .buttonStyle(.plain)
                    .ikutCard()
                    .accessibilityIdentifier("settingsDesign")
            }
            .padding(.horizontal, Spacing.screenMargin)
            .padding(.top, Spacing.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.ikutScreen)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Page.self) { _ in
                DesignLanguageView()
                    .padding(.horizontal, Spacing.screenMargin)
                    .background(Color.ikutScreen)
                    .navigationTitle("Design language")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .navigationDestination(for: DesignDrill.self) { DesignDrillView(drill: $0) }
        }
    }

    private func row(_ title: String, value: String? = nil) -> some View {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer()
            if let value { Text(value).foregroundStyle(.secondary) }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Spacing.l)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}
