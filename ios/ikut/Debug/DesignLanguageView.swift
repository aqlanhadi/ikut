#if DEBUG
import SwiftUI

/// Where a drill-down from the One-offs totals goes.
enum DesignDrill: Hashable {
    case views
    case literals(InventoryCategory)
}

/// Settings > Design: what `UI/` shares, drawn live, then the one-offs `tools/design-inventory.mjs` found (D72).
struct DesignLanguageView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DesignSharedSection()
                DesignOneOffsSection()
            }
            .padding(.bottom, Spacing.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("designLanguage")
    }
}

// MARK: One-offs

private struct DesignOneOffsSection: View {
    var body: some View {
        let literals = DesignInventory.literals
        VStack(alignment: .leading, spacing: 0) {
            CardHeader("One-offs", top: Spacing.xl)
            InlineNote("Found by tools/design-inventory.mjs; rerun it after a merge to refresh.").padding(.bottom, Spacing.s)
            VStack(spacing: 0) {
                NavigationLink(value: DesignDrill.views) { totalsRow(InventoryGroups.totals(DesignInventory.views)) }
                    .accessibilityIdentifier("designDrill.views")
                ForEach(InventoryCategory.allCases, id: \.self) { category in
                    RowDivider()
                    NavigationLink(value: DesignDrill.literals(category)) {
                        totalsRow(InventoryGroups.totals(literals, in: category))
                    }
                    .accessibilityIdentifier("designDrill.\(category.rawValue)")
                }
            }
            .ikutCard()
        }
    }

    private func totalsRow(_ text: String) -> some View {
        HStack {
            Text(text).foregroundStyle(.primary).multilineTextAlignment(.leading)
            Spacer(minLength: Spacing.s)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Spacing.l)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }
}

/// The pushed list: every custom view, or every value of one kind of literal with where it is written.
struct DesignDrillView: View {
    var drill: DesignDrill

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch drill {
                case .views: viewList
                case .literals(let category): literalList(category)
                }
            }
            .padding(.horizontal, Spacing.screenMargin)
            .padding(.bottom, Spacing.xl)
        }
        .background(Color.ikutScreen)
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
        return VStack(alignment: .leading, spacing: 0) {
            InlineNote(InventoryGroups.totals(views)).padding(.vertical, Spacing.s)
            VStack(spacing: 0) {
                ForEach(Array(views.enumerated()), id: \.offset) { index, view in
                    if index > 0 { RowDivider() }
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(view.name).font(.body.monospaced())
                        Text("\(view.kind) in \(view.file)").font(.footnote).foregroundStyle(.secondary)
                        Text(InventoryGroups.usage(view)).font(.footnote)
                            .foregroundStyle(view.usedIn <= 1 ? Color.ikutWarning : Color.ikutPositive)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.l)
                    .padding(.vertical, Spacing.m)
                }
            }
            .ikutCard()
        }
    }

    private func literalList(_ category: InventoryCategory) -> some View {
        let literals = DesignInventory.literals
        let groups = InventoryGroups.groups(literals, in: category)
        return VStack(alignment: .leading, spacing: 0) {
            InlineNote(InventoryGroups.totals(literals, in: category)).padding(.vertical, Spacing.s)
            ForEach(groups) { group in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        ForEach(Array(group.places.enumerated()), id: \.offset) { _, place in
                            Text(place).font(.footnote.monospaced()).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, Spacing.xs)
                } label: {
                    HStack(spacing: Spacing.m) {
                        sample(group, category)
                        Spacer(minLength: Spacing.s)
                        Text("\(group.count)×").foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.s)
                .ikutCard(radius: Radius.control)
                .padding(.bottom, Spacing.s)
            }
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
#endif
