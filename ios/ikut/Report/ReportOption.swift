import SwiftUI

/// One button on the report sheet.
struct ReportOption: Identifiable, Equatable, Sendable {
    let type: EventType
    let label: String
    let symbol: String
    let tint: Color

    var id: String { type.rawValue }

    /// "debris", "stopped car": reads after "Reported ".
    var toastName: String { label.lowercased() }

    /// The 6 hazards and 2 conditions in the mockup's order (a 2-column grid, 4 rows).
    static let events: [ReportOption] = [
        ReportOption(type: .debris, label: "Debris", symbol: Symbol.warning, tint: Color.warningFill),
        ReportOption(type: .accident, label: "Accident", symbol: Symbol.accident, tint: Color.criticalFill),
        ReportOption(type: .pothole, label: "Pothole", symbol: Symbol.pothole, tint: Color.reportBrown),
        ReportOption(type: .animal, label: "Animal", symbol: Symbol.animal, tint: Color.ikutOK),
        ReportOption(type: .stoppedVehicle, label: "Stopped car", symbol: Symbol.car, tint: Color.neutralFill),
        ReportOption(type: .roadworks, label: "Roadworks", symbol: Symbol.roadworks, tint: Color.warningFill),
        ReportOption(type: .heavyRain, label: "Heavy rain", symbol: Symbol.heavyRain, tint: Color.ikutAccentFill),
        ReportOption(type: .trafficJam, label: "Traffic jam", symbol: Symbol.cars, tint: Color.criticalFill),
    ]

    /// "About your car": three pills under the grid.
    static let statuses: [ReportOption] = [
        ReportOption(type: .pullingOver, label: "Pulling over", symbol: Symbol.parking, tint: .secondary),
        ReportOption(type: .carTrouble, label: "Car trouble", symbol: Symbol.carTrouble, tint: .secondary),
        ReportOption(type: .runningLate, label: "Running late", symbol: Symbol.time, tint: .secondary),
    ]

    static let all = events + statuses
}
