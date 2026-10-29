import Foundation

/// A View or ViewModifier struct outside `UI/` and how many other files mention it.
struct InventoryView: Equatable, Sendable {
    var name: String
    var kind: String
    var file: String
    var uses: Int
}

/// The kinds of literal `tools/design-inventory.mjs` records.
enum InventoryCategory: String, CaseIterable, Sendable {
    case font, color, opacity, padding, radius, frame

    /// "literal font sizes": the phrase after a count in the totals row.
    var plural: String {
        switch self {
        case .font: "literal font sizes"
        case .color: "raw colours"
        case .opacity: "literal opacities"
        case .padding: "literal paddings"
        case .radius: "literal corner radii"
        case .frame: "literal frame sizes"
        }
    }

    var title: String {
        switch self {
        case .font: "Font sizes"
        case .color: "Colours"
        case .opacity: "Opacities"
        case .padding: "Paddings"
        case .radius: "Corner radii"
        case .frame: "Frame sizes"
        }
    }
}

struct InventoryLiteral: Equatable, Sendable {
    var category: InventoryCategory
    var value: String
    /// RRGGBB, for colours.
    var swatch: String?
    /// "Trips/TripsHomeView.swift:42"
    var place: String
    /// Written in `UI/`, the shared layer: not a one-off.
    var isShared: Bool { place.hasPrefix("UI/") }
}

/// All the places one value is written.
struct LiteralGroup: Equatable, Identifiable, Sendable {
    var value: String
    var swatch: String?
    var places: [String]
    var id: String { value }
    var count: Int { places.count }
}

enum InventoryParser {
    static func views(_ rows: String) -> [InventoryView] {
        rows.split(separator: "\n").compactMap { row in
            let f = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, let used = Int(f[3]) else { return nil }
            return InventoryView(name: f[0], kind: f[1], file: f[2], uses: used)
        }
    }

    static func literals(_ rows: String) -> [InventoryLiteral] {
        rows.split(separator: "\n").compactMap { row in
            let f = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, let category = InventoryCategory(rawValue: f[0]) else { return nil }
            return InventoryLiteral(category: category, value: f[1], swatch: f[2].isEmpty ? nil : f[2], place: f[3])
        }
    }
}

enum InventoryGroups {
    /// One group per distinct value in `category`, smallest number first (so 13 and 14 sit side by side), then by
    /// name; each group's places keep the file order.
    static func groups(_ literals: [InventoryLiteral], in category: InventoryCategory) -> [LiteralGroup] {
        var order: [String] = []
        var byValue: [String: LiteralGroup] = [:]
        for l in literals where l.category == category && !l.isShared {
            if byValue[l.value] == nil {
                order.append(l.value)
                byValue[l.value] = LiteralGroup(value: l.value, swatch: l.swatch, places: [])
            }
            byValue[l.value]?.places.append(l.place)
        }
        return order.compactMap { byValue[$0] }.sorted { a, b in
            let (x, y) = (leadingNumber(a.value), leadingNumber(b.value))
            if x != y { return x < y }
            return a.value < b.value
        }
    }

    static func leadingNumber(_ value: String) -> Double {
        let word = value.split(separator: " ").first.map(String.init) ?? value
        return Double(word) ?? Double(value.split(separator: " ").dropFirst().first.map(String.init) ?? "") ?? .infinity
    }

    /// "27 literal font sizes, 11 distinct"
    static func totals(_ literals: [InventoryLiteral], in category: InventoryCategory) -> String {
        let total = literals.filter { $0.category == category && !$0.isShared }.count
        let distinct = groups(literals, in: category).count
        return "\(total) \(category.plural), \(distinct) distinct"
    }

    /// "83 custom views, 53 used once or not at all"
    static func totals(_ views: [InventoryView]) -> String {
        "\(views.count) custom views, \(views.filter { $0.uses <= 1 }.count) used once or not at all"
    }

    /// "15 literals inside the shared components (UI/)": counted apart, not one-offs.
    static func sharedTotal(_ literals: [InventoryLiteral]) -> String {
        "\(literals.filter(\.isShared).count) literals inside the shared components (UI/), not counted above"
    }

    static let viewsNote = "Counts each place a view's name is written in the app, not its own declaration, and not demos, previews or Debug code."

    /// What a view's row says.
    static func usage(_ view: InventoryView) -> String {
        switch view.uses {
        case 0: "Not used anywhere"
        case 1: "Used once"
        default: "Used \(view.uses) times"
        }
    }
}

extension DesignInventory {
    static var views: [InventoryView] { InventoryParser.views(viewRows) }
    static var literals: [InventoryLiteral] { InventoryParser.literals(literalRows) }
}

/// D77: the ratchet. The inventory's ad hoc counts may only go down; the ceilings are in `DesignCeiling`.
struct InventoryCounts: Equatable, Sendable {
    var byCategory: [InventoryCategory: Int]
    var viewsUsedOnce: Int

    init(byCategory: [InventoryCategory: Int], viewsUsedOnce: Int) {
        self.byCategory = byCategory
        self.viewsUsedOnce = viewsUsedOnce
    }

    init(literals: [InventoryLiteral], views: [InventoryView]) {
        var counts: [InventoryCategory: Int] = [:]
        for c in InventoryCategory.allCases { counts[c] = literals.filter { $0.category == c && !$0.isShared }.count }
        self.init(byCategory: counts, viewsUsedOnce: views.filter { $0.uses <= 1 }.count)
    }

    static var ceiling: InventoryCounts {
        InventoryCounts(byCategory: [
            .font: DesignCeiling.font, .color: DesignCeiling.color, .opacity: DesignCeiling.opacity,
            .padding: DesignCeiling.padding, .radius: DesignCeiling.radius, .frame: DesignCeiling.frame,
        ], viewsUsedOnce: DesignCeiling.viewsUsedOnce)
    }

    /// One line per count above its ceiling; empty when the inventory has not grown.
    func exceeding(_ ceiling: InventoryCounts) -> [String] {
        var out: [String] = []
        for c in InventoryCategory.allCases {
            let (n, max) = (byCategory[c] ?? 0, ceiling.byCategory[c] ?? 0)
            if n > max { out.append("\(c.rawValue): \(n) is above the ceiling of \(max)") }
        }
        if viewsUsedOnce > ceiling.viewsUsedOnce {
            out.append("views used once or not at all: \(viewsUsedOnce) is above the ceiling of \(ceiling.viewsUsedOnce)")
        }
        return out
    }
}

/// D78: the token ratchet. How many tokens the shared look defines (spacing, corner radii, shadows, tint fills,
/// colours), parsed by `tools/design-inventory.mjs` into `DesignInventory.tokenRows`. It may only go down; the
/// ceilings are in `TokenCeiling`.
struct TokenCounts: Equatable, Sendable {
    static let groups = ["spacing", "radius", "elevation", "tintFill", "colour"]
    var byGroup: [String: Int]

    /// `rows` is `group|name` per line.
    init(rows: String) {
        var counts: [String: Int] = [:]
        for line in rows.split(separator: "\n") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            counts[String(parts[0]), default: 0] += 1
        }
        byGroup = counts
    }

    init(byGroup: [String: Int]) { self.byGroup = byGroup }

    static var now: TokenCounts { TokenCounts(rows: DesignInventory.tokenRows) }

    static var ceiling: TokenCounts {
        TokenCounts(byGroup: [
            "spacing": TokenCeiling.spacing, "radius": TokenCeiling.radius, "elevation": TokenCeiling.elevation,
            "tintFill": TokenCeiling.tintFill, "colour": TokenCeiling.colour,
        ])
    }

    /// One line per group above its ceiling; empty when no scale has grown.
    func exceeding(_ ceiling: TokenCounts) -> [String] {
        Self.groups.compactMap { g in
            let (n, max) = (byGroup[g] ?? 0, ceiling.byGroup[g] ?? 0)
            return n > max ? "\(g): \(n) tokens is above the ceiling of \(max)" : nil
        }
    }
}
