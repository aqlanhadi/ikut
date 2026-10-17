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
        ReportOption(type: .debris, label: "Debris", symbol: "exclamationmark.triangle.fill", tint: Color(red: 0.79, green: 0.20, blue: 0)),
        ReportOption(type: .accident, label: "Accident", symbol: "exclamationmark.octagon.fill", tint: Color(red: 0.84, green: 0, blue: 0.08)),
        ReportOption(type: .pothole, label: "Pothole", symbol: "circle.bottomhalf.filled", tint: Color(red: 0.54, green: 0.42, blue: 0.27)),
        ReportOption(type: .animal, label: "Animal", symbol: "pawprint.fill", tint: Color(red: 0.12, green: 0.48, blue: 0.21)),
        ReportOption(type: .stoppedVehicle, label: "Stopped car", symbol: "car.fill", tint: Color(red: 0.39, green: 0.39, blue: 0.40)),
        ReportOption(type: .roadworks, label: "Roadworks", symbol: "cone.fill", tint: Color(red: 0.79, green: 0.20, blue: 0)),
        ReportOption(type: .heavyRain, label: "Heavy rain", symbol: "cloud.heavyrain.fill", tint: Color(red: 0, green: 0.44, blue: 0.89)),
        ReportOption(type: .trafficJam, label: "Traffic jam", symbol: "car.2.fill", tint: Color(red: 0.84, green: 0, blue: 0.08)),
    ]

    /// "About your car": three pills under the grid.
    static let statuses: [ReportOption] = [
        ReportOption(type: .pullingOver, label: "Pulling over", symbol: "parkingsign", tint: .secondary),
        ReportOption(type: .carTrouble, label: "Car trouble", symbol: "wrench.and.screwdriver.fill", tint: .secondary),
        ReportOption(type: .runningLate, label: "Running late", symbol: "clock.fill", tint: .secondary),
    ]

    static let all = events + statuses
}
