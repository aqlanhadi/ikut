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
        ReportOption(type: .debris, label: "Debris", symbol: "exclamationmark.triangle.fill", tint: Palette.warningFill.color),
        ReportOption(type: .accident, label: "Accident", symbol: "exclamationmark.octagon.fill", tint: Palette.criticalFill.color),
        ReportOption(type: .pothole, label: "Pothole", symbol: "circle.bottomhalf.filled", tint: Palette.reportBrown.color),
        ReportOption(type: .animal, label: "Animal", symbol: "pawprint.fill", tint: MapColors.ok.color),
        ReportOption(type: .stoppedVehicle, label: "Stopped car", symbol: "car.fill", tint: Palette.neutralFill.color),
        ReportOption(type: .roadworks, label: "Roadworks", symbol: "cone.fill", tint: Palette.warningFill.color),
        ReportOption(type: .heavyRain, label: "Heavy rain", symbol: "cloud.heavyrain.fill", tint: Palette.accentFill.color),
        ReportOption(type: .trafficJam, label: "Traffic jam", symbol: "car.2.fill", tint: Palette.criticalFill.color),
    ]

    /// "About your car": three pills under the grid.
    static let statuses: [ReportOption] = [
        ReportOption(type: .pullingOver, label: "Pulling over", symbol: "parkingsign", tint: .secondary),
        ReportOption(type: .carTrouble, label: "Car trouble", symbol: "wrench.and.screwdriver.fill", tint: .secondary),
        ReportOption(type: .runningLate, label: "Running late", symbol: "clock.fill", tint: .secondary),
    ]

    static let all = events + statuses
}
