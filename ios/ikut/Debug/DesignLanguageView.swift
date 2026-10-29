import SwiftUI

/// Where a drill-down from the One-offs totals goes.
enum DesignDrill: Hashable {
    case views
    case literals(InventoryCategory)
}

/// Settings > Design: what `UI/` shares, drawn live, then the one-offs `tools/design-inventory.mjs` found (D72).
struct DesignLanguageView: View {
    var body: some View {
        List {
            DesignSharedSection()
            DesignOneOffsSection()
        }
        .accessibilityIdentifier("designLanguage")
    }
}

// MARK: One-offs

private struct DesignOneOffsSection: View {
    var body: some View {
        let literals = DesignInventory.literals
        Section {
            NavigationLink(value: DesignDrill.views) { Text(InventoryGroups.totals(DesignInventory.views)) }
                .accessibilityIdentifier("designDrill.views")
            ForEach(InventoryCategory.allCases, id: \.self) { category in
                NavigationLink(value: DesignDrill.literals(category)) {
                    Text(InventoryGroups.totals(literals, in: category))
                }
                .accessibilityIdentifier("designDrill.\(category.rawValue)")
            }
        } header: {
            Text("One-offs")
        } footer: {
            Text("Found by tools/design-inventory.mjs; rerun it after a merge to refresh.\n\(InventoryGroups.sharedTotal(literals))")
        }
    }
}

/// The pushed list: every custom view, or every value of one kind of literal with where it is written.
struct DesignDrillView: View {
    var drill: DesignDrill

    var body: some View {
        List {
            switch drill {
            case .views: viewList
            case .literals(let category): literalList(category)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private var title: String {
        switch drill {
        case .views: "Custom views"
        case .literals(let category): category.title
        }
    }

    private var viewList: some View {
        let views = DesignInventory.views
        return Section {
            ForEach(Array(views.enumerated()), id: \.offset) { _, view in
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(view.name).font(.body.monospaced())
                    Text("\(view.kind) in \(view.file)").font(.footnote).foregroundStyle(.secondary)
                    Text(InventoryGroups.usage(view)).font(.footnote)
                        .foregroundStyle(view.uses <= 1 ? Color.ikutWarning : Color.ikutPositive)
                }
            }
        } header: {
            Text(InventoryGroups.totals(views))
        } footer: {
            Text(InventoryGroups.viewsNote)
        }
    }

    private func literalList(_ category: InventoryCategory) -> some View {
        let literals = DesignInventory.literals
        let groups = InventoryGroups.groups(literals, in: category)
        return Section {
            ForEach(groups) { group in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        ForEach(Array(group.places.enumerated()), id: \.offset) { _, place in
                            Text(place).font(.footnote.monospaced()).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } label: {
                    HStack(spacing: Spacing.m) {
                        sample(group, category)
                        Spacer(minLength: Spacing.s)
                        Text("\(group.count)×").foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text(InventoryGroups.totals(literals, in: category))
        }
    }

    /// The value itself: the text at that size, the colour, or just the number.
    @ViewBuilder
    private func sample(_ group: LiteralGroup, _ category: InventoryCategory) -> some View {
        switch category {
        case .font:
            Text("\(group.value) pt  Aa 123").font(.system(size: Double(group.value) ?? 17))
        case .color:
            HStack(spacing: Spacing.m) {
                RoundedRectangle(cornerRadius: Radius.icon, style: .continuous)
                    .fill(group.swatch.flatMap { Color(hex: $0) } ?? .clear)
                    .overlay(RoundedRectangle(cornerRadius: Radius.icon, style: .continuous).strokeBorder(.quaternary))
                    .frame(width: 32, height: 32)
                Text(group.value).font(.body.monospaced())
            }
        default:
            Text(group.value).font(.body.monospaced())
        }
    }
}
