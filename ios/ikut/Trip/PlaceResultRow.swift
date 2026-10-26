import MapKit
import SwiftUI

/// One search line: its kind's icon, name (the typed part in bold for a suggestion) and subtitle, then whatever
/// `trailing` says (a distance, a spinner). Shared by Where to?, Change destination and Add a stop.
struct PlaceResultRow<Trailing: View>: View {
    var title: AttributedString
    var subtitle: String
    var symbol: String
    var color: Color
    var label: String
    var disabled = false
    var action: () -> Void
    @ViewBuilder var trailing: Trailing
    @Environment(\.inPanelSheet) private var inSheet

    init(result: DestinationResult, disabled: Bool = false, action: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing) {
        let kind = PlaceKind(result)
        title = AttributedString(result.name)
        subtitle = result.subtitle
        (symbol, color) = (kind.symbol, kind.color)
        label = [result.name, result.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
        self.disabled = disabled
        self.action = action
        self.trailing = trailing()
    }

    /// A pasted pin: a pin icon, its name, "Dropped pin" and the coordinates under it.
    init(pin: DestinationResult, disabled: Bool = false, action: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing) {
        title = AttributedString(pin.name)
        subtitle = "Dropped pin · \(pin.subtitle)"
        (symbol, color) = ("mappin", .red)
        label = "Dropped pin, \(pin.name), \(pin.subtitle)"
        self.disabled = disabled
        self.action = action
        self.trailing = trailing()
    }

    /// A plain action row, like "Choose on map".
    init(action title: String, symbol: String, color: Color, disabled: Bool = false, action: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing) {
        self.title = AttributedString(title)
        subtitle = ""
        (self.symbol, self.color) = (symbol, color)
        label = title
        self.disabled = disabled
        self.action = action
        self.trailing = trailing()
    }

    /// A suggestion has no category: a pin for a place, a magnifying glass for "Search petrol station".
    init(suggestion: SearchSuggestion, disabled: Bool = false, action: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing) {
        title = HighlightedText.attributed(suggestion.shownTitle, suggestion.shownHighlights)
        subtitle = suggestion.shownSubtitle
        (symbol, color) = suggestion.isQuery ? ("magnifyingglass", .gray) : ("mappin", .orange)
        label = [suggestion.shownTitle, suggestion.shownSubtitle].filter { !$0.isEmpty }.joined(separator: ", ")
        self.disabled = disabled
        self.action = action
        self.trailing = trailing()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.m) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(color, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(.primary).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.footnote).foregroundStyle(inSheet ? Color.surfaceSecondary : Color.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .padding(.horizontal, Spacing.l)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}

/// Icon and tile color for a search result, after LocationSearch.dc.html: towns red, transit
/// purple, nature green, everything else an orange pin.
struct PlaceKind {
    var symbol: String
    var color: Color

    init(_ result: DestinationResult) {
        let category = result.category.map(MKPointOfInterestCategory.init(rawValue:))
        switch category {
        case nil:
            (symbol, color) = ("building.2.fill", .red)
        case .publicTransport?, .airport?:
            (symbol, color) = ("tram.fill", .indigo)
        case .park?, .nationalPark?, .beach?, .campground?:
            (symbol, color) = ("leaf.fill", .green)
        case .gasStation?, .evCharger?:
            (symbol, color) = ("fuelpump.fill", .orange)
        case .restaurant?, .cafe?, .bakery?, .foodMarket?:
            (symbol, color) = ("fork.knife", .orange)
        case .hotel?:
            (symbol, color) = ("bed.double.fill", .purple)
        default:
            (symbol, color) = ("mappin", .orange)
        }
    }
}
