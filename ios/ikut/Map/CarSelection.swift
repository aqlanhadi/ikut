import Foundation

/// Which car the driver has tapped on the map (D34 7b), pure so the rules can be tested. A selection only
/// rings the marker and points the panel at that car's row: it never moves the camera or changes the follow mode.
enum CarSelection {
    /// What a tap on `tapped` leaves selected: the car, or nothing when it was already the selected one.
    static func afterTap(on tapped: String?, current: String?) -> String? {
        guard let tapped else { return nil }
        return tapped == current ? nil : tapped
    }

    /// The selection once the cars on the trip are `ids`: cleared when that car has left.
    static func kept(_ selected: String?, among ids: [String]) -> String? {
        guard let selected, ids.contains(selected) else { return nil }
        return selected
    }

    /// The id the panel's rows carry, so the sheet can scroll to one.
    static func rowId(_ carId: String) -> String { "car.\(carId)" }

    /// Whether picking a car opens the folded panel: it goes at least to its tall detent, unless a stop card holds the sheet.
    static func opensPanel(selected: String?, shown: PanelSheet.Shown) -> Bool {
        selected != nil && shown == .folded
    }
}
