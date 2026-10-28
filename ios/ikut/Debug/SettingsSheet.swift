#if DEBUG
import SwiftUI

/// Debug builds only: the name button on Home opens this instead of going straight to the name alert. "You" is the
/// name row (tap to rename); "Design" is the catalog of the app's visual elements (D72).
struct SettingsSheet: View {
    enum Tab: String, CaseIterable { case you = "You", design = "Design" }

    var name: String
    var onRename: () -> Void
    var onClose: () -> Void
    @State var tab: Tab = .you
    @State private var path: [DesignDrill] = []

    init(name: String, tab: Tab = .you, drill: DesignDrill? = nil, onRename: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.name = name
        self.onRename = onRename
        self.onClose = onClose
        _tab = State(initialValue: tab)
        _path = State(initialValue: drill.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: Spacing.m) {
                SheetHeader(title: "Settings", onClose: onClose)
                Picker("Settings", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settingsTabs")
                switch tab {
                case .you: youTab
                case .design: DesignLanguageView()
                }
            }
            .padding(.horizontal, Spacing.screenMargin)
            .padding(.top, Spacing.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.ikutScreen)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: DesignDrill.self) { DesignDrillView(drill: $0) }
        }
    }

    private var youTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader("Name")
            Button(action: onRename) {
                HStack {
                    Text("Your name").foregroundStyle(.primary)
                    Spacer()
                    Text(name).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, Spacing.l)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .ikutCard()
            .accessibilityIdentifier("settingsName")
            InlineNote("Everyone in the trip sees this name.").padding(.top, Spacing.s)
        }
    }
}
#endif
