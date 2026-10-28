#if DEBUG
import Foundation

/// A View or ViewModifier struct outside `UI/` and how many other files mention it.
struct InventoryView: Equatable, Sendable {
    var name: String
    var kind: String
    var file: String
    var usedIn: Int
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
            return InventoryView(name: f[0], kind: f[1], file: f[2], usedIn: used)
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
        for l in literals where l.category == category {
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
        let total = literals.filter { $0.category == category }.count
        let distinct = groups(literals, in: category).count
        return "\(total) \(category.plural), \(distinct) distinct"
    }

    /// "93 custom views, 70 used in one file or none"
    static func totals(_ views: [InventoryView]) -> String {
        "\(views.count) custom views, \(views.filter { $0.usedIn <= 1 }.count) used in one file or none"
    }

    /// "Not reused" / "Used in 3 files": what a view's row says.
    static func usage(_ view: InventoryView) -> String {
        switch view.usedIn {
        case 0: "Only in its own file"
        case 1: "Used in 1 other file"
        default: "Used in \(view.usedIn) other files"
        }
    }
}

extension DesignInventory {
    static var views: [InventoryView] { InventoryParser.views(viewRows) }
    static var literals: [InventoryLiteral] { InventoryParser.literals(literalRows) }
}
#endif
